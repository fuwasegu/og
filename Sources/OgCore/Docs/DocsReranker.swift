import Foundation

/// A scored candidate index returned by a local cross-encoder reranker (Issue #21, FR-11, DOC-10).
public struct DocsRerankerResult: Sendable, Hashable {
    public var index: Int
    /// Normalized relevance score in `[0.0, 1.0]` (sigmoid of cross-encoder logit).
    public var score: Double

    public init(index: Int, score: Double) {
        self.index = index
        self.score = score
    }
}

/// Protocol for local cross-encoder reranking of retrieved documentation candidates (FR-11, DOC-10).
public protocol DocsReranker: Sendable {
    var modelID: String { get }
    func rerank(query: String, documents: [String], topN: Int) async throws -> [DocsRerankerResult]
}

/// Loopback-only HTTP client for the og-owned Docs inference server's `/v1/rerank` endpoint
/// (FR-11, FR-16, D-9, DOC-6, DOC-10).
///
/// Refuses non-loopback URLs at initialization (`NeverLeavesMachine`) and reuses a single
/// ephemeral, proxy-free `URLSession`.
public final class LoopbackRerankerClient: DocsReranker, Sendable {
    public let endpoint: URL
    public let modelID: String
    private let session: URLSession

    public init?(endpoint: URL, modelID: String, timeoutInterval: TimeInterval? = nil) {
        guard LocalCompletionClient.isLoopback(endpoint) else { return nil }
        self.endpoint = endpoint
        self.modelID = modelID
        let cfg = LocalCompletionClient.sessionConfiguration.copy() as? URLSessionConfiguration ?? .ephemeral
        if let timeoutInterval {
            cfg.timeoutIntervalForRequest = timeoutInterval
            cfg.timeoutIntervalForResource = timeoutInterval
        }
        self.session = URLSession(configuration: cfg, delegate: LoopbackOnlySessionDelegate.shared, delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    public func rerank(query: String, documents: [String], topN: Int) async throws -> [DocsRerankerResult] {
        guard !documents.isEmpty else { return [] }
        let clampedTopN = max(1, min(topN, documents.count))

        var req = URLRequest(url: endpoint.appendingPathComponent("v1/rerank"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": modelID,
            "query": query,
            "documents": documents,
            "top_n": clampedTopN
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DocsStorageError.rerankFailed("HTTP \(http.statusCode)")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = obj["results"] as? [[String: Any]] else {
            throw DocsStorageError.rerankFailed("invalid rerank response")
        }

        var results: [DocsRerankerResult] = []
        results.reserveCapacity(items.count)
        for item in items {
            guard let idx = (item["index"] as? NSNumber)?.intValue,
                  idx >= 0, idx < documents.count,
                  let score = (item["relevance_score"] as? NSNumber)?.doubleValue,
                  score.isFinite else {
                continue
            }
            results.append(DocsRerankerResult(index: idx, score: score))
        }
        results.sort {
            if abs($0.score - $1.score) > 1e-9 { return $0.score > $1.score }
            return $0.index < $1.index
        }
        return results
    }
}
