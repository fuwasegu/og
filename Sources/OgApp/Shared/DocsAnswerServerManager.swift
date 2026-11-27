import AppKit
import OgCore

extension Notification.Name {
    /// The local Docs answer-generation LLM server changed phase or configuration.
    static let ogDocsAnswerServerChanged = Notification.Name("og.docsAnswerServerChanged")
}

/// Owns the optional local LLM server for Docs Phase 3 answer synthesis
/// (D-9, D-10, DOC-1, DOC-6, DES-A1 in `spec/design/docs_answer.fsl`).
@MainActor
final class DocsAnswerServerManager {
    static let shared = DocsAnswerServerManager()
    static let maxFailures = 3
    static let crashWindowSeconds: TimeInterval = 120
    static let startupTimeoutSeconds: TimeInterval = 120

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
    private(set) var port: Int?
    private var process: RunProcess?
    private var generation = 0
    private var zombies: [Int: RunProcess] = [:]
    private var restartPolicy = DocsServerRestartPolicy(
        maxFailures: DocsAnswerServerManager.maxFailures,
        windowSeconds: DocsAnswerServerManager.crashWindowSeconds,
        baseBackoffSeconds: 1.0
    )
    private var pendingSpawn = false
    private var healthTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var loadedConfig: DocsAnswerServerConfig?
    private var modelServerObserver: NSObjectProtocol?

    private init() {
        modelServerObserver = NotificationCenter.default.addObserver(
            forName: .ogModelServerChanged,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                if DocsAnswerServerManager.shared.config.mode == .sharedCompletion {
                    DocsManager.shared.syncInferenceClients()
                    DocsAnswerServerManager.shared.notify()
                }
            }
        }
    }

    var config: DocsAnswerServerConfig {
        get {
            guard let data = UserDefaults.standard.data(forKey: "og.docs.answerServer"),
                  let c = try? JSONDecoder().decode(DocsAnswerServerConfig.self, from: data) else {
                return DocsAnswerServerConfig()
            }
            return c
        }
        set {
            let old = config
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "og.docs.answerServer")
            }
            if newValue != old {
                applyConfigChange(old: old, new: newValue)
            }
        }
    }

    var endpointURL: URL? {
        switch config.mode {
        case .off:
            return nil
        case .sharedCompletion:
            return ModelServerManager.shared.endpointURL
        case .dedicated:
            guard phase == .ready, let port else { return nil }
            return URL(string: "http://127.0.0.1:\(port)")
        }
    }

    /// Y-5: In sharedCompletion mode, only allow chat/instruct-capable models (never FIM-only base models).
    var isSharedModelCompatible: Bool {
        let cfg = ModelServerManager.shared.config
        if cfg.backend == .custom { return true }
        let modelName = (ModelServerManager.shared.loadedModelName ?? cfg.model).lowercased()
        if modelName.contains("--fim-") { return false }
        return modelName.contains("instruct") || modelName.contains("chat")
    }

    var answerGeneratorClient: LoopbackChatAnswerGenerator? {
        guard DocsManager.shared.enabled else { return nil }
        let cfg = config
        switch cfg.mode {
        case .off:
            return nil
        case .sharedCompletion:
            guard isSharedModelCompatible,
                  let url = ModelServerManager.shared.endpointURL,
                  let modelID = ModelServerManager.shared.loadedModelName else {
                return nil
            }
            return LoopbackChatAnswerGenerator(endpoint: url, modelID: modelID)
        case .dedicated:
            guard phase == .ready, let url = endpointURL, let loaded = loadedConfig else {
                return nil
            }
            return LoopbackChatAnswerGenerator(endpoint: url, modelID: loaded.model)
        }
    }

    var statusText: String {
        switch config.mode {
        case .off:
            return "Docs LLM: off (検索カードのみ)"
        case .sharedCompletion:
            if !isSharedModelCompatible {
                return "Docs LLM: disabled (補完モデルが Instruct 非対応のため共有不可)"
            }
            if let url = ModelServerManager.shared.endpointURL {
                return "Docs LLM: sharing inline AI server (\(url.absoluteString))"
            }
            return "Docs LLM: waiting for inline AI server"
        case .dedicated:
            switch phase {
            case .off: return "Docs LLM: off"
            case .starting(let d): return "Docs LLM: \(d)"
            case .ready: return "Docs LLM: ready on 127.0.0.1:\(port ?? 0)"
            case .failed(let why): return "Docs LLM failed: \(why)"
            }
        }
    }

    // MARK: - Lifecycle

    func startIfEnabled() {
        if DocsManager.shared.enabled && config.mode == .dedicated {
            enable()
        }
    }

    func syncWithDocsOptIn(docsEnabled: Bool) {
        if !docsEnabled {
            if phase != .off { disable() }
        } else if config.mode == .dedicated && phase == .off {
            enable()
        } else {
            DocsManager.shared.syncInferenceClients()
        }
    }

    func retry() {
        guard DocsManager.shared.enabled, config.mode == .dedicated, isFailed else { return }
        restartPolicy.reset()
        requestSpawn()
    }

    func restart() {
        guard DocsManager.shared.enabled, config.mode == .dedicated else { return }
        restartPolicy.reset()
        stopCurrent()
        requestSpawn()
    }

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
        phase = .off
    }

    private func applyConfigChange(old: DocsAnswerServerConfig, new: DocsAnswerServerConfig) {
        if new.mode != .dedicated {
            if phase != .off { disable() }
            DocsManager.shared.syncInferenceClients()
            notify()
            return
        }
        if DocsManager.shared.enabled {
            let needsRestart = old.mode != .dedicated || old.backend != new.backend || old.model != new.model || old.customCommand != new.customCommand
            if needsRestart {
                restartPolicy.reset()
                stopCurrent()
                requestSpawn()
            } else {
                DocsManager.shared.syncInferenceClients()
                notify()
            }
        } else {
            notify()
        }
    }

    private func enable() {
        guard DocsManager.shared.enabled, config.mode == .dedicated else { return }
        guard phase == .off || isFailed else { return }
        restartPolicy.reset()
        requestSpawn()
    }

    private func disable() {
        stopCurrent()
        phase = .off
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    // MARK: - Spawning

    private func requestSpawn() {
        restartTask?.cancel()
        restartTask = nil
        phase = .starting("starting…")
        pendingSpawn = true
        spawnIfPossible()
    }

    private func spawnIfPossible() {
        guard pendingSpawn, process == nil, zombies.isEmpty else { return }
        pendingSpawn = false
        let cfg = config
        guard cfg.mode == .dedicated, DocsManager.shared.enabled else {
            phase = .off
            return
        }
        guard let port = ModelServerCommand.freePort() else {
            fail("no free port on 127.0.0.1")
            return
        }
        let argv: [String]
        do {
            argv = try DocsAnswerServerCommand.argv(for: cfg, port: port)
        } catch {
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
        do {
            try p.start { event in
                Task { @MainActor in
                    if case .exit(let status) = event {
                        DocsAnswerServerManager.shared.exited(generation: gen, status: status)
                    }
                }
            }
        } catch {
            recordFailure("\(error)")
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
        let deadline = Date().addingTimeInterval(Self.startupTimeoutSeconds)
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                if await ModelServerCommand.healthy(url, timeout: 2) {
                    await MainActor.run { self?.becameReady(generation: gen) }
                    return
                }
                if Date() >= deadline {
                    await MainActor.run { self?.healthTimedOut(generation: gen) }
                    return
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
    }

    private func becameReady(generation gen: Int) {
        guard gen == generation, process != nil else { return }
        phase = .ready
    }

    private func healthTimedOut(generation gen: Int) {
        guard gen == generation else { return }
        stopCurrent()
        recordFailure("startup timed out")
    }

    private func exited(generation gen: Int, status: Int32) {
        if let z = zombies.removeValue(forKey: gen) {
            _ = z
            spawnIfPossible()
            return
        }
        guard gen == generation else { return }
        healthTask?.cancel()
        healthTask = nil
        process = nil
        port = nil
        loadedConfig = nil
        guard DocsManager.shared.enabled, config.mode == .dedicated else {
            phase = .off
            return
        }
        recordFailure("exited with status \(status)")
    }

    private func recordFailure(_ reason: String) {
        let outcome = restartPolicy.recordFailure(at: Date())
        if !outcome.shouldRetry {
            fail(reason)
            return
        }
        phase = .starting("restarting (\(outcome.failureCount)/\(Self.maxFailures))…")
        restartTask?.cancel()
        let delayNs = UInt64(outcome.delaySeconds * 1_000_000_000)
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNs)
            guard !Task.isCancelled else { return }
            self?.requestSpawn()
        }
    }

    private func fail(_ reason: String) {
        stopCurrent()
        phase = .failed(reason)
    }

    private func stopCurrent() {
        healthTask?.cancel()
        healthTask = nil
        restartTask?.cancel()
        restartTask = nil
        pendingSpawn = false
        if let p = process {
            let gen = generation
            process = nil
            port = nil
            loadedConfig = nil
            if p.isRunning {
                zombies[gen] = p
                killpg(p.pid, SIGTERM)
            }
        }
    }

    private func notify() {
        NotificationCenter.default.post(name: .ogDocsAnswerServerChanged, object: self)
    }
}
