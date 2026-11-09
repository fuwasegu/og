import Foundation

// CONTRACT (owned by the Go-features agent; keep these signatures).

/// Result of a postfix template (`expr.err` + Tab).
public struct PostfixExpansion: Sendable, Hashable {
    /// Range to replace, as UTF-16 offsets in the whole document.
    public var replaceRange: NSRange
    public var text: String
    /// Caret position after insertion, UTF-16 offset relative to `replaceRange.location`.
    public var caretOffset: Int
    public var templateName: String
}

public enum GoPostfix {
    /// Template names, for completion UI.
    public static let templates: [String] = []
    /// Tries to expand a postfix template ending at `caret` (UTF-16 offset in `text`).
    public static func expansion(in text: String, caret: Int) -> PostfixExpansion? { nil }
}

public enum GoStructTagStyle: String, Sendable, CaseIterable { case snake, camel }

public enum GoStructTags {
    /// Adds/updates `json`, `yaml`... tags on the struct that contains `line` (0-based).
    /// Returns the full new source, or nil if no struct is found.
    public static func apply(to source: String, line: Int, keys: [String] = ["json"], style: GoStructTagStyle = .snake) -> String? { nil }
}

public struct GeneratedTest: Sendable, Hashable {
    public var testFileName: String   // e.g. "server_test.go"
    public var functionName: String   // e.g. "TestServer_Handle"
    /// Full content to write when the test file does not exist yet.
    public var newFileContent: String
    /// Code to append when the test file already exists.
    public var appendContent: String
}

public enum GoTableTest {
    /// Generates a table-driven test for the func/method declared at `line` (0-based).
    public static func generate(source: String, fileName: String, line: Int) -> GeneratedTest? { nil }
}
