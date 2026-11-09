import Foundation

public enum GoTokenKind: UInt8, Sendable {
    case keyword, type, builtin, string, number, comment, function, funcDecl, typeDecl, constant
}

public struct GoToken: Sendable, Hashable {
    public var location: Int   // UTF-16 offset
    public var length: Int
    public var kind: GoTokenKind
    public var range: NSRange { NSRange(location: location, length: length) }
}

/// A fast single-pass Go lexer for syntax highlighting (UTF-16 offsets).
public enum GoLexer {
    static let keywords: Set<String> = [
        "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func",
        "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct",
        "switch", "type", "var"
    ]
    static let types: Set<String> = [
        "bool", "byte", "complex64", "complex128", "error", "float32", "float64", "int", "int8", "int16", "int32",
        "int64", "rune", "string", "uint", "uint8", "uint16", "uint32", "uint64", "uintptr", "any", "comparable"
    ]
    static let builtins: Set<String> = [
        "append", "cap", "clear", "close", "complex", "copy", "delete", "imag", "len", "make", "max", "min", "new",
        "panic", "print", "println", "real", "recover"
    ]
    static let constants: Set<String> = ["true", "false", "nil", "iota"]

    public static func tokenize(_ text: String) -> [GoToken] {
        tokenize(text as NSString)
    }

    /// Tokenizes the whole text.
    public static func tokenize(_ text: NSString) -> [GoToken] {
        tokenize(text, range: NSRange(location: 0, length: text.length))
    }

    /// Tokenizes `range`. Starts in "normal" state, so callers should pass a range
    /// starting outside of a block comment / raw string (e.g. whole document).
    public static func tokenize(_ text: NSString, range: NSRange) -> [GoToken] {
        let n = range.length
        guard n > 0 else { return [] }
        var buf = [unichar](repeating: 0, count: n)
        text.getCharacters(&buf, range: range)
        let base = range.location
        var tokens: [GoToken] = []
        tokens.reserveCapacity(n / 6)
        var i = 0
        var prevIdent = ""      // previous identifier/keyword (for func/type declarations)
        var prevNonSpace: unichar = 0

        @inline(__always) func isIdentStart(_ c: unichar) -> Bool {
            (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || c == 95 || c > 127
        }
        @inline(__always) func isIdentPart(_ c: unichar) -> Bool {
            isIdentStart(c) || (c >= 48 && c <= 57)
        }
        @inline(__always) func isDigit(_ c: unichar) -> Bool { c >= 48 && c <= 57 }

        while i < n {
            let c = buf[i]
            // Whitespace
            if c == 32 || c == 9 || c == 10 || c == 13 { i += 1; continue }
            // Comments
            if c == 47, i + 1 < n {
                if buf[i + 1] == 47 {
                    let s = i
                    while i < n && buf[i] != 10 { i += 1 }
                    tokens.append(GoToken(location: base + s, length: i - s, kind: .comment))
                    continue
                }
                if buf[i + 1] == 42 {
                    let s = i
                    i += 2
                    while i + 1 < n && !(buf[i] == 42 && buf[i + 1] == 47) { i += 1 }
                    i = min(n, i + 2)
                    tokens.append(GoToken(location: base + s, length: i - s, kind: .comment))
                    continue
                }
            }
            // Strings
            if c == 34 || c == 39 {
                let s = i
                i += 1
                while i < n && buf[i] != c && buf[i] != 10 {
                    if buf[i] == 92 { i += 1 }
                    i += 1
                }
                i = min(n, i + 1)
                tokens.append(GoToken(location: base + s, length: i - s, kind: .string))
                prevNonSpace = c
                continue
            }
            if c == 96 {
                let s = i
                i += 1
                while i < n && buf[i] != 96 { i += 1 }
                i = min(n, i + 1)
                tokens.append(GoToken(location: base + s, length: i - s, kind: .string))
                prevNonSpace = c
                continue
            }
            // Numbers
            if isDigit(c) || (c == 46 && i + 1 < n && isDigit(buf[i + 1])) {
                let s = i
                i += 1
                while i < n && (isIdentPart(buf[i]) || buf[i] == 46 ||
                                ((buf[i] == 43 || buf[i] == 45) && (buf[i - 1] == 101 || buf[i - 1] == 69 || buf[i - 1] == 112 || buf[i - 1] == 80))) {
                    i += 1
                }
                tokens.append(GoToken(location: base + s, length: i - s, kind: .number))
                prevNonSpace = 48
                continue
            }
            // Identifiers / keywords
            if isIdentStart(c) {
                let s = i
                while i < n && isIdentPart(buf[i]) { i += 1 }
                let word = String(utf16CodeUnits: Array(buf[s..<i]), count: i - s)
                var j = i
                while j < n && (buf[j] == 32 || buf[j] == 9) { j += 1 }
                let nextIsParen = j < n && buf[j] == 40
                let nextIsBracket = j < n && buf[j] == 91
                var kind: GoTokenKind?
                if keywords.contains(word) {
                    kind = .keyword
                } else if prevIdent == "func" || (prevNonSpace == 41 && prevIdent != "" && nextIsParen && lastWasReceiverClose(tokens: tokens)) {
                    kind = .funcDecl
                } else if prevIdent == "type" && (prevNonSpace != 46) {
                    kind = .typeDecl
                } else if constants.contains(word) {
                    kind = .constant
                } else if types.contains(word) {
                    kind = .type
                } else if builtins.contains(word) && nextIsParen {
                    kind = .builtin
                } else if nextIsParen || (nextIsBracket && prevNonSpace == 46) {
                    kind = .function
                }
                if let kind { tokens.append(GoToken(location: base + s, length: i - s, kind: kind)) }
                prevIdent = word
                prevNonSpace = 97
                continue
            }
            if c == 41 { // ')' — keep prevIdent so `func (r *T) Name(` marks Name as a declaration
                prevNonSpace = c
                if receiverDepthClosed(buf: buf, at: i) { prevIdent = "func" } else { prevIdent = "" }
                i += 1
                continue
            }
            prevIdent = (c == 40 && prevIdent == "func") ? "func(" : ""
            prevNonSpace = c
            i += 1
        }
        return tokens
    }

    @inline(__always)
    private static func lastWasReceiverClose(tokens: [GoToken]) -> Bool { false }

    /// True if the ')' at `i` closes a method receiver: `func (r *T)`.
    private static func receiverDepthClosed(buf: [unichar], at i: Int) -> Bool {
        var depth = 0
        var j = i
        while j >= 0 {
            if buf[j] == 41 { depth += 1 } else if buf[j] == 40 {
                depth -= 1
                if depth == 0 { break }
            } else if buf[j] == 10 { return false }
            j -= 1
        }
        guard j > 0 else { return false }
        var k = j - 1
        while k >= 0 && (buf[k] == 32 || buf[k] == 9) { k -= 1 }
        guard k >= 3 else { return false }
        return buf[k] == 99 && buf[k - 1] == 110 && buf[k - 2] == 117 && buf[k - 3] == 102 // "func"
    }
}
