import Foundation

public struct LSPPosition: Codable, Sendable, Equatable {
    public let line: Int
    public let character: Int

    public init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }
}

public struct LSPRange: Codable, Sendable, Equatable {
    public let start: LSPPosition
    public let end: LSPPosition

    public init(start: LSPPosition, end: LSPPosition) {
        self.start = start
        self.end = end
    }
}

public struct LSPLocation: Codable, Sendable, Equatable {
    public let uri: String
    public let range: LSPRange
}

public enum LSPDiagnosticSeverity: Int, Codable, Sendable {
    case error = 1
    case warning = 2
    case information = 3
    case hint = 4
}

public struct LSPDiagnostic: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(range.start.line):\(range.start.character):\(message)" }
    public let range: LSPRange
    public let severity: LSPDiagnosticSeverity?
    public let code: String?
    public let source: String?
    public let message: String

    public init(
        range: LSPRange,
        severity: LSPDiagnosticSeverity?,
        code: String? = nil,
        source: String? = "gopls",
        message: String
    ) {
        self.range = range
        self.severity = severity
        self.code = code
        self.source = source
        self.message = message
    }
}

public struct LSPCompletionItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String { label + (detail ?? "") }
    public let label: String
    public let kind: Int?
    public let detail: String?
    public let insertText: String?
}

public struct LSPTextEdit: Codable, Sendable, Equatable {
    public let range: LSPRange
    public let newText: String

    public init(range: LSPRange, newText: String) {
        self.range = range
        self.newText = newText
    }
}

public struct LSPWorkspaceEdit: Codable, Sendable, Equatable {
    public let changes: [String: [LSPTextEdit]]?

    public init(changes: [String: [LSPTextEdit]]?) {
        self.changes = changes
    }
}

public enum GoplsHealthStatus: Sendable, Equatable {
    case stopped
    case starting
    case healthy(latencyMs: Double)
    case indexing(token: String, message: String)
    case unresponsive(restartAttempt: Int)
}

public actor GoplsClient {
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?

    private var nextRequestId: Int = 1
    private var pendingRequests: [Int: CheckedContinuation<Data, Error>] = [:]
    private var receiveBuffer = Data()

    private var workspaceRootURL: URL?
    private var openDocuments: [String: (version: Int, text: String)] = [:]

    private var watchdogTask: Task<Void, Never>?
    private var lastPongTimestamp: ContinuousClock.Instant = .now
    private var restartCount: Int = 0

    public private(set) var healthStatus: GoplsHealthStatus = .stopped

    private let diagnosticsContinuation: AsyncStream<(uri: String, diagnostics: [LSPDiagnostic])>.Continuation
    public nonisolated let diagnosticsStream: AsyncStream<(uri: String, diagnostics: [LSPDiagnostic])>

    private let healthContinuation: AsyncStream<GoplsHealthStatus>.Continuation
    public nonisolated let healthStream: AsyncStream<GoplsHealthStatus>

    public init() {
        var diagCont: AsyncStream<(uri: String, diagnostics: [LSPDiagnostic])>.Continuation!
        self.diagnosticsStream = AsyncStream { diagCont = $0 }
        self.diagnosticsContinuation = diagCont

        var hCont: AsyncStream<GoplsHealthStatus>.Continuation!
        self.healthStream = AsyncStream { hCont = $0 }
        self.healthContinuation = hCont
    }

    public func start(workspaceRoot: URL, goplsExecutablePath: String = "/usr/local/bin/gopls") async throws {
        self.workspaceRootURL = workspaceRoot
        updateHealth(.starting)

        let proc = Process()
        let resolvedPath = Self.resolveGoplsBinary(preferred: goplsExecutablePath)
        proc.executableURL = URL(fileURLWithPath: resolvedPath)
        proc.arguments = ["serve"]
        proc.currentDirectoryURL = workspaceRoot

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        self.process = proc
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutHandle = stdoutPipe.fileHandleForReading

        Self.attachProcessHandlers(
            stdoutHandle: stdoutPipe.fileHandleForReading,
            process: proc,
            onData: { [weak self] chunk in
                Task {
                    await self?.handleIncomingData(chunk)
                }
            },
            onTerminate: { [weak self] in
                Task {
                    await self?.handleUnexpectedTermination()
                }
            }
        )

        try proc.run()
        lastPongTimestamp = .now

        try await sendInitializeHandshake(workspaceRoot: workspaceRoot)
        updateHealth(.healthy(latencyMs: 1.0))
        startWatchdogLoop()
    }

    nonisolated private static func attachProcessHandlers(
        stdoutHandle: FileHandle,
        process: Process,
        onData: @escaping @Sendable (Data) -> Void,
        onTerminate: @escaping @Sendable () -> Void
    ) {
        stdoutHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            onData(chunk)
        }
        process.terminationHandler = { _ in
            onTerminate()
        }
    }

    public func shutdown() async {
        watchdogTask?.cancel()
        watchdogTask = nil
        _ = try? await sendRequest(method: "shutdown", params: EmptyParams())
        try? sendNotification(method: "exit", params: EmptyParams())
        stdoutHandle?.readabilityHandler = nil
        process?.terminate()
        process = nil
        updateHealth(.stopped)
    }

    private func startWatchdogLoop() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self = self else { break }
                await self.performHealthPing()
            }
        }
    }

    private func performHealthPing() async {
        guard process?.isRunning == true else { return }
        let start = ContinuousClock.now
        do {
            let _: Data = try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    try await self.sendRequest(
                        method: "workspace/symbol",
                        params: ["query": ""]
                    )
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(4))
                    throw GoplsError.timeout
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
            let elapsed = start.duration(to: .now)
            let ms = (Double(elapsed.components.seconds) * 1000.0) + (Double(elapsed.components.attoseconds) / 1e15)
            lastPongTimestamp = .now
            updateHealth(.healthy(latencyMs: max(0.5, ms)))
        } catch {
            await triggerAutoHealingRestart()
        }
    }

    public func triggerAutoHealingRestart() async {
        restartCount += 1
        updateHealth(.unresponsive(restartAttempt: restartCount))

        stdoutHandle?.readabilityHandler = nil
        process?.terminate()
        process = nil

        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: GoplsError.restarting)
        }
        pendingRequests.removeAll()
        receiveBuffer.removeAll()

        guard let root = workspaceRootURL else { return }
        do {
            try await start(workspaceRoot: root)
            for (uri, state) in openDocuments {
                try? sendDidOpen(uri: uri, text: state.text, version: state.version)
            }
        } catch {
            updateHealth(.unresponsive(restartAttempt: restartCount))
        }
    }

    private func handleUnexpectedTermination() async {
        guard healthStatus != .stopped else { return }
        await triggerAutoHealingRestart()
    }

    private func updateHealth(_ newStatus: GoplsHealthStatus) {
        self.healthStatus = newStatus
        healthContinuation.yield(newStatus)
    }

    public func sendDidOpen(uri: String, text: String, version: Int = 1) throws {
        openDocuments[uri] = (version: version, text: text)
        let params: [String: Any] = [
            "textDocument": [
                "uri": uri,
                "languageId": "go",
                "version": version,
                "text": text
            ]
        ]
        try sendRawNotification(method: "textDocument/didOpen", paramsDict: params)
    }

    public func sendDidChange(uri: String, text: String, version: Int) throws {
        openDocuments[uri] = (version: version, text: text)
        let params: [String: Any] = [
            "textDocument": [
                "uri": uri,
                "version": version
            ],
            "contentChanges": [
                ["text": text]
            ]
        ]
        try sendRawNotification(method: "textDocument/didChange", paramsDict: params)
    }

    public func sendDidSave(uri: String, text: String) throws {
        let params: [String: Any] = [
            "textDocument": ["uri": uri],
            "text": text
        ]
        try sendRawNotification(method: "textDocument/didSave", paramsDict: params)
    }

    public func requestCompletion(uri: String, position: LSPPosition) async throws -> [LSPCompletionItem] {
        let params: [String: Any] = [
            "textDocument": ["uri": uri],
            "position": ["line": position.line, "character": position.character]
        ]
        let data = try await sendRawRequest(method: "textDocument/completion", paramsDict: params)
        struct CompletionListWrapper: Decodable {
            let result: CompletionList?
            struct CompletionList: Decodable {
                let items: [LSPCompletionItem]?
            }
        }
        if let wrapped = try? JSONDecoder().decode(CompletionListWrapper.self, from: data),
           let items = wrapped.result?.items {
            return items
        }
        return []
    }

    public func requestDefinition(uri: String, position: LSPPosition) async throws -> [LSPLocation] {
        let params: [String: Any] = [
            "textDocument": ["uri": uri],
            "position": ["line": position.line, "character": position.character]
        ]
        let data = try await sendRawRequest(method: "textDocument/definition", paramsDict: params)
        struct MultiLocationResponse: Decodable {
            let result: [LSPLocation]?
        }
        struct SingleLocationResponse: Decodable {
            let result: LSPLocation?
        }
        if let multi = try? JSONDecoder().decode(MultiLocationResponse.self, from: data),
           let locs = multi.result {
            return locs
        }
        if let single = try? JSONDecoder().decode(SingleLocationResponse.self, from: data),
           let loc = single.result {
            return [loc]
        }
        return []
    }

    public func prepareRename(uri: String, position: LSPPosition) async throws -> LSPRange {
        let params: [String: Any] = [
            "textDocument": ["uri": uri],
            "position": ["line": position.line, "character": position.character]
        ]
        let data = try await sendRawRequest(method: "textDocument/prepareRename", paramsDict: params)
        struct PrepareRenameResponse: Decodable {
            let result: RangeOrPlaceholder?
            struct RangeOrPlaceholder: Decodable {
                let range: LSPRange?
                let start: LSPPosition?
                let end: LSPPosition?
            }
        }
        let decoded = try JSONDecoder().decode(PrepareRenameResponse.self, from: data)
        if let r = decoded.result?.range { return r }
        if let s = decoded.result?.start, let e = decoded.result?.end { return LSPRange(start: s, end: e) }
        throw GoplsError.renameRejected("指定されたシンボルはリネームできません。")
    }

    public func requestRename(uri: String, position: LSPPosition, newName: String) async throws -> LSPWorkspaceEdit {
        let params: [String: Any] = [
            "textDocument": ["uri": uri],
            "position": ["line": position.line, "character": position.character],
            "newName": newName
        ]
        let data = try await sendRawRequest(method: "textDocument/rename", paramsDict: params)
        struct RenameResponse: Decodable {
            let result: LSPWorkspaceEdit?
        }
        let decoded = try JSONDecoder().decode(RenameResponse.self, from: data)
        guard let edit = decoded.result else {
            throw GoplsError.renameRejected("gopls から WorkspaceEdit が返されませんでした。")
        }
        return edit
    }

    private struct EmptyParams: Codable {}

    private func sendInitializeHandshake(workspaceRoot: URL) async throws {
        let params: [String: Any] = [
            "processId": ProcessInfo.processInfo.processIdentifier,
            "rootUri": workspaceRoot.absoluteString,
            "capabilities": [
                "textDocument": [
                    "rename": ["prepareSupport": true],
                    "completion": ["completionItem": ["snippetSupport": false]],
                    "publishDiagnostics": ["relatedInformation": true]
                ],
                "window": [
                    "workDoneProgress": true
                ]
            ]
        ]
        _ = try await sendRawRequest(method: "initialize", paramsDict: params)
        try sendRawNotification(method: "initialized", paramsDict: [:])
    }

    private func sendRequest<P: Encodable>(method: String, params: P) async throws -> Data {
        let paramsData = try JSONEncoder().encode(params)
        let paramsObj = (try? JSONSerialization.jsonObject(with: paramsData)) as? [String: Any] ?? [:]
        return try await sendRawRequest(method: method, paramsDict: paramsObj)
    }

    private func sendNotification<P: Encodable>(method: String, params: P) throws {
        let paramsData = try JSONEncoder().encode(params)
        let paramsObj = (try? JSONSerialization.jsonObject(with: paramsData)) as? [String: Any] ?? [:]
        try sendRawNotification(method: method, paramsDict: paramsObj)
    }

    private func sendRawRequest(method: String, paramsDict: [String: Any]) async throws -> Data {
        let reqId = nextRequestId
        nextRequestId += 1

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": reqId,
            "method": method,
            "params": paramsDict
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        try writeFramedMessage(body)

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[reqId] = continuation
        }
    }

    private func sendRawNotification(method: String, paramsDict: [String: Any]) throws {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": paramsDict
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        try writeFramedMessage(body)
    }

    private func writeFramedMessage(_ body: Data) throws {
        guard let handle = stdinHandle else {
            throw GoplsError.notRunning
        }
        let header = "Content-Length: \(body.count)\r\n\r\n"
        var framed = Data(header.utf8)
        framed.append(body)
        try handle.write(contentsOf: framed)
    }

    private func handleIncomingData(_ chunk: Data) {
        receiveBuffer.append(chunk)
        let headerSeparator = Data("\r\n\r\n".utf8)

        while true {
            guard let headerRange = receiveBuffer.range(of: headerSeparator) else { break }
            let headerData = receiveBuffer.subdata(in: 0..<headerRange.lowerBound)
            guard let headerStr = String(data: headerData, encoding: .utf8),
                  let contentLength = Self.parseContentLength(from: headerStr) else {
                receiveBuffer.removeSubrange(0..<headerRange.upperBound)
                continue
            }

            let messageStart = headerRange.upperBound
            let messageEnd = messageStart + contentLength
            guard receiveBuffer.count >= messageEnd else { break }

            let bodyData = receiveBuffer.subdata(in: messageStart..<messageEnd)
            receiveBuffer.removeSubrange(0..<messageEnd)

            dispatchJSONRPCMessage(bodyData)
        }
    }

    private func dispatchJSONRPCMessage(_ data: Data) {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }

        if let id = json["id"] as? Int, json["method"] == nil, let continuation = pendingRequests.removeValue(forKey: id) {
            continuation.resume(returning: data)
            return
        }

        guard let method = json["method"] as? String else { return }

        if let serverReqId = json["id"] {
            let reply: [String: Any] = [
                "jsonrpc": "2.0",
                "id": serverReqId,
                "result": NSNull()
            ]
            if let replyData = try? JSONSerialization.data(withJSONObject: reply) {
                try? writeFramedMessage(replyData)
            }
        }

        switch method {
        case "textDocument/publishDiagnostics":
            struct DiagNotification: Decodable {
                let params: DiagParams
                struct DiagParams: Decodable {
                    let uri: String
                    let diagnostics: [LSPDiagnostic]
                }
            }
            if let notif = try? JSONDecoder().decode(DiagNotification.self, from: data) {
                diagnosticsContinuation.yield((uri: notif.params.uri, diagnostics: notif.params.diagnostics))
            }

        case "$/progress":
            if let params = json["params"] as? [String: Any],
               let value = params["value"] as? [String: Any] {
                let token = (params["token"] as? String)
                    ?? (params["token"] as? Int).map(String.init)
                    ?? "progress"
                let kind = value["kind"] as? String ?? ""
                let title = value["title"] as? String ?? "Indexing"
                if kind == "end" {
                    updateHealth(.healthy(latencyMs: 1.0))
                } else {
                    updateHealth(.indexing(token: token, message: title))
                }
            }

        default:
            break
        }
    }

    private static func parseContentLength(from header: String) -> Int? {
        for line in header.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let val = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                return Int(val)
            }
        }
        return nil
    }

    private static func resolveGoplsBinary(preferred: String) -> String {
        let candidates = [
            preferred,
            "\(NSHomeDirectory())/go/bin/gopls",
            "/opt/homebrew/bin/gopls",
            "/usr/local/bin/gopls"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return preferred
    }
}

public enum GoplsError: LocalizedError, Sendable {
    case notRunning
    case timeout
    case restarting
    case renameRejected(String)

    public var errorDescription: String? {
        switch self {
        case .notRunning: return "gopls プロセスが起動していません。"
        case .timeout: return "gopls の応答がタイムアウトしました。"
        case .restarting: return "gopls をバックグラウンドで自動復旧中です。"
        case .renameRejected(let reason): return reason
        }
    }
}
