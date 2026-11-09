import Foundation

// CONTRACT (owned by the Completion agent; keep these signatures).

/// Local-only FIM completion against llama-server (spec/design/completion.fsl).
public final class LocalCompletionClient: Sendable {
    public let endpoint: URL
    /// Returns nil unless `endpoint` is a loopback http(s) URL (DES-1).
    public init?(endpoint: URL) {
        guard LocalCompletionClient.isLoopback(endpoint) else { return nil }
        self.endpoint = endpoint
    }
    public static func isLoopback(_ url: URL) -> Bool { false }
    /// Streams completion text chunks for the caret between prefix and suffix.
    public func complete(prefix: String, suffix: String, maxTokens: Int = 64) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
