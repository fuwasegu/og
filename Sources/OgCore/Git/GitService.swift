import Foundation

// CONTRACT (owned by the Git agent; keep these signatures).

public enum GitFileState: String, Sendable, Hashable {
    case modified, added, deleted, renamed, untracked, conflicted, ignored
}

public struct GitStatus: Sendable, Hashable {
    public var branch: String?
    /// Path relative to the repository root -> state.
    public var files: [String: GitFileState]
    public var hasStash: Bool
    public init(branch: String? = nil, files: [String: GitFileState] = [:], hasStash: Bool = false) {
        self.branch = branch; self.files = files; self.hasStash = hasStash
    }
}

public enum GitLineChangeKind: Sendable, Hashable { case added, modified, deleted }

/// A changed line range in the working copy relative to HEAD (0-based lines).
public struct GitLineChange: Sendable, Hashable {
    public var startLine: Int
    public var lineCount: Int
    public var kind: GitLineChangeKind
    public init(startLine: Int, lineCount: Int, kind: GitLineChangeKind) {
        self.startLine = startLine; self.lineCount = lineCount; self.kind = kind
    }
}

/// Serializes every git invocation through one queue (spec/design/vcs.fsl DES-1).
public actor GitService {
    public let root: URL
    public init(root: URL) { self.root = root }

    public func isRepository() async -> Bool { false }
    public func status() async -> GitStatus { GitStatus() }
    public func lineChanges(relativePath: String, currentText: String) async -> [GitLineChange] { [] }
    public func diff(relativePath: String) async -> String { "" }
    public func branches() async -> [String] { [] }
    public func commit(paths: [String], message: String) async throws {}
    public func checkout(branch: String) async throws {}
    public func createBranch(_ name: String) async throws {}
    public func stash() async throws {}
    public func stashPop() async throws {}
    public func rollback(relativePath: String) async throws {}
}
