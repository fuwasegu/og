import Foundation

/// `if err != nil { return … }` offered as a completion right after a statement that assigns an error.
public struct GoErrCheckSuggestion: Sendable, Hashable {
    /// UTF-16 range to replace (the typed `i` / `if`).
    public var replaceRange: NSRange
    public var text: String
    /// Caret position inside `text` (UTF-16), at the end of the return line.
    public var caretOffset: Int
    /// The error variable, usually `err`.
    public var variable: String
}

public enum GoErrCheck {
    /// A suggestion when the caret line holds only a prefix of `if`, and the previous statement assigns
    /// an error-like variable (`err`, `fooErr`) with `:=` or `=`.
    /// `externalZeros` maps types from other packages to their zero value (`"tool.Tool": "nil"`).
    public static func suggestion(in ns: NSString, caret: Int, externalZeros: [String: String] = [:]) -> GoErrCheckSuggestion? {
        guard caret <= ns.length else { return nil }
        let lineRange = ns.lineRange(for: NSRange(location: caret, length: 0))
        let beforeCaret = ns.substring(with: NSRange(location: lineRange.location, length: caret - lineRange.location))
        let indent = String(beforeCaret.prefix { $0 == " " || $0 == "\t" })
        let typed = String(beforeCaret.dropFirst(indent.count))
        guard !typed.isEmpty, "if".hasPrefix(typed) else { return nil }
        // Nothing meaningful after the caret on this line.
        let afterLen = NSMaxRange(lineRange) - caret
        let after = ns.substring(with: NSRange(location: caret, length: afterLen)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard after.isEmpty else { return nil }

        guard let stmt = previousStatement(ns, beforeLineAt: lineRange.location), let v = assignedErrorVariable(stmt) else { return nil }

        let ret = GoPostfixEngine.errorReturn(ns, before: lineRange.location, errExpr: v, externalZeros: externalZeros)
        let head = "if \(v) != nil {\n\(indent)\t\(ret)"
        let text = head + "\n\(indent)}"
        return GoErrCheckSuggestion(
            replaceRange: NSRange(location: caret - (typed as NSString).length, length: (typed as NSString).length),
            text: text, caretOffset: (head as NSString).length, variable: v)
    }

    /// Types in the enclosing function's results whose zero value can't be known from this file
    /// (qualified names such as `tool.Tool`); the editor resolves them and passes `externalZeros`.
    public static func unresolvedResultTypes(in ns: NSString, caret: Int) -> [String] {
        let probe = GoPostfixEngine.errorReturn(ns, before: min(caret, ns.length), errExpr: "err")
        var out: [String] = []
        var rest = Substring(probe)
        while let r = rest.range(of: "*new(") {
            var depth = 1
            var i = r.upperBound
            while i < rest.endIndex, depth > 0 {
                if rest[i] == "(" { depth += 1 } else if rest[i] == ")" { depth -= 1 }
                if depth > 0 { i = rest.index(after: i) }
            }
            let t = String(rest[r.upperBound..<i])
            if t.contains("."), !out.contains(t) { out.append(t) }
            rest = i < rest.endIndex ? rest[rest.index(after: i)...] : ""
        }
        return out
    }

    /// Zero value from gopls hover markdown of a type (`type Tool interface {…}` -> "nil").
    public static func zeroValue(fromHover md: String, type: String) -> String? {
        guard let line = md.components(separatedBy: "\n").first(where: { $0.hasPrefix("type ") }) else { return nil }
        let parts = line.dropFirst(5).split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        var rhs = parts[1].trimmingCharacters(in: .whitespaces)
        if rhs.hasPrefix("= ") { rhs = String(rhs.dropFirst(2)) }   // alias
        if let c = rhs.range(of: "//") { rhs = String(rhs[..<c.lowerBound]).trimmingCharacters(in: .whitespaces) }
        if rhs.hasPrefix("interface") || rhs.hasPrefix("*") || rhs.hasPrefix("[]") || rhs.hasPrefix("map[") ||
            rhs.hasPrefix("chan") || rhs.hasPrefix("func") || rhs == "error" || rhs == "any" { return "nil" }
        if rhs.hasPrefix("struct") || rhs.hasPrefix("[") { return type + "{}" }
        if rhs == "string" { return "\"\"" }
        if rhs == "bool" { return "false" }
        let numeric: Set<String> = ["int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64",
                                    "uintptr", "float32", "float64", "complex64", "complex128", "byte", "rune"]
        if numeric.contains(rhs) { return "0" }
        return nil
    }

    /// The previous non-blank, non-comment line; for a call split over lines, the line where it starts.
    static func previousStatement(_ ns: NSString, beforeLineAt start: Int) -> String? {
        var end = start
        var lines: [String] = []
        while end > 0 {
            let r = ns.lineRange(for: NSRange(location: end - 1, length: 0))
            let line = ns.substring(with: r)
            end = r.location
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if lines.isEmpty && (t.isEmpty || t.hasPrefix("//")) { continue }
            lines.insert(t, at: 0)
            // Balance parens/brackets across the collected lines (strings are rare enough here to ignore).
            var depth = 0
            for c in lines.joined(separator: "\n") {
                if c == "(" || c == "[" || c == "{" { depth += 1 } else if c == ")" || c == "]" || c == "}" { depth -= 1 }
            }
            if depth >= 0 { return lines.joined(separator: "\n") }
            if lines.count > 40 { return nil }
        }
        return nil
    }

    /// `x, err := f()` / `err = g()` / `v, fooErr := h()` -> the error variable name.
    static func assignedErrorVariable(_ stmt: String) -> String? {
        let first = stmt.components(separatedBy: "\n").first ?? stmt
        guard let op = first.range(of: ":=") ?? first.range(of: " = ") ?? first.range(of: "=") else { return nil }
        var lhs = String(first[..<op.lowerBound]).trimmingCharacters(in: .whitespaces)
        if lhs.hasPrefix("var ") { lhs = String(lhs.dropFirst(4)) }
        // Reject comparisons and compound ops (`==`, `!=`, `+=`...).
        if let last = lhs.last, "=!<>+-*/%&|^:".contains(last) { return nil }
        let names = lhs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard names.allSatisfy({ $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." } && !$0.isEmpty }) else { return nil }
        return names.last { $0 == "err" || $0.hasSuffix("Err") }
    }
}
