import Foundation

// CONTRACT (owned by the Refactor agent; keep these signatures).

public struct FileDiffPreview: Sendable, Hashable {
    public var url: URL
    /// Unified diff text for display.
    public var unifiedDiff: String
    public var newText: String
}

public struct RenameRecord: Sendable, Hashable {
    /// Original content of every replaced file, for one-step undo.
    public var originals: [URL: String]
}

public enum RenameError: Error, Sendable, LocalizedError {
    case stageFailed(URL, String)
    case commitFailed(URL, String)
    public var errorDescription: String? {
        switch self {
        case .stageFailed(let u, let m): return "could not prepare \(u.lastPathComponent): \(m)"
        case .commitFailed(let u, let m): return "could not replace \(u.lastPathComponent): \(m) (all files restored)"
        }
    }
}

/// Two-phase rename apply (spec/design/refactor.fsl).
public enum RenameTransaction {
    /// Builds previews. `currentText` returns the editor's text for open files, else nil (read from disk).
    public static func preview(_ edit: LSPWorkspaceEdit, currentText: @Sendable (URL) -> String?) -> [FileDiffPreview] { [] }
    /// Stage all files to temps, then commit one by one with backups; rolls back on any failure.
    public static func apply(_ previews: [FileDiffPreview]) throws -> RenameRecord { RenameRecord(originals: [:]) }
    /// Restores every file in the record.
    public static func undo(_ record: RenameRecord) throws {}
    /// Applies LSP text edits to a string (edits may be unordered).
    public static func applyEdits(_ edits: [LSPTextEdit], to text: String) -> String { text }
}
