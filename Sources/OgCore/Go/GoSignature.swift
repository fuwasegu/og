import Foundation

/// One entry of a Go parameter / result / type-parameter list, expanded so that
/// `a, b int` yields two entries sharing the same type.
struct GoParam: Sendable, Hashable {
    var name: String?
    var type: [GoTok]
    var variadic: Bool

    var typeText: String { GoScanner.render(type[...]) }
}

/// A parsed `func` declaration or literal header.
struct GoFuncSig: Sendable {
    var name: String?                 // nil for a func literal
    var receiver: GoParam?
    var typeParams: [GoParam]
    var params: [GoParam]
    var results: [GoParam]
    var funcIndex: Int                // index of the `func` keyword
    var bodyOpen: Int?                // index of `{`
    var bodyClose: Int?               // index of the matching `}`

    /// `Server` for `func (s *Server[T]) ...`.
    var receiverTypeName: String? {
        guard let r = receiver else { return nil }
        return r.type.first { $0.kind == .ident }?.text
    }
    var receiverIsPointer: Bool { receiver?.type.first?.isOp("*") ?? false }
    /// Type argument names of the receiver: `T`, `K` in `(m *Map[K, T])`.
    var receiverTypeArgs: [String] {
        guard let r = receiver, let open = r.type.firstIndex(where: { $0.isOp("[") }),
              let close = GoScanner.matchForward(r.type, open) else { return [] }
        return r.type[(open + 1)..<close].filter { $0.kind == .ident }.map(\.text)
    }
}

enum GoSignature {
    /// Code tokens only (no comments / newlines), as an array.
    static func codeTokens(_ toks: [GoTok]) -> [GoTok] { toks.filter(\.isCode) }

    /// Parses the field list between brackets `open` and `close` (exclusive) of `toks` (code tokens).
    static func parseFieldList(_ toks: [GoTok], open: Int, close: Int) -> [GoParam] {
        guard close > open + 1 else { return [] }
        var entries: [[GoTok]] = []
        var cur: [GoTok] = []
        var depth = 0
        for t in toks[(open + 1)..<close] {
            if t.kind == .op {
                if t.text == "(" || t.text == "[" || t.text == "{" { depth += 1 }
                if t.text == ")" || t.text == "]" || t.text == "}" { depth -= 1 }
                if t.text == "," && depth == 0 { entries.append(cur); cur = []; continue }
            }
            cur.append(t)
        }
        if !cur.isEmpty { entries.append(cur) }
        entries = entries.filter { !$0.isEmpty }

        func namedSplit(_ e: [GoTok]) -> (String, [GoTok])? {
            guard e.count >= 2, e[0].kind == .ident else { return nil }
            let second = e[1]
            if second.isOp(".") { return nil }                                // pkg.Type
            if second.isOp("[") && second.start == e[0].end { return nil }    // Generic[T] (no space)
            return (e[0].text, Array(e[1...]))
        }
        let anyNamed = entries.contains { namedSplit($0) != nil }
        var result: [GoParam] = []
        if !anyNamed {
            for e in entries {
                let variadic = e.first?.isOp("...") ?? false
                result.append(GoParam(name: nil, type: variadic ? Array(e.dropFirst()) : e, variadic: variadic))
            }
            return result
        }
        var pendingNames: [String] = []
        for e in entries {
            if let (name, type) = namedSplit(e) {
                let variadic = type.first?.isOp("...") ?? false
                let ty = variadic ? Array(type.dropFirst()) : type
                for n in pendingNames { result.append(GoParam(name: n, type: ty, variadic: false)) }
                pendingNames = []
                result.append(GoParam(name: name, type: ty, variadic: variadic))
            } else if e.count == 1, e[0].kind == .ident {
                pendingNames.append(e[0].text)
            } else {
                // Malformed for a named list; keep it as an unnamed type.
                result.append(GoParam(name: nil, type: e, variadic: false))
            }
        }
        return result
    }

    /// Parses the function header whose `func` keyword is at `fi` in `toks` (code tokens).
    static func parseFunc(_ toks: [GoTok], at fi: Int) -> GoFuncSig? {
        guard fi < toks.count, toks[fi].kind == .keyword, toks[fi].text == "func" else { return nil }
        var i = fi + 1
        var sig = GoFuncSig(name: nil, receiver: nil, typeParams: [], params: [], results: [], funcIndex: fi)
        guard i < toks.count else { return nil }
        if toks[i].isOp("(") {
            // Receiver (method) or parameters (literal).
            guard let close = GoScanner.matchForward(toks, i) else { return nil }
            if close + 1 < toks.count, toks[close + 1].kind == .ident,
               close + 2 < toks.count, toks[close + 2].isOp("(") || toks[close + 2].isOp("[") {
                sig.receiver = parseFieldList(toks, open: i, close: close).first
                sig.name = toks[close + 1].text
                i = close + 2
            }
        } else if toks[i].kind == .ident {
            sig.name = toks[i].text
            i += 1
        } else {
            return nil
        }
        guard i < toks.count else { return nil }
        if toks[i].isOp("[") {
            guard let close = GoScanner.matchForward(toks, i) else { return nil }
            sig.typeParams = parseFieldList(toks, open: i, close: close)
            i = close + 1
        }
        guard i < toks.count, toks[i].isOp("("), let pclose = GoScanner.matchForward(toks, i) else { return nil }
        sig.params = parseFieldList(toks, open: i, close: pclose)
        i = pclose + 1
        // Results: a parenthesized list, or a single type, up to the body `{` on the same line.
        if i < toks.count, toks[i].isOp("(") {
            guard let rclose = GoScanner.matchForward(toks, i) else { return nil }
            sig.results = parseFieldList(toks, open: i, close: rclose)
            i = rclose + 1
        } else {
            var j = i
            var depth = 0
            var type: [GoTok] = []
            while j < toks.count {
                let t = toks[j]
                if depth == 0 && t.isOp("{") {
                    let prev = j > 0 ? toks[j - 1] : t
                    let isTypeBrace = prev.kind == .keyword && (prev.text == "struct" || prev.text == "interface")
                    if !isTypeBrace { break }
                }
                if depth == 0 && (t.isOp(")") || t.isOp(",") || t.isOp(";") || t.isOp("}") || t.isOp("=")) { break }
                if t.kind == .op {
                    if t.text == "(" || t.text == "[" || t.text == "{" { depth += 1 }
                    if t.text == ")" || t.text == "]" || t.text == "}" { depth -= 1 }
                }
                type.append(t)
                j += 1
            }
            if !type.isEmpty { sig.results = [GoParam(name: nil, type: type, variadic: false)] }
            i = j
        }
        if i < toks.count, toks[i].isOp("{"), let bclose = GoScanner.matchForward(toks, i) {
            sig.bodyOpen = i
            sig.bodyClose = bclose
        }
        return sig
    }

    /// Imported package names → import path (alias respected), from the file's import decls.
    static func imports(_ toks: [GoTok]) -> [(name: String, path: String, alias: String?)] {
        var out: [(String, String, String?)] = []
        var i = 0
        func spec(_ j: Int) -> Int {
            var j = j
            var alias: String?
            if j < toks.count, toks[j].kind == .ident || toks[j].isOp(".") { alias = toks[j].text; j += 1 }
            if j < toks.count, toks[j].kind == .string || toks[j].kind == .rawString {
                let path = String(toks[j].text.dropFirst().dropLast())
                out.append((alias ?? defaultPackageName(path), path, alias))
                j += 1
            }
            return j
        }
        while i < toks.count {
            let t = toks[i]
            if t.kind == .keyword && t.text == "import" {
                if i + 1 < toks.count, toks[i + 1].isOp("("), let close = GoScanner.matchForward(toks, i + 1) {
                    var j = i + 2
                    while j < close {
                        let n = spec(j)
                        j = n == j ? j + 1 : n
                    }
                    i = close + 1
                } else {
                    i = spec(i + 1)
                }
                continue
            }
            // Imports come before any other top-level declaration.
            if t.kind == .keyword && (t.text == "func" || t.text == "type" || t.text == "var" || t.text == "const") { break }
            i += 1
        }
        return out
    }

    /// Best guess of a package name from its import path (`gopkg.in/yaml.v3` → `yaml`, `x/v2` → `x`).
    static func defaultPackageName(_ path: String) -> String {
        var parts = path.split(separator: "/").map(String.init)
        if parts.count > 1, let last = parts.last, last.hasPrefix("v"), Int(last.dropFirst()) != nil { parts.removeLast() }
        var name = parts.last ?? path
        if let dot = name.range(of: ".v", options: .backwards), Int(name[dot.upperBound...]) != nil {
            name = String(name[..<dot.lowerBound])
        }
        if name.hasPrefix("go-") { name = String(name.dropFirst(3)) }
        name = name.replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: ".", with: "_")
        return name
    }

    /// `package foo` name.
    static func packageName(_ toks: [GoTok]) -> String? {
        for (i, t) in toks.enumerated() where t.kind == .keyword && t.text == "package" {
            if i + 1 < toks.count, toks[i + 1].kind == .ident { return toks[i + 1].text }
        }
        return nil
    }

    enum TypeKind { case structType, interfaceType, basic(String), reference, composite, other }

    /// Top-level and grouped `type Name ...` declarations → kind of the underlying type, plus type-param constraints.
    /// `all` are the file's tokens including newlines (comments are ignored).
    static func typeDecls(_ all: [GoTok]) -> [String: (kind: TypeKind, typeParams: [GoParam])] {
        let toks = all.filter { $0.kind != .comment }
        var out: [String: (kind: TypeKind, typeParams: [GoParam])] = [:]
        func classify(_ j: Int) -> TypeKind {
            guard j < toks.count else { return .other }
            let t = toks[j]
            if t.kind == .keyword {
                switch t.text {
                case "struct": return .structType
                case "interface": return .interfaceType
                case "map": return .composite
                case "chan", "func": return .reference
                default: return .other
                }
            }
            if t.isOp("*") { return .reference }
            if t.isOp("[") { return j + 1 < toks.count && toks[j + 1].isOp("]") ? .composite : .composite }
            if t.kind == .ident, GoTypes.basic.contains(t.text), !(j + 1 < toks.count && toks[j + 1].isOp(".")) {
                return .basic(t.text)
            }
            if t.kind == .ident, t.text == "error" || t.text == "any" { return .interfaceType }
            return .other
        }
        func decl(_ j: Int) {
            guard j < toks.count, toks[j].kind == .ident else { return }
            let name = toks[j].text
            var k = j + 1
            var tparams: [GoParam] = []
            // `type T[P any] ...` vs `type T [N]int` (array): a type-param list has an ident followed by a constraint.
            if k < toks.count, toks[k].isOp("["), let close = GoScanner.matchForward(toks, k),
               close > k + 2, toks[k + 1].kind == .ident, !toks[k + 2].isOp("]") {
                let inner = Array(toks[k...close]).filter(\.isCode)
                tparams = parseFieldList(inner, open: 0, close: inner.count - 1)
                k = close + 1
            }
            if k < toks.count, toks[k].isOp("=") { k += 1 }
            out[name] = (classify(k), tparams)
        }
        var depth = 0
        var i = 0
        while i < toks.count {
            let t = toks[i]
            if t.kind == .op {
                if t.text == "{" || t.text == "(" { depth += 1 }
                if t.text == "}" || t.text == ")" { depth -= 1 }
            }
            if depth == 0, t.kind == .keyword, t.text == "type", i + 1 < toks.count {
                if toks[i + 1].isOp("("), let close = GoScanner.matchForward(toks, i + 1) {
                    var d = 0
                    var atStart = true
                    for j in (i + 2)..<close {
                        let u = toks[j]
                        if u.kind == .newline { if d == 0 { atStart = true }; continue }
                        if atStart && d == 0 && u.kind == .ident { decl(j) }
                        atStart = false
                        if u.kind == .op {
                            if u.text == "(" || u.text == "[" || u.text == "{" { d += 1 }
                            if u.text == ")" || u.text == "]" || u.text == "}" { d -= 1 }
                            if u.text == ";" && d == 0 { atStart = true }
                        }
                    }
                    i = close + 1
                    continue
                }
                decl(i + 1)
            }
            i += 1
        }
        return out
    }
}

/// Helpers about Go types for generated code.
enum GoTypes {
    static let basic: Set<String> = [
        "bool", "string", "int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64",
        "uintptr", "float32", "float64", "complex64", "complex128", "byte", "rune"
    ]

    /// Zero value expression for a rendered type.
    static func zeroValue(_ type: String, decls: [String: (kind: GoSignature.TypeKind, typeParams: [GoParam])], typeParams: Set<String>,
                          external: [String: String] = [:]) -> String {
        // Types from other packages, resolved by the editor through gopls (`tool.Tool` -> "nil").
        if let z = external[type] { return z }
        if type == "bool" { return "false" }
        if type == "string" { return "\"\"" }
        if basic.contains(type) { return "0" }
        if type == "error" || type == "any" { return "nil" }
        if type.hasPrefix("*") || type.hasPrefix("[]") || type.hasPrefix("map[") || type.hasPrefix("chan") ||
            type.hasPrefix("<-chan") || type.hasPrefix("func") || type.hasPrefix("interface") { return "nil" }
        if type.hasPrefix("[") || type.hasPrefix("struct") { return type + "{}" }
        if typeParams.contains(type) { return "*new(\(type))" }
        let base = String(type.prefix { $0 != "[" })
        if !base.contains("."), let d = decls[base] {
            switch d.kind {
            case .structType, .composite: return type + "{}"
            case .interfaceType, .reference: return "nil"
            case .basic(let b): return b == "bool" ? "false" : b == "string" ? "\"\"" : "0"
            case .other: break
            }
        }
        if type == "time.Time" { return "time.Time{}" }
        if type == "context.Context" || type == "io.Reader" || type == "io.Writer" { return "nil" }
        return "*new(\(type))"
    }
}

