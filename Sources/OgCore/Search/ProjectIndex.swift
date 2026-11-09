import Foundation

// CONTRACT (owned by the Search agent; keep these signatures).

public struct FuzzyMatch: Sendable, Hashable {
    public var relativePath: String
    public var score: Int
    /// UTF-16 offsets into `relativePath` that matched (for highlighting).
    public var matchedOffsets: [Int]
}

public struct SearchHit: Sendable, Hashable {
    public var url: URL
    public var line: Int          // 0-based
    public var column: Int        // UTF-16, 0-based
    public var length: Int        // UTF-16
    public var lineText: String
}

public struct SearchOptions: Sendable, Hashable {
    public var caseSensitive = false
    public var wholeWord = false
    public var regex = false
    public var fileGlob: String? = nil
    public init() {}
}

/// File list of a project (skips .git, vendor/, node_modules/, build output).
public actor ProjectIndex {
    public let root: URL
    public init(root: URL) { self.root = root }
    public func refresh() async {}
    public func allFiles() async -> [String] { [] }
    public func fuzzy(_ query: String, limit: Int = 100) async -> [FuzzyMatch] { [] }
    /// Find in files. `onHit` batches arrive as they are found.
    public func search(_ query: String, options: SearchOptions, limit: Int = 5000) async -> [SearchHit] { [] }
}
