import Foundation

public enum GoplsStatus: Sendable, Equatable {
    case stopped
    case starting
    case ready
    case crashed(retryIn: Double)
    case unavailable(String)

    public var label: String {
        switch self {
        case .stopped: return "gopls: stopped"
        case .starting: return "gopls: starting…"
        case .ready: return "gopls: ready"
        case .crashed(let s): return String(format: "gopls: restarting in %.0fs", s)
        case .unavailable(let why): return "gopls: \(why)"
        }
    }
}

/// Callbacks from the language server. Invoked off the main actor.
public struct GoplsEvents: Sendable {
    public var diagnostics: @Sendable (_ uri: String, _ version: Int?, _ items: [LSPDiagnostic]) -> Void
    public var status: @Sendable (GoplsStatus) -> Void
    public var applyEdit: @Sendable (LSPWorkspaceEdit) async -> Bool
    public var showMessage: @Sendable (String) -> Void

    public init(
        diagnostics: @escaping @Sendable (String, Int?, [LSPDiagnostic]) -> Void,
        status: @escaping @Sendable (GoplsStatus) -> Void,
        applyEdit: @escaping @Sendable (LSPWorkspaceEdit) async -> Bool,
        showMessage: @escaping @Sendable (String) -> Void
    ) {
        self.diagnostics = diagnostics
        self.status = status
        self.applyEdit = applyEdit
        self.showMessage = showMessage
    }
}

/// gopls supervisor + client (spec/design/lsp.fsl).
///
/// - DES-1: one ordered stdio stream; the last written version is what gopls "knows".
/// - DES-2: every process has a generation; responses from older processes are dropped.
/// - DES-3: after `initialize`, didOpen is replayed for every open document.
/// - DES-4: exponential backoff between restarts.
public actor GoplsSession {
    private enum Phase { case stopped, spawning, initializing, ready, crashed }

    private let root: URL
    private let events: GoplsEvents
    private var phase: Phase = .stopped
    private var generation = 0
    private var process: Process?
    private var rpc: JSONRPCConnection?
    private var backoff: Double = 0.5
    private var stopping = false
    /// Open documents: uri -> (version, text). Source of truth for replay.
    private var docs: [String: (version: Int, text: String)] = [:]

    public init(root: URL, events: GoplsEvents) {
        self.root = root
        self.events = events
    }

    public var isReady: Bool { phase == .ready }

    public func start() {
        stopping = false
        guard phase == .stopped || phase == .crashed else { return }
        spawn()
    }

    public func stop() async {
        stopping = true
        phase = .stopped
        if let rpc {
            _ = try? await rpc.request("shutdown", .null, timeout: 2)
            try? await rpc.notify("exit")
            await rpc.close()
        }
        process?.terminate()
        process = nil
        rpc = nil
        docs.removeAll()
        events.status(.stopped)
    }

    // MARK: - Lifecycle

    private func spawn() {
        guard let path = ToolLocator.shared.find("gopls") else {
            phase = .stopped
            events.status(.unavailable("not installed (brew install gopls)"))
            return
        }
        phase = .spawning
        events.status(.starting)
        generation += 1
        let gen = generation
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["serve"]
        proc.currentDirectoryURL = root
        proc.environment = ToolLocator.shared.environment
        let toServer = Pipe()
        let fromServer = Pipe()
        proc.standardInput = toServer
        proc.standardOutput = fromServer
        proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { [weak self] _ in
            Task { await self?.exited(generation: gen) }
        }
        do {
            try proc.run()
        } catch {
            phase = .crashed
            scheduleRestart()
            return
        }
        process = proc
        let conn = JSONRPCConnection(readFrom: fromServer.fileHandleForReading, writeTo: toServer.fileHandleForWriting)
        rpc = conn
        Task { await self.initialize(conn, generation: gen) }
    }

    private func initialize(_ conn: JSONRPCConnection, generation gen: Int) async {
        let events = self.events
        await conn.setHandlers(
            notification: { [weak self] method, params in
                await self?.handleNotification(method, params, generation: gen)
            },
            request: { method, params in
                switch method {
                case "workspace/applyEdit":
                    let ok = await events.applyEdit(LSPWorkspaceEdit(json: params["edit"] ?? .null))
                    return ["applied": .bool(ok)]
                case "workspace/configuration":
                    let count = params["items"]?.arrayValue?.count ?? 1
                    return .array(Array(repeating: GoplsSession.settings, count: count))
                default:
                    return .null
                }
            },
            close: {}
        )
        await conn.start()
        phase = .initializing
        let params: JSONValue = [
            "processId": .number(Double(ProcessInfo.processInfo.processIdentifier)),
            "rootUri": .string(root.lspURI),
            "workspaceFolders": [["uri": .string(root.lspURI), "name": .string(root.lastPathComponent)]],
            "initializationOptions": GoplsSession.settings,
            "capabilities": GoplsSession.capabilities
        ]
        do {
            _ = try await conn.request("initialize", params, timeout: 60)
            guard gen == generation else { return }
            try await conn.notify("initialized", [:])
        } catch {
            guard gen == generation else { return }
            process?.terminate()
            return
        }
        phase = .ready
        backoff = 0.5
        // DES-3: replay every open document at its current version.
        for (uri, doc) in docs {
            try? await conn.notify("textDocument/didOpen", [
                "textDocument": ["uri": .string(uri), "languageId": "go", "version": .number(Double(doc.version)), "text": .string(doc.text)]
            ])
        }
        events.status(.ready)
    }

    private func exited(generation gen: Int) async {
        guard gen == generation else { return }
        await rpc?.close()
        rpc = nil
        process = nil
        if stopping || phase == .stopped { return }
        phase = .crashed
        scheduleRestart()
    }

    private func scheduleRestart() {
        let delay = backoff
        backoff = min(backoff * 2, 30)
        events.status(.crashed(retryIn: delay))
        let gen = generation
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await self?.respawn(after: gen)
        }
    }

    private func respawn(after gen: Int) {
        guard gen == generation, phase == .crashed, !stopping else { return }
        spawn()
    }

    private func handleNotification(_ method: String, _ params: JSONValue, generation gen: Int) {
        guard gen == generation else { return }
        switch method {
        case "textDocument/publishDiagnostics":
            guard let uri = params["uri"]?.stringValue else { return }
            let items = (try? (params["diagnostics"] ?? .array([])).decode([LSPDiagnostic].self)) ?? []
            events.diagnostics(uri, params["version"]?.intValue, items)
        case "window/showMessage":
            if let m = params["message"]?.stringValue, (params["type"]?.intValue ?? 4) <= 2 { events.showMessage(m) }
        default:
            break
        }
    }

    // MARK: - Document sync (DES-1)

    public func open(uri: String, text: String, version: Int) async {
        docs[uri] = (version, text)
        guard phase == .ready, let rpc else { return }
        try? await rpc.notify("textDocument/didOpen", [
            "textDocument": ["uri": .string(uri), "languageId": "go", "version": .number(Double(version)), "text": .string(text)]
        ])
    }

    public func change(uri: String, text: String, version: Int) async {
        // Never let a late, older version overwrite a newer one (lsp.fsl NeverAhead / ordered stream).
        guard let current = docs[uri], version > current.version else { return }
        docs[uri] = (version, text)
        guard phase == .ready, let rpc else { return }
        try? await rpc.notify("textDocument/didChange", [
            "textDocument": ["uri": .string(uri), "version": .number(Double(version))],
            "contentChanges": [["text": .string(text)]]
        ])
    }

    public func save(uri: String) async {
        guard phase == .ready, let rpc, docs[uri] != nil else { return }
        try? await rpc.notify("textDocument/didSave", ["textDocument": ["uri": .string(uri)]])
    }

    public func close(uri: String) async {
        guard docs.removeValue(forKey: uri) != nil else { return }
        guard phase == .ready, let rpc else { return }
        try? await rpc.notify("textDocument/didClose", ["textDocument": ["uri": .string(uri)]])
    }

    public func didChangeWatchedFiles(_ uris: [String]) async {
        guard phase == .ready, let rpc, !uris.isEmpty else { return }
        try? await rpc.notify("workspace/didChangeWatchedFiles", [
            "changes": .array(uris.map { ["uri": .string($0), "type": 2] })
        ])
    }

    // MARK: - Requests (DES-2: dropped if the process changed meanwhile)

    private func call(_ method: String, _ params: JSONValue, timeout: TimeInterval = 15) async -> JSONValue? {
        guard phase == .ready, let rpc else { return nil }
        let gen = generation
        guard let result = try? await rpc.request(method, params, timeout: timeout) else { return nil }
        return gen == generation ? result : nil
    }

    private func docPos(_ uri: String, _ pos: LSPPosition) -> JSONValue {
        ["textDocument": ["uri": .string(uri)], "position": ["line": .number(Double(pos.line)), "character": .number(Double(pos.character))]]
    }

    public func completion(uri: String, position: LSPPosition) async -> [LSPCompletionItem]? {
        guard let r = await call("textDocument/completion", docPos(uri, position)) else { return nil }
        let items = r.arrayValue ?? r["items"]?.arrayValue ?? []
        return items.map(LSPCompletionItem.init(json:))
    }

    public func hover(uri: String, position: LSPPosition) async -> String? {
        guard let r = await call("textDocument/hover", docPos(uri, position)), let c = r["contents"] else { return nil }
        if let s = c.stringValue { return s }
        if let v = c["value"]?.stringValue { return v }
        if let a = c.arrayValue { return a.compactMap { $0.stringValue ?? $0["value"]?.stringValue }.joined(separator: "\n\n") }
        return nil
    }

    public func signatureHelp(uri: String, position: LSPPosition) async -> LSPSignatureHelp? {
        guard let r = await call("textDocument/signatureHelp", docPos(uri, position)) else { return nil }
        return LSPSignatureHelp(json: r)
    }

    private func locations(_ method: String, uri: String, position: LSPPosition, extra: [String: JSONValue] = [:]) async -> [LSPLocation] {
        var params = docPos(uri, position).objectValue ?? [:]
        for (k, v) in extra { params[k] = v }
        guard let r = await call(method, .object(params)) else { return [] }
        if let one = try? r.decode(LSPLocation.self) { return [one] }
        if let many = try? r.decode([LSPLocation].self) { return many }
        // LocationLink[]
        return (r.arrayValue ?? []).compactMap { link in
            guard let uri = link["targetUri"]?.stringValue,
                  let range = try? (link["targetSelectionRange"] ?? link["targetRange"] ?? .null).decode(LSPRange.self) else { return nil }
            return LSPLocation(uri: uri, range: range)
        }
    }

    public func definition(uri: String, position: LSPPosition) async -> [LSPLocation] {
        await locations("textDocument/definition", uri: uri, position: position)
    }

    public func typeDefinition(uri: String, position: LSPPosition) async -> [LSPLocation] {
        await locations("textDocument/typeDefinition", uri: uri, position: position)
    }

    public func implementation(uri: String, position: LSPPosition) async -> [LSPLocation] {
        await locations("textDocument/implementation", uri: uri, position: position)
    }

    public func references(uri: String, position: LSPPosition) async -> [LSPLocation] {
        await locations("textDocument/references", uri: uri, position: position, extra: ["context": ["includeDeclaration": false]])
    }

    public func documentSymbols(uri: String) async -> [LSPSymbol] {
        guard let r = await call("textDocument/documentSymbol", ["textDocument": ["uri": .string(uri)]]) else { return [] }
        return (r.arrayValue ?? []).map(LSPSymbol.init(json:))
    }

    public func workspaceSymbols(query: String) async -> [LSPSymbol] {
        guard let r = await call("workspace/symbol", ["query": .string(query)]) else { return [] }
        return (r.arrayValue ?? []).map(LSPSymbol.init(json:))
    }

    public func prepareRename(uri: String, position: LSPPosition) async -> (range: LSPRange, placeholder: String?)? {
        guard let r = await call("textDocument/prepareRename", docPos(uri, position)), !r.isNull else { return nil }
        if let range = try? r.decode(LSPRange.self) { return (range, nil) }
        if let range = try? (r["range"] ?? .null).decode(LSPRange.self) { return (range, r["placeholder"]?.stringValue) }
        return nil
    }

    public func rename(uri: String, position: LSPPosition, newName: String) async -> Result<LSPWorkspaceEdit, Error> {
        guard phase == .ready, let rpc else { return .failure(RPCError.closed) }
        var params = docPos(uri, position).objectValue ?? [:]
        params["newName"] = .string(newName)
        do {
            let r = try await rpc.request("textDocument/rename", .object(params), timeout: 60)
            return .success(LSPWorkspaceEdit(json: r))
        } catch {
            return .failure(error)
        }
    }

    public func codeActions(uri: String, range: LSPRange, diagnostics: [LSPDiagnostic], only: [String]? = nil) async -> [LSPCodeAction] {
        var context: [String: JSONValue] = ["diagnostics": (try? JSONValue.from(diagnostics)) ?? .array([])]
        if let only { context["only"] = .array(only.map { .string($0) }) }
        let params: JSONValue = [
            "textDocument": ["uri": .string(uri)],
            "range": (try? JSONValue.from(range)) ?? .null,
            "context": .object(context)
        ]
        guard let r = await call("textDocument/codeAction", params) else { return [] }
        return (r.arrayValue ?? []).map(LSPCodeAction.init(json:))
    }

    public func resolve(codeAction: LSPCodeAction) async -> LSPCodeAction {
        guard let r = await call("codeAction/resolve", codeAction.raw) else { return codeAction }
        return LSPCodeAction(json: r)
    }

    public func execute(command: JSONValue) async {
        guard let name = command["command"]?.stringValue else { return }
        _ = await call("workspace/executeCommand", ["command": .string(name), "arguments": command["arguments"] ?? .array([])], timeout: 60)
    }

    public func formatting(uri: String) async -> [LSPTextEdit]? {
        guard let r = await call("textDocument/formatting", [
            "textDocument": ["uri": .string(uri)],
            "options": ["tabSize": 4, "insertSpaces": false]
        ]) else { return nil }
        return (try? r.decode([LSPTextEdit].self)) ?? []
    }

    /// goimports-equivalent: the `source.organizeImports` code action.
    public func organizeImports(uri: String) async -> [LSPTextEdit] {
        let zero = LSPRange(start: .init(line: 0, character: 0), end: .init(line: 0, character: 0))
        let actions = await codeActions(uri: uri, range: zero, diagnostics: [], only: ["source.organizeImports"])
        return actions.first?.edit?.changes[uri] ?? []
    }

    public func inlayHints(uri: String, range: LSPRange) async -> [(position: LSPPosition, label: String)] {
        guard let r = await call("textDocument/inlayHint", [
            "textDocument": ["uri": .string(uri)], "range": (try? JSONValue.from(range)) ?? .null
        ]) else { return [] }
        return (r.arrayValue ?? []).compactMap { h in
            guard let pos = try? (h["position"] ?? .null).decode(LSPPosition.self) else { return nil }
            let label = h["label"]?.stringValue ?? (h["label"]?.arrayValue ?? []).compactMap { $0["value"]?.stringValue }.joined()
            return (pos, label)
        }
    }

    // MARK: - Static configuration

    static let settings: JSONValue = [
        "usePlaceholders": false,
        "completeUnimported": true,
        "staticcheck": false,
        "semanticTokens": false,
        "hints": ["parameterNames": true, "assignVariableTypes": false, "compositeLiteralFields": true]
    ]

    static let capabilities: JSONValue = [
        "workspace": [
            "applyEdit": true,
            "workspaceEdit": ["documentChanges": true],
            "configuration": true,
            "workspaceFolders": true,
            "didChangeWatchedFiles": ["dynamicRegistration": false],
            "symbol": ["dynamicRegistration": false]
        ],
        "textDocument": [
            "synchronization": ["didSave": true, "dynamicRegistration": false],
            "completion": ["completionItem": ["snippetSupport": true, "documentationFormat": ["plaintext", "markdown"]], "contextSupport": true],
            "hover": ["contentFormat": ["plaintext", "markdown"]],
            "signatureHelp": ["signatureInformation": ["parameterInformation": ["labelOffsetSupport": true]]],
            "definition": ["linkSupport": true],
            "implementation": ["linkSupport": true],
            "typeDefinition": ["linkSupport": true],
            "references": [:],
            "documentSymbol": ["hierarchicalDocumentSymbolSupport": true],
            "codeAction": ["codeActionLiteralSupport": ["codeActionKind": ["valueSet": ["quickfix", "refactor", "refactor.extract", "refactor.inline", "refactor.rewrite", "source", "source.organizeImports"]]], "resolveSupport": ["properties": ["edit"]]],
            "formatting": [:],
            "rename": ["prepareSupport": true],
            "publishDiagnostics": ["versionSupport": true, "relatedInformation": false],
            "inlayHint": [:]
        ],
        "window": ["workDoneProgress": false]
    ]
}
