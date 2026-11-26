import AppKit
import OgCore

extension Notification.Name {
    /// The local Docs inference server (embedding + reranker) changed phase or logs.
    static let ogDocsServerChanged = Notification.Name("og.docsServerChanged")
}

/// Owns the local Docs inference server (MLX unified embedder + cross-encoder reranker)
/// following `spec/req/docs_server.fsl` and `spec/design/docs_server.fsl` (Issue #21, Q-2, D-9, D-10).
///
/// - Independent slot from inline completion (`ModelServerManager`): can run alone or concurrently.
/// - DES-1: child process in its own process group bound strictly to `127.0.0.1:<free port>`, offline-first via `uvx --offline` once cached (W-8).
/// - DES-2: ready only after `/health` answers 200 within bounded startup timeout (V-6); health probe blocks redirects (V-3).
/// - DES-3: at most one live process; replacements wait for the previous exit.
/// - DES-4: exits are matched by generation; windowed crash cap with exponential backoff stops Ready-crash loops (V-5).
/// - DES-5: quitting stops and waits for exit so nothing outlives the app.
@MainActor
final class DocsServerManager {
    static let shared = DocsServerManager()
    static let maxFailures = 3
    static let crashWindowSeconds: TimeInterval = 120
    static let startupTimeoutSeconds: TimeInterval = 90
    static let downloadMaxTimeoutSeconds: TimeInterval = 600
    static let downloadStallTimeoutSeconds: TimeInterval = 120
    private static let cachedConfigKeyDefaults = "og.docs.server.cachedConfigKey"

    enum Phase: Equatable {
        case off
        case starting(String)
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .off {
        didSet {
            if phase != oldValue {
                DocsManager.shared.syncInferenceClients()
                notify()
            }
        }
    }
    private(set) var log: [String] = []
    private(set) var port: Int?
    private(set) var rerankReady = false
    private var process: RunProcess?
    private var generation = 0
    private var zombies: [Int: RunProcess] = [:]
    private var restartPolicy = DocsServerRestartPolicy(
        maxFailures: DocsServerManager.maxFailures,
        windowSeconds: DocsServerManager.crashWindowSeconds,
        baseBackoffSeconds: 1.0
    )
    private var pendingSpawn = false
    private var healthTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var loadedConfig: DocsServerConfig?
    private var lastOutputAt = Date()
    private var sawDownloadProgress = false
    private var lastLaunchUsedOffline = false
    private var forceOnlineOnce = false

    // MARK: - Debug / Status helpers (W-10)

    var debugPIDs: [Int32] {
        var pids: [Int32] = []
        if let p = process, p.isRunning { pids.append(p.pid) }
        for z in zombies.values where z.isRunning { pids.append(z.pid) }
        return pids
    }

    var statusText: String {
        switch phase {
        case .off: return "off"
        case .starting(let d): return "starting (\(d))"
        case .ready:
            let rr = rerankReady ? "+rerank" : "embed-only"
            return "ready 127.0.0.1:\(port ?? 0) (\(rr))"
        case .failed(let why): return "failed: \(why)"
        }
    }

    // MARK: - Settings (D-10, FR-19)

    var enabled: Bool {
        get { (UserDefaults.standard.object(forKey: "og.docs.semantic.enabled") as? Bool) ?? false }
        set {
            UserDefaults.standard.set(newValue, forKey: "og.docs.semantic.enabled")
            if newValue { enable() } else { disable() }
        }
    }

    var config: DocsServerConfig {
        get {
            guard let data = UserDefaults.standard.data(forKey: "og.docs.server"),
                  let c = try? JSONDecoder().decode(DocsServerConfig.self, from: data) else {
                return DocsServerConfig()
            }
            return c
        }
        set {
            let old = config
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "og.docs.server")
            }
            if newValue != old {
                if old.embeddingDescriptor != newValue.embeddingDescriptor {
                    DocsManager.shared.handleEmbeddingModelChanged(to: newValue.embeddingDescriptor)
                }
                selectModel()
            }
        }
    }

    var endpointURL: URL? {
        guard phase == .ready, let port else { return nil }
        return URL(string: "http://127.0.0.1:\(port)")
    }

    /// Loopback embedder client, available only while ready (ASSUME-3, D-9).
    var embedderClient: LoopbackEmbeddingClient? {
        guard phase == .ready, let url = endpointURL, let cfg = loadedConfig else { return nil }
        return LoopbackEmbeddingClient(endpoint: url, descriptor: cfg.embeddingDescriptor)
    }

    /// Loopback reranker client, available only while ready and reranker is active (DOC-10).
    var rerankerClient: LoopbackRerankerClient? {
        guard phase == .ready, rerankReady, let url = endpointURL, let cfg = loadedConfig,
              cfg.rerankEnabled, !cfg.rerankModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return LoopbackRerankerClient(endpoint: url, modelID: cfg.rerankModel)
    }

    // MARK: - Lifecycle

    func startIfEnabled() {
        if enabled && DocsManager.shared.enabled {
            enable()
        }
    }

    func syncWithDocsOptIn(docsEnabled: Bool) {
        if !docsEnabled {
            if phase != .off {
                disable()
            }
        } else if enabled && (phase == .off) {
            enable()
        }
    }

    private func enable() {
        guard DocsManager.shared.enabled else { return }
        guard phase == .off || isFailed else { return }
        restartPolicy.reset()
        requestSpawn()
    }

    private func disable() {
        stopCurrent()
        rerankReady = false
        phase = .off
    }

    func retry() {
        guard enabled, DocsManager.shared.enabled, isFailed else { return }
        restartPolicy.reset()
        requestSpawn()
    }

    func restart() {
        guard enabled, DocsManager.shared.enabled else { return }
        restartPolicy.reset()
        stopCurrent()
        requestSpawn()
    }

    private func selectModel() {
        guard enabled, DocsManager.shared.enabled, !isFailed, phase != .off else { return }
        restartPolicy.reset()
        stopCurrent()
        requestSpawn()
    }

    /// DES-5: stop and wait (bounded) so no child process outlives the app.
    func shutdownForQuit() {
        restartTask?.cancel()
        restartTask = nil
        healthTask?.cancel()
        healthTask = nil
        var all = Array(zombies.values)
        if let p = process { all.append(p) }
        for p in all where p.isRunning { killpg(p.pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(3)
        while all.contains(where: { $0.isRunning }) && Date() < deadline { usleep(50_000) }
        for p in all where p.isRunning { killpg(p.pid, SIGKILL) }
        process = nil
        zombies.removeAll()
        rerankReady = false
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    // MARK: - Spawning (DES-3, W-8)

    private func requestSpawn() {
        restartTask?.cancel()
        restartTask = nil
        rerankReady = false
        phase = .starting("starting…")
        pendingSpawn = true
        spawnIfPossible()
    }

    private func scheduleDelayedSpawn(after delaySeconds: TimeInterval) {
        restartTask?.cancel()
        rerankReady = false
        phase = .starting("restarting in \(Int(ceil(delaySeconds)))s…")
        restartTask = Task { [weak self] in
            let ns = UInt64(max(0.1, delaySeconds) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ns)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.enabled, DocsManager.shared.enabled else { return }
                self.requestSpawn()
            }
        }
    }

    private func spawnIfPossible() {
        guard pendingSpawn, process == nil, zombies.isEmpty else { return }
        pendingSpawn = false
        let cfg = config
        guard let port = ModelServerCommand.freePort() else {
            fail("no free port on 127.0.0.1")
            return
        }
        // W-8: launch uvx in strict offline mode when this exact config has already succeeded on this Mac.
        let useOffline = !forceOnlineOnce
            && cfg.backend == .mlx
            && UserDefaults.standard.string(forKey: Self.cachedConfigKeyDefaults) == cfg.cacheKey
        forceOnlineOnce = false
        lastLaunchUsedOffline = useOffline

        let argv: [String]
        do {
            argv = try DocsModelServerCommand.argv(for: cfg, port: port, offline: useOffline)
        } catch {
            appendLog("✗ \(error.localizedDescription)")
            fail(error.localizedDescription)
            return
        }
        generation += 1
        let gen = generation
        var env = ToolLocator.shared.environment
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        if useOffline {
            env["UV_OFFLINE"] = "1"
            env["HF_HUB_OFFLINE"] = "1"
        }
        let p = RunProcess(
            executable: argv[0],
            arguments: Array(argv.dropFirst()),
            directory: FileManager.default.homeDirectoryForCurrentUser,
            environment: env
        )
        let modeNote = useOffline ? " [offline]" : ""
        appendLog("$ " + argv.map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ") + modeNote)
        do {
            try p.start { event in
                Task { @MainActor in
                    switch event {
                    case .output(_, let text):
                        DocsServerManager.shared.serverOutput(text, generation: gen)
                    case .exit(let status):
                        DocsServerManager.shared.exited(generation: gen, status: status)
                    }
                }
            }
        } catch {
            appendLog("✗ \(error)")
            recordFailureAndMaybeRetry(reason: "\(error)", allowOfflineFallback: useOffline)
            return
        }
        process = p
        self.port = port
        loadedConfig = cfg
        lastOutputAt = Date()
        sawDownloadProgress = false
        phase = .starting(useOffline ? "loading cached models…" : "loading models…")
        pollHealth(generation: gen, url: URL(string: "http://127.0.0.1:\(port)\(cfg.healthPath)"))
    }

    // MARK: - Health Polling with Bounded Startup Timeout (DES-2, V-3, V-6)

    private func pollHealth(generation gen: Int, url: URL?) {
        healthTask?.cancel()
        guard let url else { return }
        let startedAt = Date()
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                if let info = await Self.fetchHealth(url) {
                    await MainActor.run { self?.becameReady(generation: gen, rerankReady: info.rerankReady) }
                    return
                }
                let timedOut: Bool = await MainActor.run {
                    guard let self, gen == self.generation, self.process != nil else { return false }
                    let now = Date()
                    let elapsed = now.timeIntervalSince(startedAt)
                    if self.sawDownloadProgress {
                        let idle = now.timeIntervalSince(self.lastOutputAt)
                        return elapsed > Self.downloadMaxTimeoutSeconds || idle > Self.downloadStallTimeoutSeconds
                    }
                    return elapsed > Self.startupTimeoutSeconds
                }
                if timedOut {
                    await MainActor.run { self?.healthTimedOut(generation: gen) }
                    return
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
    }

    /// Loopback-only, redirect-blocking health probe (V-3, NeverLeavesMachine).
    private static func fetchHealth(_ url: URL) async -> (ok: Bool, rerankReady: Bool)? {
        guard LocalCompletionClient.isLoopback(url) else { return nil }
        let cfg = LocalCompletionClient.sessionConfiguration.copy() as? URLSessionConfiguration ?? .ephemeral
        cfg.timeoutIntervalForRequest = 2
        cfg.timeoutIntervalForResource = 2
        let session = URLSession(configuration: cfg, delegate: LoopbackOnlySessionDelegate.shared, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else {
            return nil
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let rr = (obj["rerank_ready"] as? Bool) ?? false
            return (true, rr)
        }
        return (true, false)
    }

    private func becameReady(generation gen: Int, rerankReady: Bool) {
        guard gen == generation, process != nil else { return }
        // V-5: do NOT wipe `restartPolicy` on ready — sliding crash window naturally expires
        // older failures after `crashWindowSeconds`, preventing rapid Ready->crash spin loops.
        if let cfg = loadedConfig, cfg.backend == .mlx {
            UserDefaults.standard.set(cfg.cacheKey, forKey: Self.cachedConfigKeyDefaults)
        }
        self.rerankReady = rerankReady
        phase = .ready
        let rrNote = rerankReady ? " + reranker" : ""
        appendLog("✓ ready on 127.0.0.1:\(port ?? 0) (embedder\(rrNote))")
    }

    private func healthTimedOut(generation gen: Int) {
        guard gen == generation, process != nil else { return }
        let wasOffline = lastLaunchUsedOffline
        appendLog("✗ startup timed out waiting for /health")
        stopCurrent()
        recordFailureAndMaybeRetry(
            reason: "Docs server startup timed out waiting for /health",
            allowOfflineFallback: wasOffline
        )
    }

    // MARK: - Exits & Windowed Crash Cap (DES-4, V-5)

    private func exited(generation gen: Int, status: Int32) {
        if let z = zombies.removeValue(forKey: gen) {
            _ = z
            spawnIfPossible()
            return
        }
        guard gen == generation, process != nil else { return }
        process = nil
        rerankReady = false
        healthTask?.cancel()
        let wasReady = (phase == .ready)
        let wasOffline = lastLaunchUsedOffline
        appendLog("process exited with status \(status)")
        let reason = wasReady
            ? "the Docs server crashed repeatedly (status \(status))"
            : "the Docs server exited with status \(status)"
        recordFailureAndMaybeRetry(reason: reason, allowOfflineFallback: !wasReady && wasOffline)
    }

    private func recordFailureAndMaybeRetry(reason: String, allowOfflineFallback: Bool) {
        if allowOfflineFallback {
            // W-8: if local uv/HF cache was cleared externally, clear the cached marker and retry online.
            UserDefaults.standard.removeObject(forKey: Self.cachedConfigKeyDefaults)
            forceOnlineOnce = true
            appendLog("offline launch failed; retrying with network access to refresh cache…")
        }
        let outcome = restartPolicy.recordFailure(at: Date())
        if outcome.shouldRetry && enabled && DocsManager.shared.enabled {
            appendLog("retrying (\(outcome.failureCount)/\(Self.maxFailures - 1)) after \(Int(ceil(outcome.delaySeconds)))s…")
            scheduleDelayedSpawn(after: outcome.delaySeconds)
        } else {
            fail(reason)
        }
    }

    private func fail(_ reason: String) {
        restartTask?.cancel()
        restartTask = nil
        phase = .failed(reason)
    }

    private func stopCurrent() {
        restartTask?.cancel()
        restartTask = nil
        healthTask?.cancel()
        healthTask = nil
        pendingSpawn = false
        guard let p = process else { return }
        process = nil
        if p.isRunning {
            zombies[generation] = p
            p.stop(grace: 3)
        }
    }

    // MARK: - Logs

    private func serverOutput(_ s: String, generation gen: Int) {
        if gen == generation {
            lastOutputAt = Date()
        }
        for line in s.split(separator: "\n", omittingEmptySubsequences: true) {
            appendLog(String(line))
            let lower = line.lowercased()
            if gen == generation, case .starting = phase,
               line.contains("%") || lower.contains("downloading") || lower.contains("installed ") || lower.contains("fetching") {
                sawDownloadProgress = true
                phase = .starting("downloading models…")
            }
        }
    }

    private func appendLog(_ line: String) {
        log.append(line)
        if log.count > 400 { log.removeFirst(log.count - 400) }
        NotificationCenter.default.post(name: .ogDocsServerChanged, object: nil)
    }

    private func notify() {
        NotificationCenter.default.post(name: .ogDocsServerChanged, object: nil)
    }
}
