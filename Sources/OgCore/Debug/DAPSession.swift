import Foundation

/// One delve debug session over DAP (spec/design/run_debug.fsl, DES-3 / DES-4).
///
/// Lifecycle: `start(breakpoints:)` spawns `dlv dap --listen=127.0.0.1:0`, connects over TCP,
/// sends initialize → launch → setBreakpoints → configurationDone. Events are delivered,
/// in order, through `onEvent` (off the main actor). One instance = one generation; to
/// restart, `stop()` it and create a new session (DES-2 lives in the owner).
public actor DAPSession {
    public typealias EventHandler = @Sendable (DAPEvent) -> Void

    public let request: RunRequest
    private let onEvent: EventHandler
    private var state = DebugStateMachine()
    private var ledger = BreakpointLedger()
    private var pendingBreakpoints: [String: Set<Int>] = [:]
    private var configured = false
    private var process: Process?
    private var rpc: JSONRPCConnection?
    private var socket: FileHandle?
    private var lastThreadID: Int?
    private var finished = false

    public init(request: RunRequest, onEvent: @escaping EventHandler) {
        self.request = request
        self.onEvent = onEvent
    }

    public var phase: DebugPhase { state.phase }
    public var stopEpoch: Int { state.stopEpoch }
    public var isLive: Bool { state.isLive }

    // MARK: - Lifecycle

    /// Starts delve and launches the program. `breakpoints`: absolute path -> 0-based lines.
    /// Throws if delve cannot be started or the launch (build) fails; the session is then terminated.
    public func start(breakpoints: [String: Set<Int>]) async throws {
        guard state.launch() else { return }
        pendingBreakpoints = breakpoints
        do {
            let address = try await spawnDelve()
            try await connectAndLaunch(host: address.host, port: address.port)
        } catch {
            if let rpc { _ = try? await rpc.request("disconnect", ["terminateDebuggee": true], timeout: 2) }
            finish()
            throw error
        }
    }

    /// Connects to an already listening DAP server instead of spawning delve (tests, remote adapters).
    public func start(connectingTo host: String, port: UInt16, breakpoints: [String: Set<Int>]) async throws {
        guard state.launch() else { return }
        pendingBreakpoints = breakpoints
        do {
            try await connectAndLaunch(host: host, port: port)
        } catch {
            if let rpc { _ = try? await rpc.request("disconnect", ["terminateDebuggee": true], timeout: 2) }
            finish()
            throw error
        }
    }

    /// Ends the session: disconnects (terminating the debuggee) and kills delve.
    public func stop() async {
        guard !finished else { return }
        if let rpc {
            _ = try? await rpc.request("disconnect", ["terminateDebuggee": true], timeout: 3)
        }
        finish()
    }

    private func spawnDelve() async throws -> (host: String, port: UInt16) {
        guard let dlv = ToolLocator.shared.find("dlv") else { throw DAPError.delveNotFound }
        let dir = request.packageDir.standardizedFileURL
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: dlv)
        proc.arguments = ["dap", "--listen=127.0.0.1:0", "--check-go-version=false"]
        proc.currentDirectoryURL = dir
        var env = ToolLocator.shared.environment
        env["PWD"] = dir.path   // so `go build` records the project's own paths
        proc.environment = env
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = out
        proc.standardInput = FileHandle.nullDevice

        let (chunks, sink) = AsyncStream<String>.makeStream()
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                sink.finish()
            } else {
                sink.yield(String(decoding: data, as: UTF8.self))
            }
        }
        proc.terminationHandler = { [weak self] _ in
            Task { await self?.delveExited() }
        }
        try proc.run()
        process = proc

        // Wait for "DAP server listening at: host:port" (give up after 20s).
        let watchdog = Task { [weak proc] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            if !Task.isCancelled { proc?.terminate() }
        }
        let emit = onEvent
        let waiter = Locked<CheckedContinuation<String, Never>?>(nil)
        let seen = await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            waiter.withLock { $0 = cont }
            Task {
                var text = ""
                var listening = false
                for await chunk in chunks {
                    if listening {
                        // Remaining delve output goes to the console.
                        emit(.output(category: "console", text: chunk))
                        continue
                    }
                    text += chunk
                    if DelveListenAddress.parse(text) != nil {
                        listening = true
                        waiter.withLock { c in let k = c; c = nil; return k }?.resume(returning: text)
                    }
                }
                waiter.withLock { c in let k = c; c = nil; return k }?.resume(returning: text)
            }
        }
        watchdog.cancel()
        guard let address = DelveListenAddress.parse(seen) else {
            throw DAPError.delveDidNotListen(seen.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return address
    }

    private func connectAndLaunch(host: String, port: UInt16) async throws {
        let address = (host: host, port: port)

        let fd = try DAPSession.connect(host: address.host, port: address.port)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        socket = handle
        let conn = JSONRPCConnection(readFrom: handle, writeTo: handle, dap: true)
        rpc = conn
        await conn.setHandlers(
            notification: { [weak self] event, body in await self?.handleEvent(event, body) },
            request: { _, _ in .null },
            close: { [weak self] in await self?.finish() }
        )
        await conn.start()

        _ = try await conn.request("initialize", DAPLaunch.initializeArguments, timeout: 15)
        // Building can take a while.
        _ = try await conn.request("launch", DAPLaunch.arguments(for: request), timeout: 600)
        configured = true
        await sendBreakpoints(ledger.update(desired: pendingBreakpoints))
        state.launched()
        onEvent(.started)
        _ = try await conn.request("configurationDone", [:], timeout: 15)
    }

    private func delveExited() {
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        state.terminated()
        let rpc = self.rpc
        self.rpc = nil
        if let rpc { Task { await rpc.close() } }
        socket = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        onEvent(.terminated)
    }

    // MARK: - Breakpoints (DES-3)

    /// Mirrors the user's breakpoints (absolute path -> 0-based lines) to delve, asynchronously.
    public func setBreakpoints(_ all: [String: Set<Int>]) async {
        guard configured, !finished else {
            pendingBreakpoints = all
            return
        }
        await sendBreakpoints(ledger.update(desired: all))
    }

    private func sendBreakpoints(_ requests: [BreakpointRequest]) async {
        guard let rpc else { return }
        for req in requests {
            let args: JSONValue = [
                "source": ["path": .string(req.path), "name": .string((req.path as NSString).lastPathComponent)],
                "breakpoints": .array(req.lines.map { ["line": .number(Double($0))] }),
                "lines": .array(req.lines.map { .number(Double($0)) }),
            ]
            do {
                let body = try await rpc.request("setBreakpoints", args, timeout: 15)
                let acks = (body["breakpoints"]?.arrayValue ?? []).map {
                    BreakpointAck(id: $0["id"]?.intValue, line: $0["line"]?.intValue, verified: $0["verified"]?.boolValue ?? false)
                }
                ledger.record(req, acks: acks)
                let failed = (body["breakpoints"]?.arrayValue ?? []).compactMap { bp -> String? in
                    guard bp["verified"]?.boolValue == false else { return nil }
                    return bp["message"]?.stringValue
                }
                for message in failed {
                    onEvent(.output(category: "console", text: "breakpoint not set in \((req.path as NSString).lastPathComponent): \(message)\n"))
                }
            } catch {
                ledger.record(req, acks: [])
            }
        }
    }

    // MARK: - Events

    private func handleEvent(_ event: String, _ body: JSONValue) {
        guard !finished else { return }
        switch event {
        case "output":
            let text = body["output"]?.stringValue ?? ""
            if !text.isEmpty { onEvent(.output(category: body["category"]?.stringValue ?? "console", text: text)) }
        case "stopped":
            let reason = body["reason"]?.stringValue ?? "pause"
            let thread = body["threadId"]?.intValue
            let hits = (body["hitBreakpointIds"]?.arrayValue ?? []).compactMap(\.intValue)
            let text = body["description"]?.stringValue ?? body["text"]?.stringValue
            Task { await self.processStop(reason: reason, threadID: thread, hitIDs: hits, description: text) }
        case "continued":
            if state.resume() { onEvent(.continued) }
        case "exited":
            onEvent(.exited(code: body["exitCode"]?.intValue ?? 0))
        case "terminated":
            finish()
        default:
            break
        }
    }

    private func processStop(reason: String, threadID: Int?, hitIDs: [Int], description: String?) async {
        guard let rpc, !finished else { return }
        let wasRunning = state.phase == .running
        var tid = threadID
        if tid == nil {
            let threads = (try? await rpc.request("threads", [:], timeout: 10))?["threads"]?.arrayValue ?? []
            tid = threads.compactMap(DAPThread.init(json:)).first?.id
        }
        guard let tid else { return }
        let frames = (try? await fetchStack(rpc, threadID: tid, levels: 64)) ?? []
        guard !finished else { return }
        // DES-3: a stop at a breakpoint the user already removed continues silently.
        if wasRunning, state.phase == .running, let top = frames.first,
           ledger.shouldAutoContinue(reason: reason, hitBreakpointIDs: hitIDs, path: top.path.map(ledgerPath), line: top.line) {
            onEvent(.autoContinued(path: top.path ?? "", line: top.line))
            _ = try? await rpc.request("continue", ["threadId": .number(Double(tid))], timeout: 10)
            return
        }
        guard state.stopped() else { return }
        lastThreadID = tid
        onEvent(.stopped(DAPStop(reason: reason, description: description, threadID: tid, frames: frames)))
    }

    /// Maps a frame path from delve onto the key used for the user's breakpoints (symlinks).
    private func ledgerPath(_ path: String) -> String {
        if ledger.desired[path] != nil || ledger.sent[path] != nil { return path }
        let resolved = DAPSession.resolve(path)
        let keys = Set(ledger.desired.keys).union(ledger.sent.keys)
        return keys.first { DAPSession.resolve($0) == resolved } ?? path
    }

    static func resolve(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    // MARK: - Execution control (DES-4)

    public func resume() async throws {
        guard let rpc, let tid = lastThreadID else { throw DAPError.notRunning }
        guard state.resume() else { throw DAPError.notPaused }
        onEvent(.continued)
        _ = try await rpc.request("continue", ["threadId": .number(Double(tid))], timeout: 10)
    }

    public func stepOver() async throws { try await step("next") }
    public func stepIn() async throws { try await step("stepIn") }
    public func stepOut() async throws { try await step("stepOut") }

    private func step(_ command: String) async throws {
        guard let rpc, let tid = lastThreadID else { throw DAPError.notRunning }
        guard state.step() else { throw DAPError.notPaused }
        _ = try await rpc.request(command, ["threadId": .number(Double(tid))], timeout: 30)
    }

    /// Pauses a running program.
    public func pause() async throws {
        guard let rpc else { throw DAPError.notRunning }
        guard state.phase == .running else { return }
        _ = try await rpc.request("pause", ["threadId": .number(Double(lastThreadID ?? 1))], timeout: 10)
    }

    // MARK: - Inspection (only in a confirmed stop, DES-4)

    private func inspectable() throws -> JSONRPCConnection {
        guard let rpc else { throw DAPError.notRunning }
        guard state.canInspect else { throw DAPError.notPaused }
        return rpc
    }

    public func threads() async throws -> [DAPThread] {
        let rpc = try inspectable()
        let body = try await rpc.request("threads", [:], timeout: 10)
        return (body["threads"]?.arrayValue ?? []).compactMap(DAPThread.init(json:))
    }

    public func stackTrace(threadID: Int, levels: Int = 64) async throws -> [DAPStackFrame] {
        try await fetchStack(try inspectable(), threadID: threadID, levels: levels)
    }

    private func fetchStack(_ rpc: JSONRPCConnection, threadID: Int, levels: Int) async throws -> [DAPStackFrame] {
        let body = try await rpc.request("stackTrace", [
            "threadId": .number(Double(threadID)), "startFrame": 0, "levels": .number(Double(levels)),
        ], timeout: 15)
        return (body["stackFrames"]?.arrayValue ?? []).compactMap(DAPStackFrame.init(json:))
    }

    public func scopes(frameID: Int) async throws -> [DAPScope] {
        let body = try await inspectable().request("scopes", ["frameId": .number(Double(frameID))], timeout: 15)
        return (body["scopes"]?.arrayValue ?? []).compactMap(DAPScope.init(json:))
    }

    public func variables(reference: Int) async throws -> [DAPVariable] {
        let body = try await inspectable().request("variables", ["variablesReference": .number(Double(reference))], timeout: 15)
        return (body["variables"]?.arrayValue ?? []).compactMap(DAPVariable.init(json:))
    }

    public func evaluate(_ expression: String, frameID: Int?) async throws -> DAPEvaluateResult {
        var args: [String: JSONValue] = ["expression": .string(expression), "context": "repl"]
        if let frameID { args["frameId"] = .number(Double(frameID)) }
        let body = try await inspectable().request("evaluate", .object(args), timeout: 15)
        return DAPEvaluateResult(
            result: body["result"]?.stringValue ?? "",
            type: body["type"]?.stringValue ?? "",
            variablesReference: body["variablesReference"]?.intValue ?? 0
        )
    }

    // MARK: - Socket

    static func connect(host: String, port: UInt16) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DAPError.connectFailed(String(cString: strerror(errno))) }
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        let ipv4 = host == "localhost" ? "127.0.0.1" : host
        guard inet_pton(AF_INET, ipv4, &addr.sin_addr) == 1 else {
            Darwin.close(fd)
            throw DAPError.connectFailed("unsupported address \(host)")
        }
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let why = String(cString: strerror(errno))
            Darwin.close(fd)
            throw DAPError.connectFailed(why)
        }
        return fd
    }
}
