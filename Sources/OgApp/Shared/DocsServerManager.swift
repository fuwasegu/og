import AppKit
import OgCore

extension Notification.Name {
    /// The local Docs inference server (embedding + reranker) changed phase or logs.
    static let ogDocsServerChanged = Notification.Name("og.docsServerChanged")
}

/// Owns the local Docs inference server (MLX unified embedder + cross-encoder reranker)
/// following the same D-9 / D-10 / `spec/design/model_server.fsl` lifecycle contract as `ModelServerManager`
/// (Issue #21, Q-2, DES-6 in `spec/design/research.fsl`).
///
/// - Independent slot from inline completion (`ModelServerManager`): can run alone or concurrently.
/// - DES-1: child process in its own process group bound strictly to `127.0.0.1:<free port>`.
/// - DES-2: ready only after `/health` answers 200.
/// - DES-3: at most one process; replacements wait for the previous exit.
/// - DES-4: exits are matched by generation.
/// - DES-5: quitting stops and waits for exit so nothing outlives the app.
@MainActor
final class DocsServerManager {
    static let shared = DocsServerManager()
    static let maxFailures = 3

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
    private var failures = 0
    private var pendingSpawn = false
    private var healthTask: Task<Void, Never>?
    private var loadedConfig: DocsServerConfig?

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
        guard phase == .off || isFailed else { return }
        failures = 0
        requestSpawn()
    }

    private func disable() {
        stopCurrent()
        rerankReady = false
        phase = .off
    }

    func retry() {
        guard enabled, isFailed else { return }
        failures = 0
        requestSpawn()
    }

    func restart() {
        guard enabled else { return }
        failures = 0
        stopCurrent()
        requestSpawn()
    }

    private func selectModel() {
        guard enabled, DocsManager.shared.enabled, !isFailed, phase != .off else { return }
        failures = 0
        stopCurrent()
        requestSpawn()
    }

    /// DES-5: stop and wait (bounded) so no child process outlives the app.
    func shutdownForQuit() {
        healthTask?.cancel()
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

    // MARK: - Spawning (DES-3)

    private func requestSpawn() {
        rerankReady = false
        phase = .starting("starting…")
        pendingSpawn = true
        spawnIfPossible()
    }

    private func spawnIfPossible() {
        guard pendingSpawn, process == nil, zombies.isEmpty else { return }
        pendingSpawn = false
        let cfg = config
        guard let port = ModelServerCommand.freePort() else {
            fail("no free port on 127.0.0.1")
            return
        }
        let argv: [String]
        do {
            argv = try DocsModelServerCommand.argv(for: cfg, port: port)
        } catch {
            appendLog("✗ \(error.localizedDescription)")
            failures = Self.maxFailures
            fail(error.localizedDescription)
            return
        }
        generation += 1
        let gen = generation
        var env = ToolLocator.shared.environment
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        let p = RunProcess(
            executable: argv[0],
            arguments: Array(argv.dropFirst()),
            directory: FileManager.default.homeDirectoryForCurrentUser,
            environment: env
        )
        appendLog("$ " + argv.map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " "))
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
            failed(attempt: "\(error)")
            return
        }
        process = p
        self.port = port
        loadedConfig = cfg
        phase = .starting("loading models…")
        pollHealth(generation: gen, url: URL(string: "http://127.0.0.1:\(port)\(cfg.healthPath)"))
    }

    private func pollHealth(generation gen: Int, url: URL?) {
        healthTask?.cancel()
        guard let url else { return }
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                if let info = await Self.fetchHealth(url) {
                    await MainActor.run { self?.becameReady(generation: gen, rerankReady: info.rerankReady) }
                    return
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
    }

    private static func fetchHealth(_ url: URL) async -> (ok: Bool, rerankReady: Bool)? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
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
        failures = 0
        self.rerankReady = rerankReady
        phase = .ready
        let rrNote = rerankReady ? " + reranker" : ""
        appendLog("✓ ready on 127.0.0.1:\(port ?? 0) (embedder\(rrNote))")
    }

    // MARK: - Exits (DES-4)

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
        appendLog("process exited with status \(status)")
        if phase == .ready {
            failures = 1
            requestSpawn()
        } else {
            failed(attempt: "the Docs server exited with status \(status)")
        }
    }

    private func failed(attempt reason: String) {
        failures += 1
        if failures < Self.maxFailures && enabled {
            appendLog("retrying (\(failures)/\(Self.maxFailures - 1))…")
            requestSpawn()
        } else {
            fail(reason)
        }
    }

    private func fail(_ reason: String) {
        phase = .failed(reason)
    }

    private func stopCurrent() {
        healthTask?.cancel()
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
        for line in s.split(separator: "\n", omittingEmptySubsequences: true) {
            appendLog(String(line))
            if gen == generation, case .starting = phase,
               line.contains("%") || line.lowercased().contains("downloading") {
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
