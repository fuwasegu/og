import Foundation

/// One constant of an enum-like Go type (`type T string` + `const ( A T = "a" ... )`).
public struct GoEnumConstant: Sendable, Hashable {
    public var name: String
    /// Display value: the literal, the computed `iota` value, or nil when it is an inherited expression.
    public var value: String?
    public init(name: String, value: String?) { self.name = name; self.value = value }
}

/// Finds the constants of a named type by reading top-level `const` declarations.
///
/// Rules follow the Go spec, so the result is deterministic (no name guessing):
/// - `A T = expr` and `A, B T = x, y` declare constants of type T.
/// - `A = T(expr)` is a conversion and also has type T.
/// - In a parenthesized block, a spec with only names repeats the previous type and expression (iota).
public enum GoEnumScanner {
    public static func constants(ofType typeName: String, in source: String) -> [GoEnumConstant] {
        let ns = source as NSString
        let toks = lex(ns)
        var out: [GoEnumConstant] = []
        var depth = 0
        var i = 0
        while i < toks.count {
            let t = toks[i]
            if t.text == "{" { depth += 1 } else if t.text == "}" { depth = max(0, depth - 1) }
            guard depth == 0, t.text == "const" else { i += 1; continue }
            i += 1
            while i < toks.count, toks[i].text == "\n" { i += 1 }
            guard i < toks.count else { break }
            var specs: [[Tok]] = []
            if toks[i].text == "(" {
                i += 1
                var cur: [Tok] = []
                var nest = 0
                while i < toks.count {
                    let x = toks[i]
                    if nest == 0, x.text == ")" { i += 1; break }
                    if "([{".contains(x.text) { nest += 1 } else if ")]}".contains(x.text) { nest -= 1 }
                    if nest == 0, x.text == "\n" || x.text == ";" {
                        if !cur.isEmpty { specs.append(cur) }
                        cur = []
                    } else {
                        cur.append(x)
                    }
                    i += 1
                }
                if !cur.isEmpty { specs.append(cur) }
            } else {
                var cur: [Tok] = []
                var nest = 0
                while i < toks.count {
                    let x = toks[i]
                    if "([{".contains(x.text) { nest += 1 } else if ")]}".contains(x.text) { nest -= 1 }
                    if nest == 0, x.text == "\n" || x.text == ";" { break }
                    cur.append(x)
                    i += 1
                }
                specs.append(cur)
            }
            out += evaluate(specs, typeName: typeName, ns: ns)
        }
        return out
    }

    // MARK: - Specs

    private static func evaluate(_ specs: [[Tok]], typeName: String, ns: NSString) -> [GoEnumConstant] {
        var out: [GoEnumConstant] = []
        var prevType: String?
        var prevExpr: [Tok] = []
        for (iota, spec) in specs.enumerated() {
            var names: [String] = []
            var k = 0
            while k < spec.count, spec[k].isIdent {
                names.append(spec[k].text)
                k += 1
                if k < spec.count, spec[k].text == "," { k += 1 } else { break }
            }
            guard !names.isEmpty else { continue }
            let rest = Array(spec[k...])
            var type: String?
            var expr: [Tok]
            var inherited = false
            if rest.isEmpty {
                type = prevType
                expr = prevExpr
                inherited = true
            } else if rest[0].text == "=" {
                expr = Array(rest.dropFirst())
                // `A = T(x)`: a conversion to T.
                if expr.count >= 2, expr[0].text == typeName, expr[1].text == "(" { type = typeName }
            } else {
                let eq = rest.firstIndex { $0.text == "=" } ?? rest.count
                type = text(of: Array(rest[..<eq]), ns)
                expr = eq < rest.count ? Array(rest[(eq + 1)...]) : []
            }
            if !inherited { prevType = type; prevExpr = expr }
            guard type == typeName else { continue }
            let values = splitTopLevelCommas(expr)
            for (n, name) in names.enumerated() where name != "_" {
                let e = n < values.count ? values[n] : []
                out.append(GoEnumConstant(name: name, value: display(e, iota: iota, inherited: inherited, ns: ns)))
            }
        }
        return out
    }

    private static func display(_ e: [Tok], iota: Int, inherited: Bool, ns: NSString) -> String? {
        guard !e.isEmpty else { return nil }
        if e.count == 1, e[0].text == "iota" { return String(iota) }
        // `iota + k` / `k + iota`
        if e.count == 3, e[1].text == "+" {
            if e[0].text == "iota", let k = Int(e[2].text) { return String(iota + k) }
            if e[2].text == "iota", let k = Int(e[0].text) { return String(iota + k) }
        }
        // `1 << iota`
        if e.count == 3, e[1].text == "<<", e[2].text == "iota", let k = Int(e[0].text), iota < 62 { return String(k << iota) }
        if inherited { return nil }
        return text(of: e, ns)
    }

    private static func splitTopLevelCommas(_ toks: [Tok]) -> [[Tok]] {
        var out: [[Tok]] = [[]]
        var nest = 0
        for t in toks {
            if "([{".contains(t.text) { nest += 1 } else if ")]}".contains(t.text) { nest -= 1 }
            if nest == 0, t.text == "," { out.append([]) } else { out[out.count - 1].append(t) }
        }
        return out
    }

    private static func text(of toks: [Tok], _ ns: NSString) -> String? {
        guard let first = toks.first, let last = toks.last else { return nil }
        return ns.substring(with: NSRange(location: first.start, length: last.end - first.start))
    }

    // MARK: - Lexer (comments dropped, strings kept whole, newlines kept)

    struct Tok {
        var text: String
        var start: Int
        var end: Int
        var isIdent: Bool
    }

    static func lex(_ ns: NSString) -> [Tok] {
        var out: [Tok] = []
        let n = ns.length
        var i = 0
        func ch(_ j: Int) -> unichar { j < n ? ns.character(at: j) : 0 }
        func identPart(_ c: unichar) -> Bool {
            (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c > 127
        }
        while i < n {
            let c = ch(i)
            if c == 10 { out.append(Tok(text: "\n", start: i, end: i + 1, isIdent: false)); i += 1; continue }
            if c == 32 || c == 9 || c == 13 { i += 1; continue }
            if c == 47, ch(i + 1) == 47 { while i < n, ch(i) != 10 { i += 1 }; continue }
            if c == 47, ch(i + 1) == 42 {
                let s = i
                i += 2
                var sawNewline = false
                while i < n, !(ch(i) == 42 && ch(i + 1) == 47) { if ch(i) == 10 { sawNewline = true }; i += 1 }
                i = min(n, i + 2)
                // A multi-line comment acts like a newline (spec: semicolon insertion).
                if sawNewline { out.append(Tok(text: "\n", start: s, end: i, isIdent: false)) }
                continue
            }
            let s = i
            if c == 34 || c == 39 {
                i += 1
                while i < n, ch(i) != c, ch(i) != 10 { if ch(i) == 92 { i += 1 }; i += 1 }
                i = min(n, i + 1)
            } else if c == 96 {
                i += 1
                while i < n, ch(i) != 96 { i += 1 }
                i = min(n, i + 1)
            } else if identPart(c) {
                let number = c >= 48 && c <= 57
                while i < n, identPart(ch(i)) || (number && ch(i) == 46) { i += 1 }
            } else if c == 60, ch(i + 1) == 60 || ch(i + 1) == 61 {
                i += 2
            } else if c == 62, ch(i + 1) == 62 || ch(i + 1) == 61 {
                i += 2
            } else {
                i += 1
            }
            let text = ns.substring(with: NSRange(location: s, length: i - s))
            let isIdent = identPart(c) && !(c >= 48 && c <= 57)
            out.append(Tok(text: text, start: s, end: i, isIdent: isIdent))
        }
        return out
    }
}
