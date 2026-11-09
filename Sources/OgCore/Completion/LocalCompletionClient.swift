import Foundation

// CONTRACT (owned by the Completion agent; keep these signatures).

/// Local-only FIM completion against llama-server (spec/design/completion.fsl).
public final class LocalCompletionClient: Sendable {
    /// Wire format of the server.
    public enum API: Sendable, Hashable, Codable {
        /// llama.cpp `/infill` (the server applies the model's FIM template).
        case llamaInfill
        /// OpenAI-compatible `/v1/completions` with a Qwen-style FIM prompt (mlx_lm.server).
        case openAIFIM(model: String)
    }

    public let endpoint: URL
    public let api: API

    /// Returns nil unless `endpoint` is a loopback http(s) URL (DES-1).
    public init?(endpoint: URL, api: API = .llamaInfill) {
        guard LocalCompletionClient.isLoopback(endpoint) else { return nil }
        self.endpoint = endpoint
        self.api = api
    }

    /// DES-1: only `http`/`https` on 127.0.0.1, ::1 or localhost (no credentials).
    public static func isLoopback(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        guard url.user == nil, url.password == nil else { return false }
        guard var host = url.host?.lowercased() else { return false }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return host == "127.0.0.1" || host == "::1" || host == "localhost"
    }

    /// Streams completion text chunks for the caret between prefix and suffix.
    /// The stream ends at a blank line or after `CompletionStreamLimiter.maxLines` lines; cancelling
    /// the consuming task cancels the HTTP request. Throws when the server is unreachable.
    public func complete(prefix: String, suffix: String, maxTokens: Int = 64) -> AsyncThrowingStream<String, Error> {
        let request = makeRequest(prefix: prefix, suffix: suffix, maxTokens: maxTokens)
        return AsyncThrowingStream { continuation in
            let task = Task {
                let session = URLSession(configuration: Self.sessionConfiguration)
                defer { session.invalidateAndCancel() }
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw LocalCompletionError.http(http.statusCode)
                    }
                    var limiter = CompletionStreamLimiter()
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard let event = SSEParser.parse(line: line) else { continue }
                        switch event {
                        case .error(let message):
                            throw LocalCompletionError.server(message)
                        case .done:
                            continuation.finish()
                            return
                        case .content(let text, let stop):
                            let (emit, finished) = limiter.feed(text)
                            if !emit.isEmpty { continuation.yield(emit) }
                            if finished || stop {
                                continuation.finish()
                                return
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Internals (internal for tests)

    static let sessionConfiguration: URLSessionConfiguration = {
        let c = URLSessionConfiguration.ephemeral
        c.connectionProxyDictionary = [:]          // never route loopback traffic through a proxy
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 60
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpCookieStorage = nil
        c.urlCache = nil
        return c
    }()

    /// llama.cpp `/infill` request.
    func makeRequest(prefix: String, suffix: String, maxTokens: Int) -> URLRequest {
        if case .openAIFIM(let model) = api {
            return makeOpenAIRequest(model: model, prefix: prefix, suffix: suffix, maxTokens: maxTokens)
        }
        var req = URLRequest(url: endpoint.appendingPathComponent("infill"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let body: [String: Any] = [
            "input_prefix": prefix,
            "input_suffix": suffix,
            "n_predict": max(1, maxTokens),
            "stream": true,
            "temperature": 0.1,
            "top_k": 40,
            "top_p": 0.9,
            "cache_prompt": true,
            "stop": ["\n\n"],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return req
    }
}

public enum LocalCompletionError: Error, Sendable, LocalizedError {
    case http(Int)
    case server(String)
    public var errorDescription: String? {
        switch self {
        case .http(let code): return "completion server returned HTTP \(code)"
        case .server(let m): return "completion server error: \(m)"
        }
    }
}

/// One server-sent event of the llama.cpp streaming API.
enum SSEEvent: Sendable, Equatable {
    case content(String, stop: Bool)
    case done
    case error(String)
}

enum SSEParser {
    /// Parses one SSE line (`data: {...}`); nil for comments, other fields and blank lines.
    static func parse(line: String) -> SSEEvent? {
        var s = Substring(line)
        if s.hasSuffix("\r") { s = s.dropLast() }
        guard s.hasPrefix("data:") else { return nil }
        s = s.dropFirst(5)
        if s.hasPrefix(" ") { s = s.dropFirst() }
        if s == "[DONE]" { return .done }
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let err = obj["error"] {
            if let e = err as? [String: Any] { return .error((e["message"] as? String) ?? "unknown error") }
            return .error(String(describing: err))
        }
        let stop = (obj["stop"] as? Bool) ?? false
        if let content = obj["content"] as? String { return .content(content, stop: stop) }
        // OpenAI-compatible shape, in case a proxy rewrites the stream.
        if let choices = obj["choices"] as? [[String: Any]], let first = choices.first {
            let text = (first["text"] as? String) ?? ((first["delta"] as? [String: Any])?["content"] as? String) ?? ""
            let finished = first["finish_reason"].map { !($0 is NSNull) } ?? false
            return .content(text, stop: stop || finished)
        }
        return stop ? .content("", stop: true) : nil
    }
}

/// Cuts the streamed text at the first blank line or after `maxLines` lines.
/// A newline (and the indentation after it) is held back until non-blank text
/// follows, so the shown text never ends with a dangling line break.
struct CompletionStreamLimiter: Sendable {
    static let maxLines = 8
    /// Text emitted so far.
    private(set) var text = ""
    private(set) var finished = false
    private var pending = ""          // "\n" + following spaces/tabs, not yet emitted
    private var lines = 1

    /// Returns the part of `chunk` to show and whether the stream should stop.
    mutating func feed(_ chunk: String) -> (String, Bool) {
        guard !finished else { return ("", true) }
        var emit = ""
        for ch in chunk {
            if ch == "\n" || ch == "\r\n" || ch == "\r" {
                if !pending.isEmpty && (text + emit).contains(where: { !$0.isWhitespace }) {
                    finished = true          // blank line ends the suggestion
                    break
                }
                if pending.isEmpty {
                    pending = "\n"
                } else {
                    pending += "\n"          // leading blank lines before any code are kept
                }
                continue
            }
            if !pending.isEmpty {
                if ch == " " || ch == "\t" { pending.append(ch); continue }
                let newLines = pending.filter { $0 == "\n" }.count
                if lines + newLines > Self.maxLines {
                    finished = true
                    break
                }
                lines += newLines
                emit += pending
                pending = ""
            }
            emit.append(ch)
        }
        text += emit
        return (emit, finished)
    }
}

extension LocalCompletionClient {
    /// OpenAI-compatible completion with the Qwen2.5-Coder FIM template.
    func makeOpenAIRequest(model: String, prefix: String, suffix: String, maxTokens: Int) -> URLRequest {
        var req = URLRequest(url: endpoint.appendingPathComponent("v1/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let body: [String: Any] = [
            "model": model,
            "prompt": "<|fim_prefix|>\(prefix)<|fim_suffix|>\(suffix)<|fim_middle|>",
            "max_tokens": max(1, maxTokens),
            "stream": true,
            "temperature": 0.1,
            "top_p": 0.9,
            "stop": ["\n\n", "<|endoftext|>", "<|fim_pad|>", "<|file_sep|>"],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return req
    }
}
