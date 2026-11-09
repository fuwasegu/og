// Foundation helpers for tests live here (AGENTS.md: never import Foundation and Testing in one file).
import Foundation
@testable import OgCore

// MARK: - Postfix

/// Expands the postfix template at the `|` marker; returns the new text with `‸` at the caret, or nil.
func expandPostfix(_ marked: String) -> String? {
    let ns = marked as NSString
    let caret = ns.range(of: "|").location
    guard caret != NSNotFound else { return nil }
    let text = ns.replacingCharacters(in: NSRange(location: caret, length: 1), with: "")
    guard let e = GoPostfix.expansion(in: text, caret: caret) else { return nil }
    let out = (text as NSString).replacingCharacters(in: e.replaceRange, with: e.text) as NSString
    let c = e.replaceRange.location + e.caretOffset
    return out.substring(to: c) + "‸" + out.substring(from: c)
}

/// The template name matched at the `|` marker.
func postfixTemplateName(_ marked: String) -> String? {
    let ns = marked as NSString
    let caret = ns.range(of: "|").location
    let text = ns.replacingCharacters(in: NSRange(location: caret, length: 1), with: "")
    return GoPostfix.expansion(in: text, caret: caret)?.templateName
}

// MARK: - Text

func lineIndex(of needle: String, in text: String) -> Int {
    text.components(separatedBy: "\n").firstIndex { $0.contains(needle) } ?? -1
}

func textContains(_ text: String, _ needle: String) -> Bool { text.contains(needle) }

func edit(_ l1: Int, _ c1: Int, _ l2: Int, _ c2: Int, _ t: String) -> LSPTextEdit {
    LSPTextEdit(range: LSPRange(start: LSPPosition(line: l1, character: c1), end: LSPPosition(line: l2, character: c2)), newText: t)
}

// MARK: - Files

/// A temporary directory removed by `cleanup()`.
final class TempDir: @unchecked Sendable {
    let url: URL
    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("og-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func file(_ name: String, _ content: String) -> URL {
        let u = url.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? content.write(to: u, atomically: true, encoding: .utf8)
        return u
    }
    func subdir(_ name: String) -> URL {
        let u = url.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    func cleanup() {
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
            for case let f as URL in e {
                try? FileManager.default.setAttributes([.immutable: false, .posixPermissions: 0o755], ofItemAtPath: f.path)
            }
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        try? FileManager.default.removeItem(at: url)
    }
}

func readFile(_ u: URL) -> String? { try? String(contentsOf: u, encoding: .utf8) }
func listDir(_ u: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: u.path)) ?? []).sorted() }
func setReadOnlyDirectory(_ u: URL, _ readOnly: Bool) {
    try? FileManager.default.setAttributes([.posixPermissions: readOnly ? 0o555 : 0o755], ofItemAtPath: u.path)
}
func setImmutable(_ u: URL, _ on: Bool) {
    try? FileManager.default.setAttributes([.immutable: on], ofItemAtPath: u.path)
}
func uri(_ u: URL) -> String { u.absoluteString }
func preview(_ u: URL, _ newText: String) -> FileDiffPreview { FileDiffPreview(url: u, unifiedDiff: "", newText: newText) }
func standardized(_ u: URL) -> URL { u.standardizedFileURL }

/// File system whose commit fails for targets named `name`.
func failingCommitFileSystem(on name: String) -> RenameTransaction.FileSystem {
    var fs = RenameTransaction.FileSystem.live
    fs.replace = { temp, target in
        if target.lastPathComponent == name { throw CocoaError(.fileWriteUnknown) }
        try RenameTransaction.FileSystem.live.replace(temp, target)
    }
    return fs
}

// MARK: - Completion

func url(_ s: String) -> URL? { URL(string: s) }

func requestJSON(_ client: LocalCompletionClient, prefix: String, suffix: String, maxTokens: Int) -> [String: String] {
    let req = client.makeRequest(prefix: prefix, suffix: suffix, maxTokens: maxTokens)
    guard let body = req.httpBody, let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return [:] }
    var out: [String: String] = ["_path": req.url?.path ?? "", "_method": req.httpMethod ?? ""]
    for (k, v) in obj { out[k] = "\(v)" }
    return out
}

/// Feeds a canned SSE transcript through the parser and limiter like `complete` does.
func runCannedSSE(_ transcript: String) -> (text: String, error: String?) {
    var limiter = CompletionStreamLimiter()
    var text = ""
    for line in transcript.components(separatedBy: "\n") {
        guard let ev = SSEParser.parse(line: line) else { continue }
        switch ev {
        case .error(let m): return (text, m)
        case .done: return (text, nil)
        case .content(let c, let stop):
            let (emit, finished) = limiter.feed(c)
            text += emit
            if finished || stop { return (text, nil) }
        }
    }
    return (text, nil)
}

func sseLine(_ content: String, stop: Bool = false) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: ["content": content, "stop": stop])) ?? Data()
    return "data: " + String(decoding: data, as: UTF8.self)
}

/// GoErrCheck suggestion with the caret at the end of `src`.
func errCheckAtEnd(_ src: String) -> GoErrCheckSuggestion? {
    GoErrCheck.suggestion(in: src as NSString, caret: (src as NSString).length)
}

// MARK: - Go style (GoStyleTests)

/// `rule@line` (1-based) for every style finding.
func styleFindings(_ src: String, file: String = "x.go") -> [String] {
    GoStyle.check(src, fileName: file).map { "\($0.rule.id)@\($0.range.start.line + 1)" }
}

/// The new name of a rename fix for `rule`, or nil.
func styleRename(_ src: String, rule: String, file: String = "x.go") -> String? {
    guard let f = GoStyle.check(src, fileName: file).first(where: { $0.rule.id == rule })?.fix,
          case .rename(_, let name) = f.kind else { return nil }
    return name
}

/// The text after applying the edit fix for `rule`, or nil.
func styleApplyFix(_ src: String, rule: String, file: String = "x.go") -> String? {
    guard let f = GoStyle.check(src, fileName: file).first(where: { $0.rule.id == rule })?.fix,
          case .edits(let edits, _) = f.kind else { return nil }
    let ns = NSMutableString(string: src)
    let lines = TextLines(src)
    for r in edits.map({ (lines.nsRange(for: $0.range), $0.newText) }).sorted(by: { $0.0.location > $1.0.location }) {
        ns.replaceCharacters(in: r.0, with: r.1)
    }
    return ns as String
}

/// Style completions at the `|` marker.
func styleCompletionItems(_ marked: String, file: String = "x_test.go", package: [String] = [],
                          candidates: [(String, String?)] = []) -> [GoStyleCompletion] {
    let ns = marked as NSString
    let caret = ns.range(of: "|").location
    guard caret != NSNotFound else { return [] }
    let text = ns.replacingCharacters(in: NSRange(location: caret, length: 1), with: "") as NSString
    return GoStyleCompletions.items(in: text, caret: caret, fileName: file, packageSources: package,
                                    candidates: candidates.map { GoCompletionCandidate(label: $0.0, detail: $0.1) })
}

func styleLabels(_ marked: String, file: String = "x_test.go", package: [String] = [], candidates: [(String, String?)] = []) -> [String] {
    styleCompletionItems(marked, file: file, package: package, candidates: candidates).map(\.label)
}

/// Applies the style completion whose label contains `label` at the `|` marker; `‸` marks the caret.
func styleComplete(_ marked: String, label: String = "", file: String = "x_test.go", package: [String] = [],
                   candidates: [(String, String?)] = []) -> String? {
    guard let item = styleCompletionItems(marked, file: file, package: package, candidates: candidates)
        .first(where: { label.isEmpty || $0.label.contains(label) }) else { return nil }
    let ns = marked as NSString
    let caret = ns.range(of: "|").location
    let text = ns.replacingCharacters(in: NSRange(location: caret, length: 1), with: "") as NSString
    let out = text.replacingCharacters(in: item.replaceRange, with: item.text) as NSString
    let c = item.replaceRange.location + item.caretOffset
    return out.substring(to: c) + "‸" + out.substring(from: c)
}

func styleTriggers(_ marked: String) -> Bool {
    let ns = marked as NSString
    let caret = ns.range(of: "|").location
    let text = ns.replacingCharacters(in: NSRange(location: caret, length: 1), with: "") as NSString
    return GoStyleCompletions.shouldTrigger(in: text, caret: caret)
}
