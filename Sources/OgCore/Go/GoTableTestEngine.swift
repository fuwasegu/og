import Foundation

/// Implementation of `GoTableTest` (gotests-style table-driven test skeletons).
enum GoTableTestEngine {
    static func generate(source: String, fileName: String, line: Int) -> GeneratedTest? {
        let all = GoScanner.tokenize(source)
        let code = all.filter(\.isCode)
        let lines = TextLines(source)
        guard let pkg = GoSignature.packageName(code) else { return nil }

        // Top-level func whose header or body contains `line`.
        var sig: GoFuncSig?
        var depth = 0
        for (i, t) in code.enumerated() {
            if t.kind == .op {
                if t.text == "{" || t.text == "(" || t.text == "[" { depth += 1 }
                if t.text == "}" || t.text == ")" || t.text == "]" { depth -= 1 }
            }
            guard depth == 0, t.kind == .keyword, t.text == "func", let s = GoSignature.parseFunc(code, at: i), s.name != nil else { continue }
            let first = lines.line(forOffset: t.start)
            let lastTok = s.bodyClose ?? s.bodyOpen ?? i
            let last = lines.line(forOffset: code[lastTok].start)
            if first <= line && line <= last { sig = s; break }
        }
        guard let sig, let funcName = sig.name, funcName != "init", funcName != "_" else { return nil }

        let decls = GoSignature.typeDecls(all)
        // Concrete types for type parameters.
        var subst: [String: String] = [:]
        for p in sig.typeParams { if let n = p.name { subst[n] = concreteType(p.type, decls: decls) } }
        var receiverText: String?
        if let rname = sig.receiverTypeName {
            let args = sig.receiverTypeArgs
            let declParams = decls[rname]?.typeParams ?? []
            var concrete: [String] = []
            for (i, a) in args.enumerated() {
                let c = i < declParams.count ? concreteType(declParams[i].type, decls: decls) : "int"
                subst[a] = c
                concrete.append(c)
            }
            receiverText = concrete.isEmpty ? rname : "\(rname)[\(concrete.joined(separator: ", "))]"
        }
        func typeString(_ toks: [GoTok]) -> String {
            var out = toks
            for (i, t) in out.enumerated() where t.kind == .ident {
                if i > 0, out[i - 1].isOp(".") { continue }
                if let c = subst[t.text] { out[i].text = c }
            }
            return GoScanner.render(out[...])
        }

        // Arguments.
        struct Field { var name: String; var type: String }
        var args: [Field] = []
        var callArgs: [String] = []
        var used = Set<String>()
        for (i, p) in sig.params.enumerated() {
            var n = p.name ?? ""
            if n.isEmpty || n == "_" || used.contains(n) { n = "arg\(i)" }
            used.insert(n)
            let ty = typeString(p.type)
            args.append(Field(name: n, type: p.variadic ? "[]" + ty : ty))
            callArgs.append("tt.args.\(n)" + (p.variadic ? "..." : ""))
        }
        // Results.
        let resultTypes = sig.results.map { typeString($0.type) }
        let hasErr = resultTypes.last == "error"
        let valueTypes = hasErr ? Array(resultTypes.dropLast()) : resultTypes
        let wantNames = valueTypes.indices.map { $0 == 0 ? "want" : "want\($0)" }
        let gotNames = valueTypes.indices.map { $0 == 0 ? "got" : "got\($0)" }

        // Receiver and call.
        var prelude: [String] = []
        var callee = funcName
        var display = "\(funcName)()"
        if !sig.typeParams.isEmpty {
            let inst = sig.typeParams.compactMap { $0.name.flatMap { subst[$0] } }
            callee += "[\(inst.joined(separator: ", "))]"
        }
        if let rname = sig.receiverTypeName, let rtext = receiverText {
            display = "\(rname).\(funcName)()"
            let literal: Bool
            switch decls[rname]?.kind {
            case .structType?, .composite?, nil: literal = true
            default: literal = false
            }
            let recv: String
            if sig.receiverIsPointer {
                recv = literal ? "(&\(rtext){})" : "new(\(rtext))"
            } else if literal {
                recv = "(\(rtext){})"         // parenthesized: `T{}` is ambiguous in an if header
            } else {
                prelude.append("var recv \(rtext)")
                recv = "recv"
            }
            callee = "\(recv).\(funcName)"
        }
        let call = "\(callee)(\(callArgs.joined(separator: ", ")))"

        // Test name.
        func testPrefix(_ s: String) -> String {
            guard let f = s.unicodeScalars.first else { return "Test" }
            return CharacterSet.uppercaseLetters.contains(f) ? "Test" : "Test_"
        }
        let testName: String
        if let rname = sig.receiverTypeName {
            testName = testPrefix(rname) + rname + "_" + funcName
        } else {
            testName = testPrefix(funcName) + funcName
        }

        // Body.
        var needsReflect = false
        var b: [String] = []
        b.append("func \(testName)(t *testing.T) {")
        if !args.isEmpty {
            b.append("\ttype args struct {")
            b += alignFields(args.map { ($0.name, $0.type) }).map { "\t\t" + $0 }
            b.append("\t}")
        }
        var tableFields: [(String, String)] = [("name", "string")]
        if !args.isEmpty { tableFields.append(("args", "args")) }
        for (w, ty) in zip(wantNames, valueTypes) { tableFields.append((w, ty)) }
        if hasErr { tableFields.append(("wantErr", "bool")) }
        b.append("\ttests := []struct {")
        b += alignFields(tableFields).map { "\t\t" + $0 }
        b.append("\t}{")
        b.append("\t\t// TODO: Add test cases.")
        b.append("\t}")
        b.append("\tfor _, tt := range tests {")
        b.append("\t\tt.Run(tt.name, func(t *testing.T) {")
        let ind = "\t\t\t"
        b += prelude.map { ind + $0 }
        let errCheck = [
            "\(ind)\tt.Errorf(\"\(display) error = %v, wantErr %v\", err, tt.wantErr)",
        ]
        if valueTypes.isEmpty {
            if hasErr {
                b.append("\(ind)if err := \(call); (err != nil) != tt.wantErr {")
                b += errCheck
                b.append("\(ind)}")
            } else {
                b.append("\(ind)\(call)")
            }
        } else {
            let lhs = gotNames + (hasErr ? ["err"] : [])
            b.append("\(ind)\(lhs.joined(separator: ", ")) := \(call)")
            if hasErr {
                b.append("\(ind)if (err != nil) != tt.wantErr {")
                b += errCheck
                b.append("\(ind)\treturn")
                b.append("\(ind)}")
            }
            for (i, ty) in valueTypes.enumerated() {
                let g = gotNames[i], w = wantNames[i]
                let label = valueTypes.count == 1 ? "\(display) = %v, want %v" : "\(display) \(g) = %v, want %v"
                if isComparableBasic(ty, decls: decls) {
                    b.append("\(ind)if \(g) != tt.\(w) {")
                } else {
                    needsReflect = true
                    b.append("\(ind)if !reflect.DeepEqual(\(g), tt.\(w)) {")
                }
                b.append("\(ind)\tt.Errorf(\"\(label)\", \(g), tt.\(w))")
                b.append("\(ind)}")
            }
        }
        b.append("\t\t})")
        b.append("\t}")
        b.append("}")
        let function = b.joined(separator: "\n")

        // Imports: testing, reflect, and packages used in field types.
        var imports: [(name: String?, path: String)] = [(nil, "testing")]
        if needsReflect { imports.append((nil, "reflect")) }
        let sourceImports = GoSignature.imports(code)
        var qualifiers = Set<String>()
        for f in args.map(\.type) + valueTypes {
            for q in qualifiersIn(f) { qualifiers.insert(q) }
        }
        for q in qualifiers.sorted() {
            guard let imp = sourceImports.first(where: { $0.name == q }) else { continue }
            if imports.contains(where: { $0.path == imp.path }) { continue }
            let lastElem = imp.path.split(separator: "/").last.map(String.init) ?? imp.path
            imports.append((imp.alias ?? (lastElem == q ? nil : q), imp.path))
        }
        let importText = importBlock(imports)

        let base = fileName.hasSuffix(".go") ? String(fileName.dropLast(3)) : fileName
        let testFile = base.hasSuffix("_test") ? base + ".go" : base + "_test.go"
        let newFile = "package \(pkg)\n\n\(importText)\n\n\(function)\n"
        return GeneratedTest(testFileName: testFile, functionName: testName, newFileContent: newFile, appendContent: "\n" + function + "\n")
    }

    // MARK: - Helpers

    static func alignFields(_ fields: [(String, String)]) -> [String] {
        let w = fields.map(\.0.count).max() ?? 0
        return fields.map { $0.0 + String(repeating: " ", count: w - $0.0.count + 1) + $0.1 }
    }

    static func importBlock(_ imports: [(name: String?, path: String)]) -> String {
        func spec(_ i: (name: String?, path: String)) -> String { (i.name.map { $0 + " " } ?? "") + "\"\(i.path)\"" }
        let std = imports.filter { !($0.path.split(separator: "/").first?.contains(".") ?? false) }.sorted { $0.path < $1.path }
        let other = imports.filter { $0.path.split(separator: "/").first?.contains(".") ?? false }.sorted { $0.path < $1.path }
        if std.count + other.count == 1, let only = (std + other).first { return "import \(spec(only))" }
        var lines = std.map { "\t" + spec($0) }
        if !std.isEmpty && !other.isEmpty { lines.append("") }
        lines += other.map { "\t" + spec($0) }
        return "import (\n" + lines.joined(separator: "\n") + "\n)"
    }

    static func qualifiersIn(_ type: String) -> [String] {
        let toks = GoScanner.tokenize(type)
        var out: [String] = []
        for i in toks.indices where i + 2 < toks.count {
            if toks[i].kind == .ident, toks[i + 1].isOp("."), toks[i + 2].kind == .ident, i == 0 || !toks[i - 1].isOp(".") {
                out.append(toks[i].text)
            }
        }
        return out
    }

    static func isComparableBasic(_ type: String, decls: [String: (kind: GoSignature.TypeKind, typeParams: [GoParam])]) -> Bool {
        if GoTypes.basic.contains(type) { return true }
        if case .basic? = decls[type]?.kind { return true }
        return false
    }

    /// A concrete type argument satisfying a type-parameter constraint (best effort).
    static func concreteType(_ constraint: [GoTok], decls: [String: (kind: GoSignature.TypeKind, typeParams: [GoParam])]) -> String {
        let text = GoScanner.render(constraint[...])
        switch text {
        case "any", "interface{}", "comparable", "cmp.Ordered", "constraints.Ordered", "constraints.Integer",
             "constraints.Signed": return "int"
        case "constraints.Unsigned": return "uint"
        case "constraints.Float": return "float64"
        case "constraints.Complex": return "complex128"
        default: break
        }
        // Union / interface literal: first basic term (`~string | ~[]byte` → string).
        let code = constraint.filter(\.isCode)
        if let t = firstBasicTerm(code) { return t }
        return "int"
    }

    private static func firstBasicTerm(_ code: [GoTok]) -> String? {
        for (i, t) in code.enumerated() where t.kind == .ident && GoTypes.basic.contains(t.text) {
            if i + 1 < code.count, code[i + 1].isOp(".") { continue }
            if i > 0, code[i - 1].isOp(".") { continue }
            return t.text
        }
        return nil
    }
}
