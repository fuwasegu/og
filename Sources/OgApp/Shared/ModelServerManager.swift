import AppKit
import OgCore

extension Notification.Name {
    /// The local model server changed phase.
    static let ogModelServerChanged = Notification.Name("og.modelServerChanged")
}

/// Owns the local completion server (spec/design/model_server.fsl).
///
/// - DES-1: child process in its own process group on 127.0.0.1:<free port>
/// - DES-2: ready only after the health endpoint answers
/// - DES-3: at most one process; a replacement waits for the previous exit
/// - DES-4: exits are matched by generation
/// - DES-5: quitting waits for the process to exit
@MainActor
final class ModelServerManager {
    static let shared = ModelServerManager()
    static let maxFailures = 3

    enum Phase: Equatable {
        case off
        case starting(String)
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .off { didSet { if phase != oldValue { notify() } } }
    private(set) var log: [String] = []
    private(set) var port: Int?
    private var process: RunProcess?
    private var generation = 0
    private var zombies: [Int: RunProcess] = [:]
    private var failures = 0
    private var pendingSpawn = false
    private var healthTask: Task<Void, Never>?
    private var loadedConfig: ModelServerConfig?

    // MARK: - Settings

    var enabled: Bool {
        get { (UserDefaults.standard.object(forKey: "og.ai.enabled") as? Bool) ?? false }
        set {
            UserDefaults.standard.set(newValue, forKey: "og.ai.enabled")
            if newValue { enable() } else { disable() }
        }
    }

    var config: ModelServerConfig {
        get {
            guard let data = UserDefaults.standard.data(forKey: "og.ai.server"),
                  let c = try? JSONDecoder().decode(ModelServerConfig.self, from: data) else { return ModelServerConfig() }
            return c
        }
        set {
            let old = config
            if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: "og.ai.server") }
            if newValue != old { selectModel() }
        }
    }

    /// A client only while ready (spec ASSUME-3).
    var client: LocalCompletionClient? {
        guard phase == .ready, let port, let cfg = loadedConfig,
              let url = URL(string: "http://127.0.0.1:\(port)") else { return nil }
        return LocalCompletionClient(endpoint: url, api: cfg.api)
    }

    var statusText: String {
        switch phase {
        case .off: return "AI: off"
        case .starting(let detail): return "AI: \(detail)"
        case .ready: return "AI: ready"
        case .failed: return "AI: failed"
        }
    }

    // MARK: - Lifecycle (requirements: enable / disable / retry / select_model / quit)

    /// Called at launch.
    func startIfEnabled() {
        if enabled { enable() }
    }

    private func enable() {
        guard phase == .off || isFailed else { return }
        failures = 0
        requestSpawn()
    }

    private func disable() {
        stopCurrent()
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
        guard enabled, !isFailed, phase != .off else { return }
        failures = 0
        stopCurrent()
        requestSpawn()
    }

    /// DES-5: stop and wait (bounded) so nothing outlives the app.
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
    }

    private var isFailed: Bool { if case .failed = phase { return true }; return false }

    // MARK: - Spawning (DES-3)

    private func requestSpawn() {
        phase = .starting("starting…")
        pendingSpawn = true
        spawnIfPossible()
    }

    private func spawnIfPossible() {
        guard pendingSpawn, process == nil, zombies.isEmpty else { return }
        pendingSpawn = false
        let cfg = config
        guard let port = ModelServerCommand.freePort() else { fail("no free port on 127.0.0.1"); return }
        let argv: [String]
        do {
            argv = try ModelServerCommand.argv(for: cfg, port: port)
        } catch {
            appendLog("✗ \(error.localizedDescription)")
            // A missing tool will not fix itself: give up immediately.
            failures = Self.maxFailures
            fail(error.localizedDescription)
            return
        }
        generation += 1
        let gen = generation
        var env = ToolLocator.shared.environment
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        // DES-1: own process group from spawn time, so stop reaches uvx/mise children too.
        let p = RunProcess(executable: argv[0], arguments: Array(argv.dropFirst()),
                           directory: FileManager.default.homeDirectoryForCurrentUser, environment: env)
        appendLog("$ " + argv.map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " "))
        do {
            try p.start { event in
                Task { @MainActor in
                    switch event {
                    case .output(_, let text): ModelServerManager.shared.serverOutput(text, generation: gen)
                    case .exit(let status): ModelServerManager.shared.exited(generation: gen, status: status)
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
        phase = .starting("loading model…")
        pollHealth(generation: gen, url: URL(string: "http://127.0.0.1:\(port)\(cfg.healthPath)"))
    }

    private func pollHealth(generation gen: Int, url: URL?) {
        healthTask?.cancel()
        guard let url else { return }
        healthTask = Task { [weak self] in
            // Model download can take minutes; keep polling while the process lives.
            while !Task.isCancelled {
                if await ModelServerCommand.healthy(url) {
                    await MainActor.run { self?.becameReady(generation: gen) }
                    return
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
    }

    private func becameReady(generation gen: Int) {
        guard gen == generation, process != nil else { return }
        failures = 0
        phase = .ready
        appendLog("✓ ready on 127.0.0.1:\(port ?? 0)")
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
        healthTask?.cancel()
        appendLog("process exited with status \(status)")
        if phase == .ready {
            // crashed(): restart automatically.
            failures = 1
            requestSpawn()
        } else {
            failed(attempt: "the server exited with status \(status)")
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

    /// Live pids (current + stopping), for the headless test driver.
    var debugPIDs: [Int32] { ([process] + zombies.values.map { Optional($0) }).compactMap { $0 }.filter(\.isRunning).map(\.pid) }

    // MARK: - Log

    private func serverOutput(_ s: String, generation gen: Int) {
        for line in s.split(separator: "\n", omittingEmptySubsequences: true) {
            appendLog(String(line))
            if gen == generation, case .starting = phase, line.contains("%") || line.lowercased().contains("download") {
                phase = .starting("downloading model…")
            }
        }
    }

    private func appendLog(_ line: String) {
        log.append(line)
        if log.count > 400 { log.removeFirst(log.count - 400) }
        NotificationCenter.default.post(name: .ogModelServerChanged, object: nil)
    }

    private func notify() {
        NotificationCenter.default.post(name: .ogModelServerChanged, object: nil)
    }
}
