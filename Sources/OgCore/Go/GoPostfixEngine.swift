import Foundation

/// Implementation of `GoPostfix` (GoLand-style postfix templates).
enum GoPostfixEngine {
    static let templateNames = [
        "err", "nn", "nil", "not", "if", "var", "for", "forr", "range", "return", "print",
        "len", "par", "go", "defer", "switch"
    ]
    /// Templates that produce an expression (usable anywhere); the rest are statements.
    private static let expressionTemplates: Set<String> = ["not", "len", "par"]
    private static let caretMark: Character = "\u{1}"

    static func expansion(in text: String, caret: Int) -> PostfixExpansion? {
        let ns = text as NSString
        guard caret > 1, caret <= ns.length else { return nil }
        // Current line.
        var lineStart = caret
        while lineStart > 0 {
            let c = ns.character(at: lineStart - 1)
            if c == 10 || c == 13 { break }
            lineStart -= 1
        }
        var lineEnd = caret
        while lineEnd < ns.length {
            let c = ns.character(at: lineEnd)
            if c == 10 || c == 13 { break }
            lineEnd += 1
        }
        let toks = GoScanner.tokenize(ns, range: NSRange(location: lineStart, length: caret - lineStart))
        guard toks.count >= 3, let name = toks.last, name.end == caret,
              name.kind == .ident || name.kind == .keyword, templateNames.contains(name.text) else { return nil }
        let dotIdx = toks.count - 2
        let dot = toks[dotIdx]
        guard dot.isOp("."), dot.end == name.start, dotIdx >= 1, toks[dotIdx - 1].end == dot.start else { return nil }
        guard !GoScanner.isInsideStringOrComment(ns, offset: caret) else { return nil }
        // The dot itself must be code (not e.g. the end of a line comment).
        guard toks.allSatisfy({ $0.kind != .comment }) else { return nil }

        guard var s = primaryStart(toks, dotIdx - 1) else { return nil }
        // Absorb unary operators: `!ok.if` → `if !ok {`.
        while s > 0 {
            let u = toks[s - 1]
            guard u.kind == .op, ["!", "-", "+", "^", "*", "&", "<-"].contains(u.text), u.end == toks[s].start else { break }
            if s >= 2, endsOperand(toks[s - 2]) { break }
            s -= 1
        }
        let exprToks = Array(toks[s..<dotIdx])
        let exprStart = toks[s].start
        var expr = ns.substring(with: NSRange(location: exprStart, length: dot.start - exprStart))
        let template = name.text
        // `T{...}` in an if/for/switch header must be parenthesized (spec: composite literal parsing ambiguity).
        let headerTemplates: Set<String> = ["err", "nn", "nil", "if", "for", "forr", "range", "switch"]
        if headerTemplates.contains(template), let f = exprToks.first, f.kind == .ident || f.isOp("*") || f.isOp("&"),
           exprToks.contains(where: { $0.isOp("{") }) {
            expr = "(\(expr))"
        }

        let isStatement = !expressionTemplates.contains(template)
        if isStatement {
            // Only at the start of a statement, with nothing but a comment after the caret.
            guard s == 0 else { return nil }
            let rest = ns.substring(with: NSRange(location: caret, length: lineEnd - caret))
                .trimmingCharacters(in: .whitespaces)
            guard rest.isEmpty || rest.hasPrefix("//") else { return nil }
        }
        // `fmt.err` while typing a package selector is not an expression.
        if exprToks.count == 1, exprToks[0].kind == .ident {
            let all = GoScanner.tokenize(ns, range: NSRange(location: 0, length: lineStart)).filter(\.isCode)
            if GoSignature.imports(all).contains(where: { $0.name == exprToks[0].text }) { return nil }
        }

        var indent = ""
        var k = lineStart
        while k < caret {
            let c = ns.character(at: k)
            guard c == 32 || c == 9 else { break }
            indent.append(Character(UnicodeScalar(UInt8(c))))
            k += 1
        }
        let body = indent + "\t"
        let m = String(caretMark)
        let isCall = exprToks.last?.isOp(")") ?? false
        let intLike = (exprToks.count == 1 && exprToks[0].kind == .number) ||
            (exprToks.first.map { $0.kind == .ident && ($0.text == "len" || $0.text == "cap") } ?? false) && isCall

        var out: String
        switch template {
        case "err":
            let ret = errorReturn(ns, before: lineStart, errExpr: isCall ? "err" : expr)
            if isCall {
                out = "if err := \(expr); err != nil {\n\(body)\(ret)\(m)\n\(indent)}"
            } else {
                out = "if \(expr) != nil {\n\(body)\(ret)\(m)\n\(indent)}"
            }
        case "nn": out = "if \(expr) != nil {\n\(body)\(m)\n\(indent)}"
        case "nil": out = "if \(expr) == nil {\n\(body)\(m)\n\(indent)}"
        case "not": out = expr.hasPrefix("!") && exprToks.count > 1 ? String(expr.dropFirst()) + m : "!\(expr)\(m)"
        case "if": out = "if \(expr) {\n\(body)\(m)\n\(indent)}"
        case "var": out = "\(variableName(exprToks, exprText: expr)) := \(expr)\(m)"
        case "for":
            out = intLike ? "for i := range \(expr) {\n\(body)\(m)\n\(indent)}"
                : "for _, v := range \(expr) {\n\(body)\(m)\n\(indent)}"
        case "forr": out = "for i := range \(expr) {\n\(body)\(m)\n\(indent)}"
        case "range":
            out = intLike ? "for i := range \(expr) {\n\(body)\(m)\n\(indent)}"
                : "for k, v := range \(expr) {\n\(body)\(m)\n\(indent)}"
        case "return": out = "return \(expr)\(m)"
        case "print": out = "fmt.Println(\(expr))\(m)"
        case "len": out = "len(\(expr))\(m)"
        case "par": out = "(\(expr))\(m)"
        case "go", "defer": out = isCall ? "\(template) \(expr)\(m)" : "\(template) \(expr)(\(m))"
        case "switch": out = "switch \(expr) {\n\(indent)case \(m):\n\(indent)}"
        default: return nil
        }
        guard let markIdx = out.firstIndex(of: caretMark) else { return nil }
        let caretOffset = (String(out[..<markIdx]) as NSString).length
        out.remove(at: markIdx)
        return PostfixExpansion(
            replaceRange: NSRange(location: exprStart, length: caret - exprStart),
            text: out, caretOffset: caretOffset, templateName: template)
    }

    // MARK: - Expression boundaries

    /// Token that can end an operand (so a following `(`/`[` is a call/index, and an operator after it is binary).
    static func endsOperand(_ t: GoTok) -> Bool {
        t.kind == .ident || t.isOp(")") || t.isOp("]") || t.isOp("}") || t.isLiteral
    }

    /// Start index of the maximal primary expression ending at token `end`, or nil.
    static func primaryStart(_ toks: [GoTok], _ end: Int) -> Int? {
        var k = end
        func adjacentPrev(_ i: Int) -> GoTok? {
            i > 0 && toks[i - 1].end == toks[i].start ? toks[i - 1] : nil
        }
        while k >= 0 {
            let t = toks[k]
            if t.isOp(")") || t.isOp("]") {
                guard let o = GoScanner.matchBackward(toks, k), toks[o].text == (t.text == ")" ? "(" : "[") else { return nil }
                if let p = adjacentPrev(o) {
                    if t.isOp(")"), p.isOp(".") { k = o - 2; continue }        // x.(T)
                    if endsOperand(p) { k = o - 1; continue }                   // call / index / instantiation
                }
                return t.isOp(")") ? o : nil                                     // (a + b)
            }
            if t.isOp("}") {
                guard let o = GoScanner.matchBackward(toks, k), toks[o].isOp("{"), o > 0 else { return nil }
                return typeStart(toks, o - 1)                                    // T{...}
            }
            if t.kind == .ident {
                if let p = adjacentPrev(k) {
                    if p.isOp(".") { k -= 2; continue }                          // selector
                    if p.isOp("]") { return typeStart(toks, k) }                 // []byte(x)
                }
                return k
            }
            if t.isLiteral { return k }
            return nil
        }
        return nil
    }

    /// Start of a type expression ending at `end` (`pkg.T`, `[]T`, `map[K]V`, `*T`, `G[int]`, `struct{...}`).
    static func typeStart(_ toks: [GoTok], _ end: Int) -> Int? {
        guard end >= 0 else { return nil }
        var i = end
        let t = toks[i]
        if t.kind == .ident {
            if i >= 2, toks[i - 1].isOp("."), toks[i - 2].kind == .ident { i -= 2 }
        } else if t.isOp("]"), let o = GoScanner.matchBackward(toks, i), o > 0, toks[o - 1].kind == .ident, toks[o - 1].end == toks[o].start {
            i = o - 1
            if i >= 2, toks[i - 1].isOp("."), toks[i - 2].kind == .ident { i -= 2 }
        } else if t.isOp("}"), let o = GoScanner.matchBackward(toks, i), o > 0, toks[o - 1].kind == .keyword,
                  toks[o - 1].text == "struct" || toks[o - 1].text == "interface" {
            i = o - 1
        } else {
            return nil
        }
        while i > 0 {
            let p = toks[i - 1]
            guard p.end == toks[i].start else { break }
            if p.isOp("]"), let o = GoScanner.matchBackward(toks, i - 1) {
                if o > 0, toks[o - 1].kind == .keyword, toks[o - 1].text == "map" { i = o - 1 } else { i = o }
                continue
            }
            if p.isOp("*") { i -= 1; continue }
            break
        }
        return i
    }

    // MARK: - Variable names

    static func variableName(_ toks: [GoTok], exprText: String) -> String {
        var i = toks.count - 1
        var indexed = false
        var asserted: String?
        while i >= 0, toks[i].isOp(")") || toks[i].isOp("]") || toks[i].isOp("}") {
            guard let o = GoScanner.matchBackward(toks, i) else { return "v" }
            if toks[i].isOp(")"), o > 0, toks[o - 1].isOp(".") {
                asserted = toks[(o + 1)..<i].last { $0.kind == .ident }?.text
                break
            }
            if toks[i].isOp("]") { indexed = true }
            if toks[i].isOp("}") {
                // composite literal: name after the type
                asserted = toks[0..<o].last { $0.kind == .ident }?.text
                break
            }
            i = o - 1
        }
        var name: String
        if let a = asserted {
            name = a
        } else if i >= 0, toks[i].kind == .ident {
            name = toks[i].text
        } else {
            return "v"
        }
        if ["len", "cap"].contains(name) { return "n" }
        if ["make", "new", "append", "string", "int", "byte", "rune", "float64", "any", "min", "max"].contains(name) { return "v" }
        for p in ["New", "Get", "Make", "Create", "Load", "Read", "Parse", "Find", "Fetch", "Build", "Open", "Must"] {
            if name.hasPrefix(p), name.count > p.count,
               let c = name.dropFirst(p.count).first, c.isUppercase {
                name = String(name.dropFirst(p.count))
                break
            }
        }
        name = lowerCamel(name)
        if indexed, name.count > 2, name.hasSuffix("s") { name.removeLast() }
        if name == "type" { return "typ" }
        if GoScanner.keywords.contains(name) || name.isEmpty || name == exprText || name == "_" { return "v" }
        return name
    }

    /// `HTTPClient` → `httpClient`, `URL` → `url`, `Server` → `server`.
    static func lowerCamel(_ s: String) -> String {
        let chars = Array(s)
        var run = 0
        while run < chars.count, chars[run].isUppercase { run += 1 }
        if run == 0 { return s }
        if run == chars.count { return s.lowercased() }
        let lowerCount = run > 1 ? run - 1 : 1
        return String(chars[0..<lowerCount]).lowercased() + String(chars[lowerCount...])
    }

    // MARK: - err template: what to return

    /// `return <zero values>, err` for the innermost enclosing function, or `t.Fatal(err)` in tests.
    static func errorReturn(_ ns: NSString, before offset: Int, errExpr: String) -> String {
        let all = GoScanner.tokenize(ns, range: NSRange(location: 0, length: offset)).filter(\.isCode)
        // Stack of open braces enclosing `offset`.
        var stack: [Int] = []
        for (i, t) in all.enumerated() where t.kind == .op {
            if t.text == "{" { stack.append(i) } else if t.text == "}" { _ = stack.popLast() }
        }
        for b in stack.reversed() {
            guard let fi = funcKeyword(all, beforeBrace: b), let sig = GoSignature.parseFunc(all, at: fi) else { continue }
            if sig.results.isEmpty {
                if let t = sig.params.first(where: { ["*testing.T", "*testing.B", "*testing.F", "testing.TB"].contains($0.typeText) }),
                   let n = t.name, n != "_" {
                    return "\(n).Fatal(\(errExpr))"
                }
                return "return"
            }
            let fileToks = GoScanner.tokenize(ns as String)
            let decls = GoSignature.typeDecls(fileToks)
            let tparams = Set(sig.typeParams.compactMap(\.name))
            let lastIsError = sig.results.last?.typeText == "error"
            var vals: [String] = []
            for (idx, r) in sig.results.enumerated() {
                if idx == sig.results.count - 1 && lastIsError {
                    vals.append(errExpr)
                } else {
                    vals.append(GoTypes.zeroValue(r.typeText, decls: decls, typeParams: tparams))
                }
            }
            if !lastIsError { return "return \(errExpr)" }
            return "return " + vals.joined(separator: ", ")
        }
        return "return \(errExpr)"
    }

    /// The `func` keyword whose signature ends at the brace `b`, if `b` opens a function body.
    static func funcKeyword(_ toks: [GoTok], beforeBrace b: Int) -> Int? {
        var i = b - 1
        var depth = 0
        while i >= 0 {
            let t = toks[i]
            if t.kind == .op {
                if t.text == ")" || t.text == "]" { depth += 1 }
                if t.text == "(" || t.text == "[" {
                    depth -= 1
                    if depth < 0 { return nil }
                }
                if depth == 0 && (t.text == "{" || t.text == "}" || t.text == ";" || t.text == ":=" || t.text == "=" || t.text == ",") {
                    // `struct{}` / `interface{}` inside a result type are allowed.
                    if t.text == "}" || t.text == "{" {
                        if let o = t.text == "}" ? GoScanner.matchBackward(toks, i) : i, o > 0,
                           toks[o - 1].kind == .keyword, toks[o - 1].text == "struct" || toks[o - 1].text == "interface" {
                            i = o - 2
                            continue
                        }
                    }
                    return nil
                }
            }
            if depth == 0, t.kind == .keyword {
                if t.text == "func" { return i }
                if !["chan", "map", "struct", "interface"].contains(t.text) { return nil }
            }
            i -= 1
        }
        return nil
    }
}
