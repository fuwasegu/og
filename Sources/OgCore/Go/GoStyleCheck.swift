import Foundation

/// A quick fix for a style finding.
public struct GoStyleFix: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// Rename the identifier at `position` through the rename flow (preview, every file).
        case rename(position: LSPPosition, newName: String)
        /// Edits to this file; `caret` (in the edited text) is where the caret goes afterwards.
        case edits([LSPTextEdit], caret: LSPPosition?)
    }
    public var title: String
    public var kind: Kind
}

/// One Effective Go / Google Go Style finding that staticcheck does not report.
public struct GoStyleFinding: Sendable, Hashable {
    public var rule: GoStyleRule
    public var range: LSPRange
    public var severity: LSPSeverity
    public var message: String
    public var fix: GoStyleFix?

    /// As an editor diagnostic: `source` is `og`, `code` the rule id.
    public var diagnostic: LSPDiagnostic {
        var d = LSPDiagnostic(range: range, severity: severity, message: message, source: GoStyle.source)
        d.code = .string(rule.id)
        return d
    }
}

/// og's own Go style checks. Purely lexical (GoScanner / GoSignature), deterministic, one file at a time.
public enum GoStyle {
    public static let source = "og"

    /// Findings for one file, sorted by position. Generated files (`// Code generated … DO NOT EDIT.`) have none.
    public static func check(_ text: String, fileName: String) -> [GoStyleFinding] {
        let ns = text as NSString
        guard !isGenerated(ns) else { return [] }
        var scan = StyleScan(ns: ns, fileName: fileName)
        scan.run()
        return scan.findings.sorted { $0.range.start < $1.range.start }
    }

    static func isGenerated(_ ns: NSString) -> Bool {
        var found = false
        ns.enumerateLines { line, stop in
            if line.hasPrefix("package ") { stop.pointee = true; return }
            if line.hasPrefix("// Code generated ") && line.hasSuffix(" DO NOT EDIT.") { found = true; stop.pointee = true }
        }
        return found
    }

    static func isExported(_ name: String) -> Bool { name.first?.isUppercase ?? false }

    static func capitalized(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
    static func lowerFirst(_ s: String) -> String { s.prefix(1).lowercased() + s.dropFirst() }

    /// `HTTPServer` in package `http` -> `Server`; nil when the name does not repeat the package.
    public static func stutterRemainder(_ name: String, package pkg: String) -> String? {
        guard pkg.count >= 2, pkg != "main", name.count > pkg.count, isExported(name),
              name.lowercased().hasPrefix(pkg.lowercased()) else { return nil }
        let rest = String(name.dropFirst(pkg.count))
        guard let f = rest.first, f.isUppercase else { return nil }
        return rest
    }

    /// `NotFound` -> `ErrNotFound`, `notFoundError` -> `errNotFound`.
    public static func errorVariableName(for name: String) -> String {
        var base = name
        for suffix in ["Error", "Err"] where base.hasSuffix(suffix) && base.count > suffix.count {
            base = String(base.dropLast(suffix.count))
            break
        }
        for prefix in ["error", "Error", "err", "Err"] where base.hasPrefix(prefix) && base.count > prefix.count {
            let rest = base.dropFirst(prefix.count)
            if rest.first?.isUppercase == true { base = String(rest); break }
        }
        return (isExported(name) ? "Err" : "err") + capitalized(base)
    }

    /// True for `ErrFoo` / `errFoo` (and `Err` / `err` + digits are not special-cased).
    static func isErrorVariableName(_ name: String) -> Bool {
        for p in ["Err", "err"] where name.hasPrefix(p) {
            let rest = name.dropFirst(p.count)
            if let f = rest.first, f.isUppercase || f.isNumber { return true }
        }
        return false
    }

    /// `Load` -> `Loader`, `Close` -> `Closer`.
    public static func erName(forMethod m: String, exported: Bool) -> String {
        let n = m.hasSuffix("e") ? m + "r" : m + "er"
        return exported ? capitalized(n) : lowerFirst(n)
    }

    /// Short receiver name for a type: `Server` -> `s`, `HTTPClient` -> `h`, `*Map[K, V]` -> `m`.
    public static func defaultReceiverName(for type: String) -> String {
        guard let f = type.first(where: { $0.isLetter }) else { return "x" }
        let r = String(f).lowercased()
        return GoScanner.keywords.contains(r) ? r + r : r
    }

    static let testingTypes: Set<String> = ["*testing.T", "*testing.B", "*testing.F", "testing.TB"]
}

/// One pass over a file: collect declarations, then run every rule.
struct StyleScan {
    let ns: NSString
    let lines: TextLines
    let all: [GoTok]
    let code: [GoTok]
    let nc: [GoTok]                       // no comments, newlines kept
    let isTest: Bool
    var pkg = ""
    var findings: [GoStyleFinding] = []

    struct Spec {
        var keyword: GoTok
        var toks: [GoTok]                 // nc tokens of the spec
        var grouped: Bool
    }

    struct Method {
        var name: String
        var receiverName: String?
        var pointer: Bool
    }

    var funcs: [GoFuncSig] = []
    var specs: [Spec] = []
    var methods: [String: [Method]] = [:]
    var fields: [String: Set<String>] = [:]
    var topNames: Set<String> = []

    init(ns: NSString, fileName: String) {
        self.ns = ns
        lines = TextLines(nsString: ns)
        all = GoScanner.tokenize(ns, range: NSRange(location: 0, length: ns.length))
        code = all.filter(\.isCode)
        nc = all.filter { $0.kind != .comment }
        isTest = fileName.hasSuffix("_test.go")
    }

    // MARK: Helpers

    func pos(_ offset: Int) -> LSPPosition { lines.position(forOffset: offset) }
    func range(_ t: GoTok) -> LSPRange { LSPRange(start: pos(t.start), end: pos(t.end)) }
    func range(_ a: Int, _ b: Int) -> LSPRange { LSPRange(start: pos(a), end: pos(b)) }

    /// A `//` or `/* */` comment ends on the line above `line` (directives like `//go:` do not count).
    func hasDoc(line: Int) -> Bool {
        var l = line - 1
        while l >= 0 {
            let t = lines.lineText(l).trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("//go:") || t.hasPrefix("//line ") || t.hasPrefix("//nolint") { l -= 1; continue }
            return t.hasPrefix("//") || t.hasSuffix("*/")
        }
        return false
    }

    mutating func add(_ rule: GoStyleRule, _ r: LSPRange, _ sev: LSPSeverity, _ msg: String, fix: GoStyleFix? = nil) {
        findings.append(GoStyleFinding(rule: rule, range: r, severity: sev, message: msg, fix: fix))
    }

    func renameFix(_ tok: GoTok, to name: String) -> GoStyleFix? {
        guard !topNames.contains(name), !GoScanner.keywords.contains(name) else { return nil }
        return GoStyleFix(title: "Rename \(tok.text) to \(name)", kind: .rename(position: pos(tok.start), newName: name))
    }

    func docFix(name: String, atLine line: Int) -> GoStyleFix {
        let indent = String(lines.lineText(line).prefix { $0 == " " || $0 == "\t" })
        let text = "\(indent)// \(name) "
        let at = LSPPosition(line: line, character: 0)
        return GoStyleFix(title: "Add doc comment \"// \(name) …\"",
                          kind: .edits([LSPTextEdit(range: LSPRange(start: at, end: at), newText: text + "\n")],
                                       caret: LSPPosition(line: line, character: (text as NSString).length)))
    }

    // MARK: Collect

    mutating func run() {
        pkg = GoSignature.packageName(code) ?? ""
        collect()
        for sig in funcs { checkFunc(sig) }
        checkSpecs()
        checkElses()
    }

    mutating func collect() {
        var codeIndex: [Int: Int] = [:]
        for (i, t) in code.enumerated() { codeIndex[t.start] = i }
        var depth = 0
        var i = 0
        while i < nc.count {
            let t = nc[i]
            if t.kind == .op {
                if t.text == "(" || t.text == "[" || t.text == "{" { depth += 1 }
                if t.text == ")" || t.text == "]" || t.text == "}" { depth -= 1 }
            } else if depth == 0, t.kind == .keyword {
                if t.text == "func", let ci = codeIndex[t.start], let sig = GoSignature.parseFunc(code, at: ci) {
                    funcs.append(sig)
                } else if t.text == "type" || t.text == "var" || t.text == "const" {
                    let (s, next) = collectSpecs(at: i)
                    specs += s
                    i = next
                    continue
                }
            }
            i += 1
        }
        for sig in funcs {
            guard let name = sig.name else { continue }
            if let type = sig.receiverTypeName {
                methods[type, default: []].append(Method(name: name, receiverName: sig.receiver?.name, pointer: sig.receiverIsPointer))
            } else {
                topNames.insert(name)
            }
        }
        for s in specs {
            let c = s.toks.filter(\.isCode)
            for n in specNames(c) { topNames.insert(n.text) }
            if s.keyword.text == "type", let name = c.first?.text, let body = typeBody(s.toks, keyword: "struct") {
                var names: Set<String> = []
                for e in body {
                    let ec = e.filter(\.isCode)
                    guard let f = ec.first else { continue }
                    if ec.count >= 2, f.kind == .ident, !ec[1].isOp(".") {
                        var k = 0
                        while k < ec.count, ec[k].kind == .ident {
                            names.insert(ec[k].text)
                            if k + 1 < ec.count, ec[k + 1].isOp(",") { k += 2 } else { break }
                        }
                    } else if let last = ec.last(where: { $0.kind == .ident }) {
                        names.insert(last.text)            // embedded field
                    }
                }
                fields[name] = names
            }
        }
    }

    func collectSpecs(at k: Int) -> ([Spec], Int) {
        let kw = nc[k]
        var j = k + 1
        guard j < nc.count else { return ([], j) }
        func adjust(_ u: GoTok, _ d: inout Int) {
            guard u.kind == .op else { return }
            if u.text == "(" || u.text == "[" || u.text == "{" { d += 1 }
            if u.text == ")" || u.text == "]" || u.text == "}" { d -= 1 }
        }
        if nc[j].isOp("("), let close = GoScanner.matchForward(nc, j) {
            var out: [Spec] = []
            var cur: [GoTok] = []
            var d = 0
            func flush() {
                if cur.contains(where: \.isCode) { out.append(Spec(keyword: kw, toks: cur, grouped: true)) }
                cur = []
            }
            for u in nc[(j + 1)..<close] {
                if d == 0 && (u.kind == .newline || u.isOp(";")) { flush(); continue }
                adjust(u, &d)
                cur.append(u)
            }
            flush()
            return (out, close + 1)
        }
        var cur: [GoTok] = []
        var d = 0
        while j < nc.count {
            let u = nc[j]
            if d == 0 && (u.kind == .newline || u.isOp(";")) { break }
            adjust(u, &d)
            cur.append(u)
            j += 1
        }
        return ([Spec(keyword: kw, toks: cur, grouped: false)], j)
    }

    /// Declared names of a spec (code tokens): `T` for a type, `a, b` for `var a, b = …`.
    func specNames(_ c: [GoTok]) -> [GoTok] {
        guard let f = c.first, f.kind == .ident else { return [] }
        var out = [f]
        var k = 1
        while k + 1 < c.count, c[k].isOp(","), c[k + 1].kind == .ident { out.append(c[k + 1]); k += 2 }
        return out
    }

    /// Elements (lines) of the `struct { … }` / `interface { … }` body of a type spec.
    func typeBody(_ toks: [GoTok], keyword: String) -> [[GoTok]]? {
        guard let first = toks.firstIndex(where: \.isCode) else { return nil }
        var k = first + 1
        // Type parameters: `T[P any]`.
        while k < toks.count, toks[k].kind == .newline { k += 1 }
        if k < toks.count, toks[k].isOp("["), let close = GoScanner.matchForward(toks, k),
           close > k + 2, toks[k + 1].kind == .ident, !toks[k + 2].isOp("]") {
            k = close + 1
        }
        guard k < toks.count, toks[k].kind == .keyword, toks[k].text == keyword,
              k + 1 < toks.count, toks[k + 1].isOp("{"), let close = GoScanner.matchForward(toks, k + 1) else { return nil }
        var out: [[GoTok]] = []
        var cur: [GoTok] = []
        var d = 0
        for u in toks[(k + 2)..<close] {
            if d == 0 && (u.kind == .newline || u.isOp(";")) { if !cur.isEmpty { out.append(cur) }; cur = []; continue }
            if u.kind == .op {
                if u.text == "(" || u.text == "[" || u.text == "{" { d += 1 }
                if u.text == ")" || u.text == "]" || u.text == "}" { d -= 1 }
            }
            cur.append(u)
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    // MARK: Functions

    mutating func checkFunc(_ sig: GoFuncSig) {
        guard let name = sig.name else { return }
        let fi = sig.funcIndex
        var nameIdx = fi + 1
        if sig.receiver != nil || (fi + 1 < code.count && code[fi + 1].isOp("(")) {
            guard let close = GoScanner.matchForward(code, fi + 1) else { return }
            nameIdx = close + 1
        }
        guard nameIdx < code.count, code[nameIdx].text == name else { return }
        let nameTok = code[nameIdx]
        let line = pos(code[fi].start).line

        if let recv = sig.receiver, let type = sig.receiverTypeName {
            // Receiver named this / self.
            if let rn = recv.name, rn == "this" || rn == "self", fi + 2 < code.count, code[fi + 2].text == rn {
                let others = (methods[type] ?? []).compactMap(\.receiverName).filter { !["this", "self", "_"].contains($0) }
                let counts = Dictionary(grouping: others, by: { $0 }).mapValues(\.count)
                let suggested = counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? GoStyle.defaultReceiverName(for: type)
                let clash = sig.params.contains { $0.name == suggested } || sig.results.contains { $0.name == suggested }
                add(GoStyleRules.receiverName, range(code[fi + 2]), .warning,
                    "Receiver name \"\(rn)\" is generic; Go receivers are a short name for the type, such as \"\(suggested)\".",
                    fix: clash ? nil : GoStyleFix(title: "Rename receiver to \(suggested)",
                                                  kind: .rename(position: pos(code[fi + 2].start), newName: suggested)))
            }
            // GetX() T -> X() T.
            if name.hasPrefix("Get"), name.count > 3, name.dropFirst(3).first?.isUppercase == true,
               sig.params.isEmpty, !sig.results.isEmpty {
                let new = String(name.dropFirst(3))
                let clash = (methods[type] ?? []).contains { $0.name == new } || (fields[type]?.contains(new) ?? false)
                add(GoStyleRules.getter, range(nameTok), .information,
                    "Getter \(name): Go getters don't use a Get prefix; call it \(new) (a setter would be Set\(new)).",
                    fix: clash ? nil : GoStyleFix(title: "Rename \(name) to \(new)", kind: .rename(position: pos(nameTok.start), newName: new)))
            }
        } else if !isTest, let rest = GoStyle.stutterRemainder(name, package: pkg) {
            add(GoStyleRules.stutter, range(nameTok), .information,
                "\(pkg).\(name) stutters: callers already write the package name, so \(pkg).\(rest) reads better.",
                fix: renameFix(nameTok, to: rest))
        }

        // ctx context.Context first.
        if let idx = sig.params.firstIndex(where: { $0.typeText == "context.Context" }), idx > 0,
           !sig.params[..<idx].allSatisfy({ GoStyle.testingTypes.contains($0.typeText) }),
           let first = sig.params[idx].type.first, let last = sig.params[idx].type.last {
            add(GoStyleRules.contextFirst, range(first.start, last.end), .warning,
                "context.Context should be the first parameter of \(name) (ctx context.Context, …).")
        }

        // Doc comment on exported API.
        let exportedAPI = GoStyle.isExported(name) && (sig.receiverTypeName.map(GoStyle.isExported) ?? true)
        if exportedAPI, !isTest, pkg != "main", !hasDoc(line: line) {
            add(GoStyleRules.docComment, range(nameTok), .hint,
                "Exported \(sig.receiver == nil ? "function" : "method") \(name) has no doc comment; start one with \"// \(name) …\".",
                fix: docFix(name: name, atLine: line))
        }
    }

    // MARK: Types, vars, consts

    mutating func checkSpecs() {
        var groupsReported: Set<Int> = []
        // Groups where some spec (or the group itself) is documented.
        var documentedGroups: Set<Int> = []
        for s in specs where s.grouped {
            if hasDoc(line: pos(s.keyword.start).line) { documentedGroups.insert(s.keyword.start) }
            if let f = s.toks.first(where: \.isCode), hasDoc(line: pos(f.start).line) { documentedGroups.insert(s.keyword.start) }
        }
        for s in specs {
            let c = s.toks.filter(\.isCode)
            let names = specNames(c)
            guard let nameTok = names.first else { continue }
            let name = nameTok.text
            let kw = s.keyword.text

            // Doc comments.
            if !isTest, pkg != "main", let exported = names.first(where: { GoStyle.isExported($0.text) }) {
                let what = kw == "type" ? "type" : (kw == "var" ? "variable" : "constant")
                if !s.grouped {
                    let line = pos(s.keyword.start).line
                    if !hasDoc(line: line) {
                        add(GoStyleRules.docComment, range(exported), .hint,
                            "Exported \(what) \(exported.text) has no doc comment; start one with \"// \(exported.text) …\".",
                            fix: docFix(name: exported.text, atLine: line))
                    }
                } else if !documentedGroups.contains(s.keyword.start), !groupsReported.contains(s.keyword.start) {
                    groupsReported.insert(s.keyword.start)
                    add(GoStyleRules.docComment, range(exported), .hint,
                        "Exported \(what) \(exported.text) has no doc comment (neither it nor its \(kw) group).",
                        fix: docFix(name: exported.text, atLine: pos(exported.start).line))
                }
            }

            // Stutter.
            if !isTest, let rest = GoStyle.stutterRemainder(name, package: pkg) {
                add(GoStyleRules.stutter, range(nameTok), .information,
                    "\(pkg).\(name) stutters: callers already write the package name, so \(pkg).\(rest) reads better.",
                    fix: renameFix(nameTok, to: rest))
            }

            if kw == "type" {
                checkType(s, nameTok: nameTok)
            } else if kw == "var", names.count == 1, name != "_",
                      let eq = c.firstIndex(where: { $0.isOp("=") }), eq + 3 < c.count,
                      c[eq + 2].isOp("."), (c[eq + 1].text == "errors" && c[eq + 3].text == "New") || (c[eq + 1].text == "fmt" && c[eq + 3].text == "Errorf"),
                      !GoStyle.isErrorVariableName(name) {
                let new = GoStyle.errorVariableName(for: name)
                add(GoStyleRules.errorVarName, range(nameTok), .warning,
                    "Error variable \(name) should be named \(new): sentinel errors start with \(GoStyle.isExported(name) ? "Err" : "err").",
                    fix: renameFix(nameTok, to: new))
            }
        }
    }

    mutating func checkType(_ s: Spec, nameTok: GoTok) {
        let name = nameTok.text
        // Error types end in Error.
        let isErrorType = funcs.contains { $0.receiverTypeName == name && $0.name == "Error" && $0.params.isEmpty && $0.results.count == 1 && $0.results[0].typeText == "string" }
        if isErrorType, !name.hasSuffix("Error") {
            let new = name.hasSuffix("Err") ? String(name.dropLast(3)) + "Error" : name + "Error"
            add(GoStyleRules.errorTypeName, range(nameTok), .information,
                "\(name) implements error; error types are named like \(new).", fix: renameFix(nameTok, to: new))
        }
        // One-method interfaces: method name + -er.
        guard !isTest, let body = typeBody(s.toks, keyword: "interface") else { return }
        var methodNames: [String] = []
        for e in body {
            let ec = e.filter(\.isCode)
            guard !ec.isEmpty else { continue }
            if ec.contains(where: { $0.isOp("|") || $0.isOp("~") }) { return }        // constraint
            if ec.count >= 2, ec[0].kind == .ident, ec[1].isOp("(") { methodNames.append(ec[0].text) } else { return }   // embedded
        }
        let lower = name.lowercased()
        guard methodNames.count == 1, let m = methodNames.first, !lower.hasSuffix("er"), !lower.hasSuffix("or") else { return }
        let suggested = GoStyle.erName(forMethod: m, exported: GoStyle.isExported(name))
        add(GoStyleRules.interfaceName, range(nameTok), .hint,
            "One-method interface \(name): by convention it is named after its method plus -er, such as \(suggested).",
            fix: renameFix(nameTok, to: suggested))
    }

    // MARK: else after return

    mutating func checkElses() {
        let terminators: Set<String> = ["return", "break", "continue", "goto"]
        for idx in nc.indices where nc[idx].kind == .keyword && nc[idx].text == "if" {
            // Not the `if` of an `else if`.
            var p = idx - 1
            while p >= 0, nc[p].kind == .newline { p -= 1 }
            if p >= 0, nc[p].kind == .keyword, nc[p].text == "else" { continue }
            // Block `{` of this if; bail on an init statement that declares variables.
            var j = idx + 1
            var depth = 0
            var sawSemi = false
            var declares = false
            while j < nc.count {
                let t = nc[j]
                if t.kind == .newline && depth == 0 { break }
                if t.kind == .op {
                    if t.text == "(" || t.text == "[" { depth += 1 }
                    if t.text == ")" || t.text == "]" { depth -= 1 }
                    if depth == 0 && t.text == ":=" && !sawSemi { declares = true }
                    if depth == 0 && t.text == ";" { sawSemi = true }
                    if depth == 0 && t.text == "{" { break }
                }
                j += 1
            }
            guard j < nc.count, nc[j].isOp("{"), !(declares && sawSemi), let close = GoScanner.matchForward(nc, j),
                  close + 2 < nc.count, nc[close + 1].kind == .keyword, nc[close + 1].text == "else", nc[close + 2].isOp("{"),
                  let elseClose = GoScanner.matchForward(nc, close + 2) else { continue }
            // Last statement of the if block.
            var k = close - 1
            while k > j, nc[k].kind == .newline { k -= 1 }
            guard k > j else { continue }
            var d = 0
            while k > j {
                let t = nc[k]
                if t.kind == .op {
                    if t.text == ")" || t.text == "]" || t.text == "}" { d += 1 }
                    if t.text == "(" || t.text == "[" || t.text == "{" { d -= 1 }
                }
                if d == 0 && (t.kind == .newline || t.isOp(";")) { break }
                k -= 1
            }
            // `k` is the block's `{` or the newline / `;` before the last statement.
            let first = nc[k + 1]
            let isTerminator = (first.kind == .keyword && terminators.contains(first.text)) ||
                (first.kind == .ident && first.text == "panic")
            guard isTerminator else { continue }
            let elseTok = nc[close + 1]
            add(GoStyleRules.elseAfterReturn, range(elseTok), .information,
                "The if block ends with \(first.text), so this else is not needed: drop it and outdent its block.",
                fix: elseFix(ifClose: nc[close].start, elseOpen: nc[close + 2].start, elseClose: nc[elseClose].start))
        }
    }

    /// `} else {\n body \n}` -> `}\n body (outdented)`; nil when the layout is not gofmt-like.
    func elseFix(ifClose: Int, elseOpen: Int, elseClose: Int) -> GoStyleFix? {
        let openLine = lines.line(forOffset: elseOpen)
        let closeLine = lines.line(forOffset: elseClose)
        guard closeLine > openLine else { return nil }
        let openRange = lines.lineRange(openLine)
        let afterOpen = ns.substring(with: NSRange(location: elseOpen + 1, length: NSMaxRange(openRange) - elseOpen - 1))
        let closeRange = lines.lineRange(closeLine)
        let beforeClose = ns.substring(with: NSRange(location: closeRange.location, length: elseClose - closeRange.location))
        guard afterOpen.trimmingCharacters(in: .whitespaces).isEmpty, beforeClose.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let bodyStart = lines.lineStarts[openLine + 1]
        let bodyEnd = closeRange.location
        // A multi-line raw string would change if its lines were outdented.
        if all.contains(where: { $0.kind == .rawString && $0.start >= bodyStart && $0.end <= bodyEnd && $0.text.contains("\n") }) { return nil }
        let body = ns.substring(with: NSRange(location: bodyStart, length: bodyEnd - bodyStart))
        let outdented = body.components(separatedBy: "\n").map { line -> String in
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            if line.hasPrefix("    ") { return String(line.dropFirst(4)) }
            return line
        }.joined(separator: "\n")
        var trimmed = outdented
        while trimmed.hasSuffix("\n") { trimmed.removeLast() }
        let newText = trimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n" + trimmed
        return GoStyleFix(title: "Remove else and outdent its block",
                          kind: .edits([LSPTextEdit(range: range(ifClose + 1, elseClose + 1), newText: newText)], caret: nil))
    }
}
