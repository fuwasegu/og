import Foundation

/// One of og's style-guided completion items (inserted above the gopls list).
public struct GoStyleCompletion: Sendable, Hashable {
    public var label: String
    public var detail: String
    /// UTF-16 range to replace; it ends at the caret.
    public var replaceRange: NSRange
    public var text: String
    /// Caret position inside `text` (UTF-16).
    public var caretOffset: Int
    public var filterText: String
    public var sortText: String
    /// The text uses a package (`fmt`, `errors`, `cmp`) that may need an import.
    public var needsImports: Bool
}

/// A gopls completion item, reduced to what og's templates look at.
public struct GoCompletionCandidate: Sendable, Hashable {
    public var label: String
    public var detail: String?
    public init(label: String, detail: String?) { self.label = label; self.detail = detail }
}

/// Completion templates that steer towards Effective Go and the Google Go Style Guide.
public enum GoStyleCompletions {
    /// All templates that apply at the caret. `packageSources` are the other files of the package
    /// (receivers, constructors); `candidates` are the gopls items (sentinel errors for `errors.Is`).
    public static func items(in ns: NSString, caret: Int, fileName: String = "",
                             packageSources: [String] = [], candidates: [GoCompletionCandidate] = [],
                             externalZeros: [String: String] = [:]) -> [GoStyleCompletion] {
        guard caret >= 0, caret <= ns.length, !GoScanner.isInsideStringOrComment(ns, offset: lineStart(ns, caret)) else { return [] }
        var out: [GoStyleCompletion] = []
        if let w = errorWrap(in: ns, caret: caret, externalZeros: externalZeros) { out.append(w) }
        out += errorsIs(in: ns, caret: caret, candidates: candidates)
        if let d = docComment(in: ns, caret: caret) { out.append(d) }
        out += receivers(in: ns, caret: caret, fileName: fileName, packageSources: packageSources)
        out += constructors(in: ns, caret: caret, fileName: fileName, packageSources: packageSources)
        if fileName.isEmpty || fileName.hasSuffix("_test.go") { out += testTemplates(in: ns, caret: caret) }
        return out
    }

    /// The character just typed should open completion for a template gopls never offers (`//`, `func (`).
    public static func shouldTrigger(in ns: NSString, caret: Int) -> Bool {
        guard caret <= ns.length else { return false }
        let before = lineBefore(ns, caret)
        let t = before.drop { $0 == " " || $0 == "\t" }
        return t == "//" || t == "// " || before == "func ("
    }

    /// The caret is in a comment or string: only og's templates make sense there, not gopls items.
    public static func isInCommentOrString(_ ns: NSString, caret: Int) -> Bool {
        GoScanner.isInsideStringOrComment(ns, offset: caret)
    }

    /// Receivers and constructors look at the rest of the package.
    public static func wantsPackageSources(in ns: NSString, caret: Int) -> Bool {
        guard caret <= ns.length else { return false }
        let before = lineBefore(ns, caret)
        if before.hasPrefix("func ("), before.dropFirst(6).allSatisfy(isIdentChar) { return true }
        if before.hasPrefix("func "), let id = Optional(before.dropFirst(5)), id.allSatisfy(isIdentChar), id.count >= 3,
           id.lowercased().hasPrefix("new") || "new".hasPrefix(id.lowercased()) { return true }
        return false
    }

    // MARK: - Line helpers

    static func isIdentChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

    static func lineStart(_ ns: NSString, _ caret: Int) -> Int {
        ns.lineRange(for: NSRange(location: caret, length: 0)).location
    }

    static func lineBefore(_ ns: NSString, _ caret: Int) -> String {
        let s = lineStart(ns, caret)
        return ns.substring(with: NSRange(location: s, length: caret - s))
    }

    static func restOfLine(_ ns: NSString, _ caret: Int) -> String {
        let r = ns.lineRange(for: NSRange(location: caret, length: 0))
        return ns.substring(with: NSRange(location: caret, length: NSMaxRange(r) - caret)).trimmingCharacters(in: .newlines)
    }

    static func indentOf(_ s: String) -> String { String(s.prefix { $0 == " " || $0 == "\t" }) }

    // MARK: - Error wrapping

    /// Next to `if err != nil { return …, err }`: the same check returning `fmt.Errorf("<call>: %w", err)`.
    static func errorWrap(in ns: NSString, caret: Int, externalZeros: [String: String] = [:]) -> GoStyleCompletion? {
        guard let base = GoErrCheck.suggestion(in: ns, caret: caret, externalZeros: externalZeros) else { return nil }
        let start = lineStart(ns, caret)
        let indent = indentOf(lineBefore(ns, caret))
        guard let stmt = GoErrCheck.previousStatement(ns, beforeLineAt: start) else { return nil }
        let msg = calleePhrase(stmt) ?? ""
        let v = base.variable
        let errExpr = "fmt.Errorf(\"\(msg): %w\", \(v))"
        let ret = GoPostfixEngine.errorReturn(ns, before: start, errExpr: errExpr, externalZeros: externalZeros)
        guard ret.hasPrefix("return "), ret.hasSuffix(errExpr) else { return nil }
        let text = "if \(v) != nil {\n\(indent)\t\(ret)\n\(indent)}"
        let t = text as NSString
        let open = t.range(of: "fmt.Errorf(\"")
        return GoStyleCompletion(
            label: "if \(v) != nil { \(ret) }", detail: "wrap the error with context (%w)",
            replaceRange: base.replaceRange, text: text, caretOffset: NSMaxRange(open) + (msg as NSString).length,
            filterText: "if", sortText: "!1", needsImports: true)
    }

    /// `data, err := os.ReadFile(p)` -> `read file`; `err = s.db.QueryRowContext(…)` -> `query row context`.
    static func calleePhrase(_ stmt: String) -> String? {
        let toks = GoScanner.tokenize(stmt).filter(\.isCode)
        var depth = 0
        var rhs: Int?
        for (i, t) in toks.enumerated() where t.kind == .op {
            if t.text == "(" || t.text == "[" || t.text == "{" { depth += 1 }
            if t.text == ")" || t.text == "]" || t.text == "}" { depth -= 1 }
            if depth == 0 && (t.text == ":=" || t.text == "=") { rhs = i + 1; break }
        }
        guard let r = rhs else { return nil }
        depth = 0
        for i in r..<toks.count {
            let t = toks[i]
            if t.isOp("(") {
                guard depth == 0, i > r else { return nil }
                var j = i - 1
                // Generic instantiation `For[T](…)`: step back over the type arguments.
                if toks[j].isOp("]") {
                    var d = 0
                    while j > r {
                        if toks[j].isOp("]") { d += 1 } else if toks[j].isOp("[") { d -= 1; if d == 0 { break } }
                        j -= 1
                    }
                    j -= 1
                }
                guard j >= r, toks[j].kind == .ident else { return nil }
                let name = words(toks[j].text)
                // `jsonschema.For`, `http.Get`, `c.Do`: a bare short verb says little; keep the qualifier.
                if !name.contains(" "), name.count <= 3, j - 2 >= r, toks[j - 1].isOp("."), toks[j - 2].kind == .ident {
                    return words(toks[j - 2].text) + " " + name
                }
                return name
            }
            if t.isOp("[") || t.isOp("{") { depth += 1 }
            if t.isOp("]") || t.isOp("}") { depth -= 1 }
        }
        return nil
    }

    /// Splits a Go identifier into lower-case words, keeping initialisms: `ParseURL` -> `parse URL`.
    static func words(_ name: String) -> String {
        let chars = Array(name)
        var parts: [String] = []
        var cur = ""
        for (i, c) in chars.enumerated() {
            if c == "_" { if !cur.isEmpty { parts.append(cur) }; cur = ""; continue }
            if c.isUppercase, !cur.isEmpty {
                let prevUpper = chars[i - 1].isUppercase
                let nextLower = i + 1 < chars.count && chars[i + 1].isLowercase
                if !prevUpper || nextLower { parts.append(cur); cur = "" }
            }
            cur.append(c)
        }
        if !cur.isEmpty { parts.append(cur) }
        return parts.map { p in p.count > 1 && p.allSatisfy { $0.isUppercase || $0.isNumber } ? p : p.lowercased() }.joined(separator: " ")
    }

    // MARK: - errors.Is

    /// `err == ErrN` / `err != io.E` -> `errors.Is(err, ErrNotFound)` / `!errors.Is(err, io.EOF)`.
    static func errorsIs(in ns: NSString, caret: Int, candidates: [GoCompletionCandidate]) -> [GoStyleCompletion] {
        let start = lineStart(ns, caret)
        let before = lineBefore(ns, caret)
        let toks = GoScanner.tokenize(before).filter(\.isCode)
        let length = (before as NSString).length
        var k = toks.count
        var typedMember = false
        if k > 0, toks[k - 1].kind == .ident, toks[k - 1].end == length { k -= 1; typedMember = true }
        var qualifier: String?
        if k >= 2, toks[k - 1].isOp("."), toks[k - 2].kind == .ident, toks[k - 1].end == (typedMember ? toks[k].start : length) {
            qualifier = toks[k - 2].text
            k -= 2
        }
        guard typedMember || qualifier != nil, k >= 2, toks[k - 1].isOp("==") || toks[k - 1].isOp("!="),
              toks[k - 2].kind == .ident else { return [] }
        let errVar = toks[k - 2].text
        guard errVar == "err" || errVar.hasSuffix("Err"), !(k >= 3 && toks[k - 3].isOp(".")) else { return [] }
        let negate = toks[k - 1].isOp("!=")
        var seen: Set<String> = []
        var out: [GoStyleCompletion] = []
        for c in candidates where out.count < 6 {
            let name = c.label
            guard name != "nil", name != errVar, name.allSatisfy(isIdentChar), !seen.contains(name) else { continue }
            let errorish = c.detail == "error" || GoStyle.isErrorVariableName(name)
            guard errorish else { continue }
            seen.insert(name)
            let sentinel = qualifier.map { "\($0).\(name)" } ?? name
            let text = (negate ? "!" : "") + "errors.Is(\(errVar), \(sentinel))"
            out.append(GoStyleCompletion(
                label: text, detail: "matches wrapped errors too",
                replaceRange: NSRange(location: start + toks[k - 2].start, length: caret - start - toks[k - 2].start),
                text: text, caretOffset: (text as NSString).length, filterText: name,
                sortText: "!2\(out.count)", needsImports: true))
        }
        return out
    }

    // MARK: - Doc comments

    /// `//` above an exported declaration -> `// Name `; above `package x` -> `// Package x `.
    static func docComment(in ns: NSString, caret: Int) -> GoStyleCompletion? {
        let start = lineStart(ns, caret)
        let before = lineBefore(ns, caret)
        let indent = indentOf(before)
        var typed = Substring(before.dropFirst(indent.count))
        guard typed.hasPrefix("//"), restOfLine(ns, caret).trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        typed = typed.dropFirst(2)
        if typed.hasPrefix(" ") { typed = typed.dropFirst() }
        guard typed.allSatisfy(isIdentChar) else { return nil }
        let lineEnd = NSMaxRange(ns.lineRange(for: NSRange(location: caret, length: 0)))
        guard lineEnd < ns.length else { return nil }
        let next = ns.lineRange(for: NSRange(location: lineEnd, length: 0))
        let toks = GoScanner.tokenize(ns, range: next).filter(\.isCode)
        guard let first = toks.first else { return nil }
        var name: String?
        var isPackage = false
        if first.kind == .keyword {
            switch first.text {
            case "func":
                if toks.count > 1, toks[1].isOp("("), let close = GoScanner.matchForward(toks, 1), close + 1 < toks.count {
                    name = toks[close + 1].kind == .ident ? toks[close + 1].text : nil
                } else if toks.count > 1, toks[1].kind == .ident {
                    name = toks[1].text
                }
            case "type", "var", "const":
                if toks.count > 1, toks[1].kind == .ident { name = toks[1].text }
            case "package":
                if toks.count > 1, toks[1].kind == .ident, toks[1].text != "main" { name = toks[1].text; isPackage = true }
            default: break
            }
        } else if first.kind == .ident, inDeclarationGroup(ns, before: next.location) {
            name = first.text
        }
        guard let n = name, isPackage || GoStyle.isExported(n) else { return nil }
        let head = isPackage ? "Package \(n)" : n
        guard typed.isEmpty || head.hasPrefix(typed) else { return nil }
        let text = "// \(head) "
        let from = start + (indent as NSString).length
        return GoStyleCompletion(
            label: "// \(head) …", detail: "doc comment starts with the name",
            replaceRange: NSRange(location: from, length: caret - from), text: text, caretOffset: (text as NSString).length,
            filterText: head, sortText: "!0", needsImports: false)
    }

    /// True when `offset` is inside a `const (` / `var (` / `type (` group.
    static func inDeclarationGroup(_ ns: NSString, before offset: Int) -> Bool {
        let toks = GoScanner.tokenize(ns, range: NSRange(location: 0, length: offset)).filter(\.isCode)
        var stack: [Int] = []
        for (i, t) in toks.enumerated() where t.kind == .op {
            if t.text == "(" || t.text == "{" || t.text == "[" { stack.append(i) }
            if t.text == ")" || t.text == "}" || t.text == "]" { _ = stack.popLast() }
        }
        guard stack.count == 1, let open = stack.first, toks[open].isOp("("), open > 0 else { return false }
        let kw = toks[open - 1]
        return kw.kind == .keyword && (kw.text == "const" || kw.text == "var" || kw.text == "type")
    }

    // MARK: - Receivers and constructors

    struct PackageType {
        var name: String
        var typeParams: String          // `[K comparable, V any]` or ""
        var typeArgs: String            // `[K, V]` or ""
        var isStruct: Bool
        var offset: Int                 // in the current file, or Int.max for other files
    }

    /// Types declared in the file and the package (current file first, in source order), plus every method.
    static func packageTypes(_ ns: NSString, packageSources: [String]) -> (types: [PackageType], methods: [String: [StyleScan.Method]], funcs: Set<String>) {
        var types: [PackageType] = []
        var methods: [String: [StyleScan.Method]] = [:]
        var funcs: Set<String> = []
        var seen: Set<String> = []
        for (i, src) in ([ns as String] + packageSources).enumerated() {
            var scan = StyleScan(ns: src as NSString, fileName: "")
            scan.collect()
            for (k, v) in scan.methods { methods[k, default: []] += v }
            for f in scan.funcs where f.receiver == nil { if let n = f.name { funcs.insert(n) } }
            for s in scan.specs where s.keyword.text == "type" {
                let c = s.toks.filter(\.isCode)
                guard let nameTok = c.first, nameTok.kind == .ident, !seen.contains(nameTok.text) else { continue }
                var k = 1
                var tparams = "", targs = ""
                if k < c.count, c[k].isOp("["), let close = GoScanner.matchForward(c, k), close > k + 2,
                   c[k + 1].kind == .ident, !c[k + 2].isOp("]") {
                    let params = GoSignature.parseFieldList(c, open: k, close: close)
                    tparams = "[" + params.map { "\($0.name ?? "_") \($0.typeText)" }.joined(separator: ", ") + "]"
                    targs = "[" + params.map { $0.name ?? "_" }.joined(separator: ", ") + "]"
                    k = close + 1
                }
                guard k < c.count, !c[k].isOp("="), !(c[k].kind == .keyword && c[k].text == "interface") else { continue }
                seen.insert(nameTok.text)
                types.append(PackageType(name: nameTok.text, typeParams: tparams, typeArgs: targs,
                                         isStruct: c[k].kind == .keyword && c[k].text == "struct",
                                         offset: i == 0 ? nameTok.start : Int.max))
            }
        }
        return (types, methods, funcs)
    }

    /// Current-file types nearest above the caret first, then the rest of the file, then other files.
    static func ordered(_ types: [PackageType], caret: Int) -> [PackageType] {
        let above = types.filter { $0.offset < caret }.sorted { $0.offset > $1.offset }
        let below = types.filter { $0.offset >= caret && $0.offset != Int.max }.sorted { $0.offset < $1.offset }
        let other = types.filter { $0.offset == Int.max }.sorted { $0.name < $1.name }
        return above + below + other
    }

    /// `func (` at top level -> `s *Server`, named and pointer-ed like the type's existing methods.
    static func receivers(in ns: NSString, caret: Int, fileName: String, packageSources: [String]) -> [GoStyleCompletion] {
        let before = lineBefore(ns, caret)
        guard before.hasPrefix("func (") else { return [] }
        let typed = before.dropFirst(6)
        guard typed.allSatisfy(isIdentChar) else { return [] }
        let closes = restOfLine(ns, caret).hasPrefix(")")
        let (types, methods, _) = packageTypes(ns, packageSources: packageSources)
        var out: [GoStyleCompletion] = []
        for t in ordered(types, caret: caret).prefix(12) {
            let existing = methods[t.name] ?? []
            let names = existing.compactMap(\.receiverName).filter { !["this", "self", "_"].contains($0) }
            let counts = Dictionary(grouping: names, by: { $0 }).mapValues(\.count)
            let recv = counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? GoStyle.defaultReceiverName(for: t.name)
            guard typed.isEmpty || recv.hasPrefix(typed) else { continue }
            let pointers = existing.filter(\.pointer).count
            let pointer = existing.isEmpty ? t.isStruct : pointers * 2 >= existing.count
            let decl = "\(recv) \(pointer ? "*" : "")\(t.name)\(t.typeArgs)"
            let text = decl + (closes ? "" : ") ")
            let from = lineStart(ns, caret) + 6
            out.append(GoStyleCompletion(
                label: decl, detail: existing.isEmpty ? "receiver" : "receiver, as in its other methods",
                replaceRange: NSRange(location: from, length: caret - from), text: text, caretOffset: (text as NSString).length,
                filterText: recv, sortText: "!3\(String(format: "%02d", out.count))", needsImports: false))
        }
        return out
    }

    /// `func New` -> `func NewServer() *Server { return &Server{} }` for the struct types of the file.
    static func constructors(in ns: NSString, caret: Int, fileName: String, packageSources: [String]) -> [GoStyleCompletion] {
        let before = lineBefore(ns, caret)
        guard before.hasPrefix("func "), restOfLine(ns, caret).trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let typed = String(before.dropFirst(5))
        guard typed.count >= 3, typed.allSatisfy(isIdentChar) else { return [] }
        let (types, _, funcs) = packageTypes(ns, packageSources: packageSources)
        var out: [GoStyleCompletion] = []
        for t in ordered(types, caret: caret) where t.isStruct && t.offset != Int.max && out.count < 6 {
            let ctor = (GoStyle.isExported(t.name) ? "New" : "new") + GoStyle.capitalized(t.name)
            guard ctor.hasPrefix(typed), !funcs.contains(ctor) else { continue }
            let type = t.name + t.typeArgs
            let head = "func \(ctor)\(t.typeParams)("
            let text = head + ") *\(type) {\n\treturn &\(type){}\n}"
            let from = lineStart(ns, caret)
            out.append(GoStyleCompletion(
                label: "func \(ctor)\(t.typeParams)() *\(type)", detail: "constructor",
                replaceRange: NSRange(location: from, length: caret - from), text: text, caretOffset: (head as NSString).length,
                filterText: ctor, sortText: "!4\(out.count)", needsImports: false))
        }
        return out
    }

    // MARK: - Tests

    /// Test function name and `*testing.T` parameter enclosing the caret.
    static func enclosingTest(_ ns: NSString, caret: Int) -> (test: String, t: String)? {
        let toks = GoScanner.tokenize(ns, range: NSRange(location: 0, length: caret)).filter(\.isCode)
        var stack: [Int] = []
        for (i, t) in toks.enumerated() where t.kind == .op {
            if t.text == "{" { stack.append(i) } else if t.text == "}" { _ = stack.popLast() }
        }
        var tName: String?
        var test: String?
        for b in stack.reversed() {
            guard let fi = GoPostfixEngine.funcKeyword(toks, beforeBrace: b), let sig = GoSignature.parseFunc(toks, at: fi) else { continue }
            if tName == nil, let p = sig.params.first(where: { $0.typeText == "*testing.T" }), let n = p.name, n != "_" { tName = n }
            if let n = sig.name, n.hasPrefix("Test") { test = n }
        }
        guard let test, let tName else { return nil }
        return (test, tName)
    }

    /// `TestParseURL` -> `ParseURL`, `TestServer_Start` -> `Server.Start`, `TestParse_empty` -> `Parse`.
    static func functionUnderTest(_ test: String) -> String {
        let parts = test.dropFirst(4).split(separator: "_").map(String.init)
        guard let first = parts.first, !first.isEmpty else { return "F" }
        if parts.count > 1, parts[1].first?.isUppercase == true { return first + "." + parts[1] }
        return first
    }

    /// `t.Errorf` with the `F(in) = got, want want` message, and the `cmp.Diff` comparison.
    static func testTemplates(in ns: NSString, caret: Int) -> [GoStyleCompletion] {
        let before = lineBefore(ns, caret)
        let indent = indentOf(before)
        let typed = String(before.dropFirst(indent.count))
        guard !typed.isEmpty, restOfLine(ns, caret).trimmingCharacters(in: .whitespaces).isEmpty,
              typed.allSatisfy({ isIdentChar($0) || $0 == "." }) else { return [] }
        guard let enclosing = enclosingTest(ns, caret: caret) else { return [] }
        let t = enclosing.t
        let f = functionUnderTest(enclosing.test)
        let from = lineStart(ns, caret) + (indent as NSString).length
        let range = NSRange(location: from, length: caret - from)
        var out: [GoStyleCompletion] = []
        if typed.hasPrefix(t + "."), "Errorf".hasPrefix(typed.dropFirst(t.count + 1)) {
            let text = "\(t).Errorf(\"\(f)(%v) = %v, want %v\", in, got, want)"
            out.append(GoStyleCompletion(
                label: text, detail: "got/want failure message", replaceRange: range, text: text,
                caretOffset: (text as NSString).length, filterText: "Errorf", sortText: "!5", needsImports: false))
        }
        if typed.count >= 3, "cmp.Diff".hasPrefix(typed) {
            let head = "if diff := cmp.Diff(want, got); diff != \"\" {\n\(indent)\t\(t).Errorf(\"\(f)() mismatch (-want +got):\\n%s\", diff)"
            let text = head + "\n\(indent)}"
            out.append(GoStyleCompletion(
                label: "if diff := cmp.Diff(want, got); diff != \"\" { … }", detail: "cmp.Diff comparison",
                replaceRange: range, text: text, caretOffset: (head as NSString).length,
                filterText: typed.contains(".") ? "Diff" : "cmp.Diff", sortText: "!6", needsImports: true))
        }
        return out
    }
}
