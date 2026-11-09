import Foundation

/// A small Go tokenizer used by the structural Go features (postfix templates,
/// struct tags, table tests). Unlike `GoLexer` (highlighting only), it keeps
/// every token, operators and newlines included, with UTF-16 offsets.
struct GoTok: Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        case ident, keyword, number, string, rawString, char, comment, op, newline
    }
    var kind: Kind
    /// UTF-16 offset in the scanned text.
    var start: Int
    var end: Int
    var text: String
    /// True for a string, rune or comment that is not terminated (runs to the end of the scanned range).
    var unterminated = false

    var isLiteral: Bool { kind == .number || kind == .string || kind == .rawString || kind == .char }
    var isCode: Bool { kind != .comment && kind != .newline }
    func isOp(_ s: String) -> Bool { kind == .op && text == s }
}

enum GoScanner {
    static let keywords: Set<String> = [
        "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func",
        "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct",
        "switch", "type", "var"
    ]

    private static let ops3: Set<String> = ["...", "<<=", ">>=", "&^="]
    private static let ops2: Set<String> = [
        ":=", "<-", "==", "!=", "<=", ">=", "&&", "||", "++", "--", "+=", "-=", "*=", "/=", "%=",
        "&=", "|=", "^=", "<<", ">>", "&^"
    ]

    @inline(__always) static func isIdentStart(_ c: unichar) -> Bool {
        (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || c == 95 || c > 127
    }
    @inline(__always) static func isIdentPart(_ c: unichar) -> Bool {
        isIdentStart(c) || (c >= 48 && c <= 57)
    }
    @inline(__always) static func isDigit(_ c: unichar) -> Bool { c >= 48 && c <= 57 }

    static func units(_ text: NSString, _ range: NSRange) -> [unichar] {
        var buf = [unichar](repeating: 0, count: range.length)
        if range.length > 0 { text.getCharacters(&buf, range: range) }
        return buf
    }

    /// Tokenizes `text` (UTF-16 offsets relative to the whole string).
    static func tokenize(_ text: String) -> [GoTok] {
        let ns = text as NSString
        return tokenize(ns, range: NSRange(location: 0, length: ns.length))
    }

    static func tokenize(_ text: NSString, range: NSRange) -> [GoTok] {
        let buf = units(text, range)
        let n = buf.count
        let base = range.location
        var toks: [GoTok] = []
        var i = 0
        func str(_ s: Int, _ e: Int) -> String { String(utf16CodeUnits: Array(buf[s..<e]), count: e - s) }
        func add(_ k: GoTok.Kind, _ s: Int, _ e: Int, open: Bool = false) {
            toks.append(GoTok(kind: k, start: base + s, end: base + e, text: str(s, e), unterminated: open))
        }
        while i < n {
            let c = buf[i]
            if c == 32 || c == 9 || c == 13 { i += 1; continue }
            if c == 10 { add(.newline, i, i + 1); i += 1; continue }
            if c == 47, i + 1 < n, buf[i + 1] == 47 {
                let s = i
                while i < n && buf[i] != 10 { i += 1 }
                add(.comment, s, i); continue
            }
            if c == 47, i + 1 < n, buf[i + 1] == 42 {
                let s = i
                i += 2
                while i + 1 < n && !(buf[i] == 42 && buf[i + 1] == 47) { i += 1 }
                let closed = i + 1 < n
                i = min(n, i + 2)
                add(.comment, s, i, open: !closed); continue
            }
            if c == 34 || c == 39 {
                let s = i
                i += 1
                while i < n && buf[i] != c && buf[i] != 10 {
                    if buf[i] == 92 { i += 1 }
                    i += 1
                }
                i = min(i, n)
                let closed = i < n && buf[i] == c
                if closed { i += 1 }
                add(c == 34 ? .string : .char, s, i, open: !closed); continue
            }
            if c == 96 {
                let s = i
                i += 1
                while i < n && buf[i] != 96 { i += 1 }
                let closed = i < n
                i = min(n, i + 1)
                add(.rawString, s, i, open: !closed); continue
            }
            if isDigit(c) || (c == 46 && i + 1 < n && isDigit(buf[i + 1])) {
                let s = i
                i += 1
                while i < n {
                    let d = buf[i]
                    if isIdentPart(d) { i += 1; continue }
                    if d == 46 {
                        // `1.5` / `1.` are floats; `10.for` (postfix template) is a number then a selector.
                        if i + 1 < n, isIdentStart(buf[i + 1]) { break }
                        i += 1; continue
                    }
                    if (d == 43 || d == 45), let p = Optional(buf[i - 1]), p == 101 || p == 69 || p == 112 || p == 80 {
                        // exponent sign (1e+9, 0x1p-2); not for hex digits like 0xE+1 (rare)
                        i += 1; continue
                    }
                    break
                }
                add(.number, s, i); continue
            }
            if isIdentStart(c) {
                let s = i
                while i < n && isIdentPart(buf[i]) { i += 1 }
                let w = str(s, i)
                toks.append(GoTok(kind: keywords.contains(w) ? .keyword : .ident, start: base + s, end: base + i, text: w))
                continue
            }
            if i + 3 <= n, ops3.contains(str(i, i + 3)) { add(.op, i, i + 3); i += 3; continue }
            if i + 2 <= n, ops2.contains(str(i, i + 2)) { add(.op, i, i + 2); i += 2; continue }
            add(.op, i, i + 1)
            i += 1
        }
        return toks
    }

    /// Lexical context at a UTF-16 offset: true when inside a string, rune or comment.
    static func isInsideStringOrComment(_ text: NSString, offset: Int) -> Bool {
        let o = max(0, min(offset, text.length))
        for t in tokenize(text, range: NSRange(location: 0, length: o)).reversed() {
            if t.end < o { return false }
            switch t.kind {
            case .comment:
                // A line comment runs to the caret; a closed block comment ending exactly at the caret does not.
                return t.text.hasPrefix("//") || t.unterminated
            case .string, .char, .rawString:
                return t.unterminated
            default:
                return false
            }
        }
        return false
    }

    /// Index of the bracket matching the opener at `open` (`(`, `[`, `{`), or nil.
    static func matchForward(_ toks: [GoTok], _ open: Int) -> Int? {
        var depth = 0
        var i = open
        while i < toks.count {
            let t = toks[i]
            if t.kind == .op {
                if t.text == "(" || t.text == "[" || t.text == "{" { depth += 1 }
                if t.text == ")" || t.text == "]" || t.text == "}" {
                    depth -= 1
                    if depth == 0 { return i }
                }
            }
            i += 1
        }
        return nil
    }

    /// Index of the bracket matching the closer at `close`, or nil.
    static func matchBackward(_ toks: [GoTok], _ close: Int) -> Int? {
        var depth = 0
        var i = close
        while i >= 0 {
            let t = toks[i]
            if t.kind == .op {
                if t.text == ")" || t.text == "]" || t.text == "}" { depth += 1 }
                if t.text == "(" || t.text == "[" || t.text == "{" {
                    depth -= 1
                    if depth == 0 { return i }
                }
            }
            i -= 1
        }
        return nil
    }

    /// Renders code tokens as gofmt-style single-line type/expression text.
    static func render(_ toks: ArraySlice<GoTok>) -> String {
        var out = ""
        var prev: GoTok?
        for t in toks where t.isCode {
            if let p = prev, needsSpace(p, t) { out += " " }
            out += t.text
            prev = t
        }
        return out
    }

    private static func isWord(_ t: GoTok) -> Bool {
        t.kind == .ident || t.kind == .keyword || t.isLiteral
    }

    private static func needsSpace(_ p: GoTok, _ t: GoTok) -> Bool {
        if t.isOp(",") || t.isOp(")") || t.isOp("]") || t.isOp(".") || t.isOp(";") { return false }
        if p.isOp(".") || p.isOp("(") || p.isOp("[") || p.isOp("*") || p.isOp("...") || p.isOp("~") || p.isOp("&") { return false }
        if p.isOp(",") || p.isOp(";") || p.isOp("|") || t.isOp("|") { return true }
        if p.isOp("{") { return !t.isOp("}") }
        if t.isOp("}") { return !p.isOp("{") }
        if t.isOp("{") { return !(p.kind == .keyword && (p.text == "struct" || p.text == "interface")) }
        if t.isOp("<-") { return !(p.kind == .keyword && p.text == "chan") }
        if p.isOp("<-") { return !(t.kind == .keyword && t.text == "chan") }
        if p.isOp(")") { return true }
        if p.isOp("]") { return false }
        if isWord(p) && isWord(t) { return true }
        if p.kind == .keyword && (p.text == "chan" || p.text == "func") { return !t.isOp("(") || p.text == "chan" }
        if isWord(p) && (t.isOp("*") || t.isOp("[") && p.kind == .keyword && p.text == "chan") { return true }
        return false
    }
}
