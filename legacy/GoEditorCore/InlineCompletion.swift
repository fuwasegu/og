import Foundation

public struct InlineCompletionContext: Sendable {
    public let prefix: String
    public let suffix: String
    public let filePath: String
    public let cursorPosition: (line: Int, column: Int)
    public let goStructuralHeader: String

    public init(
        prefix: String,
        suffix: String,
        filePath: String,
        cursorPosition: (line: Int, column: Int),
        goStructuralHeader: String = ""
    ) {
        self.prefix = prefix
        self.suffix = suffix
        self.filePath = filePath
        self.cursorPosition = cursorPosition
        self.goStructuralHeader = goStructuralHeader
    }
}

public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var _isCancelled: Bool = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCancelled
    }

    public func cancel() {
        lock.lock()
        _isCancelled = true
        lock.unlock()
    }
}

public protocol InlineCompletionProvider: Sendable {
    func isAvailable() async -> Bool
    func streamCompletion(
        context: InlineCompletionContext,
        cancellationToken: CancellationToken
    ) -> AsyncStream<String>
}

public struct GoFIMContextExtractor: Sendable {
    public init() {}

    public func buildContext(
        from buffer: TextBuffer,
        cursor: TextPosition,
        filePath: String,
        astAnalysis: GoASTAnalysis
    ) -> InlineCompletionContext {
        let cursorOffset = buffer.characterOffset(for: cursor)
        let prefixStart = max(0, cursorOffset - 2400)
        let suffixEnd = min(buffer.count, cursorOffset + 1000)

        let rawPrefix = buffer.substring(in: prefixStart..<cursorOffset)
        let rawSuffix = buffer.substring(in: cursorOffset..<suffixEnd)

        var structuralNotes: [String] = [
            "// File: \(URL(fileURLWithPath: filePath).lastPathComponent)",
            "package \(astAnalysis.packageName)"
        ]
        if !astAnalysis.importsBlock.isEmpty {
            structuralNotes.append(astAnalysis.importsBlock)
        }

        if let enclosingFunc = astAnalysis.functions.first(where: {
            cursor.line >= $0.startLine && cursor.line <= $0.endLine
        }) {
            if let recvType = enclosingFunc.receiverType,
               let matchingStruct = astAnalysis.types.first(where: { $0.name == recvType }) {
                let structLines = (matchingStruct.startLine...matchingStruct.endLine)
                    .map { buffer.lineContent(at: $0) }
                    .joined(separator: "\n")
                structuralNotes.append("// Receiver struct definition:\n" + structLines)
            }
        }

        let header = structuralNotes.joined(separator: "\n")
        return InlineCompletionContext(
            prefix: rawPrefix,
            suffix: rawSuffix,
            filePath: filePath,
            cursorPosition: (line: cursor.line, column: cursor.column),
            goStructuralHeader: header
        )
    }

    public static func formatQwenFIMPrompt(context: InlineCompletionContext) -> String {
        let enrichedPrefix: String
        if context.prefix.contains("package ") {
            enrichedPrefix = context.prefix
        } else {
            enrichedPrefix = context.goStructuralHeader + "\n\n" + context.prefix
        }
        return "<|fim_prefix|>\(enrichedPrefix)<|fim_suffix|>\(context.suffix)<|fim_middle|>"
    }
}

public struct LlamaServerCompletionProvider: InlineCompletionProvider {
    public let endpointURL: URL
    public let maxTokens: Int

    public init(
        endpointURL: URL = URL(string: "http://127.0.0.1:8080")!,
        maxTokens: Int = 96
    ) {
        self.endpointURL = endpointURL
        self.maxTokens = maxTokens
    }

    public func isAvailable() async -> Bool {
        let healthURL = endpointURL.appendingPathComponent("health")
        var req = URLRequest(url: healthURL)
        req.timeoutInterval = 0.8
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    public func streamCompletion(
        context: InlineCompletionContext,
        cancellationToken: CancellationToken
    ) -> AsyncStream<String> {
        let baseURL = self.endpointURL
        let maxPredict = self.maxTokens

        return AsyncStream { continuation in
            let task = Task {
                let compURL = baseURL.appendingPathComponent("completion")
                var request = URLRequest(url: compURL)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.timeoutInterval = 5.0

                let fimPrompt = GoFIMContextExtractor.formatQwenFIMPrompt(context: context)
                let body: [String: Any] = [
                    "prompt": fimPrompt,
                    "n_predict": maxPredict,
                    "temperature": 0.1,
                    "stop": ["<|endoftext|>", "<|fim_pad|>", "\n\n\n"],
                    "stream": true
                ]
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)

                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                        continuation.finish()
                        return
                    }

                    for try await line in bytes.lines {
                        if Task.isCancelled || cancellationToken.isCancelled {
                            break
                        }
                        guard line.hasPrefix("data: ") else { continue }
                        let jsonStr = String(line.dropFirst("data: ".count))
                        if jsonStr == "[DONE]" { break }
                        if let data = jsonStr.data(using: .utf8),
                           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                           let content = obj["content"] as? String {
                            continuation.yield(content)
                        }
                    }
                } catch {
                    if !Task.isCancelled && !cancellationToken.isCancelled {
                        if let fallback = Self.offlineGoHeuristicCompletion(for: context) {
                            continuation.yield(fallback)
                        }
                    }
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                cancellationToken.cancel()
                task.cancel()
            }
        }
    }

    private static func offlineGoHeuristicCompletion(for context: InlineCompletionContext) -> String? {
        let trimmedPrefix = context.prefix.trimmingCharacters(in: .whitespaces)
        if trimmedPrefix.hasSuffix("if err != nil {") {
            return "\n\t\treturn fmt.Errorf(\"unexpected error: %w\", err)\n\t}"
        }
        if trimmedPrefix.hasSuffix("func ") {
            return "ServeHTTP(w http.ResponseWriter, r *http.Request) {\n\t\n}"
        }
        if trimmedPrefix.hasSuffix("ctx, cancel := ") {
            return "context.WithTimeout(context.Background(), 5*time.Second)\n\tdefer cancel()"
        }
        return nil
    }
}

@MainActor
public final class InlineCompletionCoordinator {
    private let provider: any InlineCompletionProvider
    private let extractor = GoFIMContextExtractor()
    private var activeTask: Task<Void, Never>?
    private var activeToken: CancellationToken?
    public var debounceMilliseconds: UInt64 = 220

    public init(provider: any InlineCompletionProvider = LlamaServerCompletionProvider()) {
        self.provider = provider
    }

    public func cancelCurrentRequest() {
        activeToken?.cancel()
        activeToken = nil
        activeTask?.cancel()
        activeTask = nil
    }

    public func scheduleCompletion(
        buffer: TextBuffer,
        cursor: TextPosition,
        filePath: String,
        astAnalysis: GoASTAnalysis,
        onGhostTextUpdate: @escaping @MainActor (String) -> Void
    ) {
        cancelCurrentRequest()

        let token = CancellationToken()
        self.activeToken = token
        let delayMs = self.debounceMilliseconds
        let ctx = extractor.buildContext(
            from: buffer,
            cursor: cursor,
            filePath: filePath,
            astAnalysis: astAnalysis
        )
        let providerRef = self.provider

        activeTask = Task {
            try? await Task.sleep(for: .milliseconds(delayMs))
            guard !Task.isCancelled && !token.isCancelled else { return }

            var accumulated = ""
            let stream = providerRef.streamCompletion(context: ctx, cancellationToken: token)
            for await chunk in stream {
                if Task.isCancelled || token.isCancelled { break }
                accumulated += chunk
                onGhostTextUpdate(accumulated)
            }
        }
    }
}
