import Foundation

public enum RPCError: Error, LocalizedError, Sendable {
    case closed
    case server(code: Int, message: String)
    case timeout
    case encoding

    public var errorDescription: String? {
        switch self {
        case .closed: return "connection closed"
        case .server(let code, let message): return "server error \(code): \(message)"
        case .timeout: return "request timed out"
        case .encoding: return "could not encode message"
        }
    }
}

/// Content-Length framed JSON-RPC 2.0 over a pair of file handles.
/// Used for gopls (stdio) and delve DAP (socket, with `dap: true` message shape).
public actor JSONRPCConnection {
    public typealias NotificationHandler = @Sendable (String, JSONValue) async -> Void
    public typealias RequestHandler = @Sendable (String, JSONValue) async -> JSONValue

    private let input: FileHandle   // we read from here
    private let output: FileHandle  // we write here
    private let dap: Bool
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var closed = false
    private var onNotification: NotificationHandler?
    private var onRequest: RequestHandler?
    private var onClose: (@Sendable () async -> Void)?
    private let parser = Locked(FrameParser())

    public init(readFrom input: FileHandle, writeTo output: FileHandle, dap: Bool = false) {
        self.input = input
        self.output = output
        self.dap = dap
    }

    public func setHandlers(
        notification: @escaping NotificationHandler,
        request: @escaping RequestHandler,
        close: @escaping @Sendable () async -> Void
    ) {
        onNotification = notification
        onRequest = request
        onClose = close
    }

    public func start() {
        let parser = self.parser
        input.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                Task { await self.handleClosed() }
                return
            }
            let messages = parser.withLock { p -> [Data] in
                p.append(data)
                return p.drain()
            }
            if messages.isEmpty { return }
            Task { await self.handle(messages: messages) }
        }
    }

    public func close() {
        input.readabilityHandler = nil
        handleClosed()
    }

    /// Sends a request and awaits its result.
    public func request(_ method: String, _ params: JSONValue = .null, timeout: TimeInterval = 30) async throws -> JSONValue {
        if closed { throw RPCError.closed }
        let id = nextID
        nextID += 1
        let message: JSONValue
        if dap {
            message = ["seq": .number(Double(id)), "type": "request", "command": .string(method), "arguments": params]
        } else {
            message = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]
        }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<JSONValue, Error>) in
            pending[id] = cont
            do {
                try write(message)
            } catch {
                pending[id] = nil
                cont.resume(throwing: error)
                return
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.expire(id)
            }
        }
    }

    public func notify(_ method: String, _ params: JSONValue = .null) throws {
        if closed { throw RPCError.closed }
        try write(["jsonrpc": "2.0", "method": .string(method), "params": params])
    }

    private func expire(_ id: Int) {
        if let cont = pending.removeValue(forKey: id) { cont.resume(throwing: RPCError.timeout) }
    }

    private func write(_ message: JSONValue) throws {
        guard let body = try? JSONEncoder().encode(message) else { throw RPCError.encoding }
        var frame = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        frame.append(body)
        do {
            try output.write(contentsOf: frame)
        } catch {
            throw RPCError.closed
        }
    }

    private func handle(messages: [Data]) async {
        for data in messages {
            guard let msg = try? JSONDecoder().decode(JSONValue.self, from: data) else { continue }
            if dap {
                await handleDAP(msg)
            } else {
                await handleLSP(msg)
            }
        }
    }

    private func handleLSP(_ msg: JSONValue) async {
        if let method = msg["method"]?.stringValue {
            let params = msg["params"] ?? .null
            if let id = msg["id"] {
                let result = await onRequest?(method, params) ?? .null
                try? write(["jsonrpc": "2.0", "id": id, "result": result])
            } else {
                await onNotification?(method, params)
            }
            return
        }
        guard let id = msg["id"]?.intValue, let cont = pending.removeValue(forKey: id) else { return }
        if let err = msg["error"] {
            cont.resume(throwing: RPCError.server(code: err["code"]?.intValue ?? 0, message: err["message"]?.stringValue ?? ""))
        } else {
            cont.resume(returning: msg["result"] ?? .null)
        }
    }

    private func handleDAP(_ msg: JSONValue) async {
        switch msg["type"]?.stringValue {
        case "response":
            guard let id = msg["request_seq"]?.intValue, let cont = pending.removeValue(forKey: id) else { return }
            if msg["success"]?.boolValue == false {
                let detail = msg["body"]?["error"]?["format"]?.stringValue
                let message = [msg["message"]?.stringValue, detail].compactMap { $0 }.joined(separator: ": ")
                cont.resume(throwing: RPCError.server(code: 0, message: message.isEmpty ? "request failed" : message))
            } else {
                cont.resume(returning: msg["body"] ?? .null)
            }
        case "event":
            await onNotification?(msg["event"]?.stringValue ?? "", msg["body"] ?? .null)
        case "request":
            let result = await onRequest?(msg["command"]?.stringValue ?? "", msg["arguments"] ?? .null) ?? .null
            let seq = nextID
            nextID += 1
            try? write(["seq": .number(Double(seq)), "type": "response", "request_seq": msg["seq"] ?? .null,
                        "success": true, "command": msg["command"] ?? .null, "body": result])
        default:
            break
        }
    }

    private func handleClosed() {
        guard !closed else { return }
        closed = true
        let waiting = pending
        pending.removeAll()
        for (_, cont) in waiting { cont.resume(throwing: RPCError.closed) }
        let onClose = self.onClose
        Task { await onClose?() }
    }
}

/// Incremental Content-Length frame parser.
struct FrameParser {
    private var buffer = Data()

    mutating func append(_ data: Data) { buffer.append(data) }

    mutating func drain() -> [Data] {
        var out: [Data] = []
        let separator = Data("\r\n\r\n".utf8)
        while let headerEnd = buffer.range(of: separator) {
            let header = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) ?? ""
            var length = -1
            for line in header.split(separator: "\r\n") {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2, parts[0].lowercased() == "content-length" {
                    length = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? -1
                }
            }
            guard length >= 0 else {
                buffer.removeSubrange(buffer.startIndex..<headerEnd.upperBound)
                continue
            }
            let bodyStart = headerEnd.upperBound
            guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { break }
            let bodyEnd = buffer.index(bodyStart, offsetBy: length)
            out.append(Data(buffer[bodyStart..<bodyEnd]))
            buffer.removeSubrange(buffer.startIndex..<bodyEnd)
        }
        if buffer.isEmpty { buffer = Data() }
        return out
    }
}
