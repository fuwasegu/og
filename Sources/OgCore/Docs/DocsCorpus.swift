import Foundation

/// Target Go build platform (`GOOS` / `GOARCH` / optional target `goVersion`) used to evaluate
/// `//go:build` and filename constraints (R-2, S-7).
public struct GoBuildTarget: Sendable, Hashable {
    public var goos: String
    public var goarch: String
    public var goVersion: GoVersion?

    public init(goos: String, goarch: String, goVersion: GoVersion? = nil) {
        self.goos = goos
        self.goarch = goarch
        self.goVersion = goVersion
    }

    public static var hostDefault: GoBuildTarget {
        #if arch(arm64)
        return GoBuildTarget(goos: "darwin", goarch: "arm64")
        #else
        return GoBuildTarget(goos: "darwin", goarch: "amd64")
        #endif
    }

    func withDefaultVersion(_ rawVersion: String) -> GoBuildTarget {
        guard goVersion == nil, let parsed = GoVersion(parsing: rawVersion) else { return self }
        return GoBuildTarget(goos: goos, goarch: goarch, goVersion: parsed)
    }
}

/// Extracts structured `DocsChunk` items from authoritative Go sources without HTML scraping (FR-4, FR-7):
/// 1. Local GOROOT `src/` `.go` files (GoDoc comments + exported `func`/`method`/`type`/`interface`/`const`/`var` + `Example*` tests)
/// 2. `golang/website` Markdown guides (stripping Hugo front matter and shortcode tags while keeping inner prose)
/// 3. Language specification / release notes sections
public enum DocsCorpusExtractor {
    /// Target platform tags used when filtering `//go:build` and filename suffixes (M-13, R-2).
    public static let defaultTargetGOOS = "darwin"
    private static let knownOSNames: Set<String> = [
        "aix", "android", "darwin", "dragonfly", "freebsd", "hurd", "illumos", "ios",
        "js", "linux", "nacl", "netbsd", "openbsd", "plan9", "solaris", "wasip1", "windows"
    ]
    private static let knownArchNames: Set<String> = [
        "386", "amd64", "arm", "arm64", "loong64", "mips", "mips64", "mips64le",
        "mipsle", "ppc64", "ppc64le", "riscv64", "s390x", "wasm"
    ]
    private static let unixOSNames: Set<String> = [
        "aix", "android", "darwin", "dragonfly", "freebsd", "hurd", "illumos", "ios",
        "linux", "netbsd", "openbsd", "solaris"
    ]

    /// Extracts standard library chunks from a local `GOROOT/src` directory (FR-4-1, FR-7, L-6).
    /// Includes `builtin` (L-6) and skips `internal/`, `vendor/`, `testdata/`, `cmd/`.
    public static func extractStdlib(
        fromGorootSrc srcRoot: URL,
        goVersion: String,
        target: GoBuildTarget = .hostDefault
    ) -> [DocsChunk] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: srcRoot.path) else { return [] }

        var packageDirs: [URL] = []
        if let enumerator = fm.enumerator(
            at: srcRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDir else { continue }
                let name = url.lastPathComponent
                if name == "internal" || name == "vendor" || name == "testdata" || name == "cmd" {
                    enumerator.skipDescendants()
                    continue
                }
                packageDirs.append(url)
            }
        }

        let resolvedTarget = target.withDefaultVersion(goVersion)
        var chunks: [DocsChunk] = []
        for dir in packageDirs.sorted(by: { $0.path < $1.path }) {
            let relPath = relativePackagePath(dir: dir, root: srcRoot)
            guard !relPath.isEmpty else { continue }
            chunks.append(contentsOf: extractStdlibPackage(directory: dir, importPath: relPath, goVersion: goVersion, target: resolvedTarget))
        }
        return chunks
    }

    /// Extracts exported symbols (`func`, `method`, `type`/`interface`, `const`, `var`, including grouped declarations)
    /// and attaches `Example*` functions to their exact parent symbol (H-1, M-12..14, R-2, R-4, R-7).
    public static func extractStdlibPackage(
        directory: URL,
        importPath: String,
        goVersion: String,
        target: GoBuildTarget = .hostDefault
    ) -> [DocsChunk] {
        let target = target.withDefaultVersion(goVersion)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        let goFiles = entries
            .filter { $0.pathExtension == "go" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        // First collect examples from `*_test.go` files keyed by exact target symbol name.
        var examplesBySymbol: [String: String] = [:]
        for file in goFiles where file.lastPathComponent.hasSuffix("_test.go") {
            guard matchesBuildFilename(file.lastPathComponent, target: target),
                  let text = try? String(contentsOf: file, encoding: .utf8),
                  matchesBuildConstraints(in: text, target: target) else { continue }
            for (targetSymbol, snippet) in parseExamples(from: text) {
                if examplesBySymbol[targetSymbol] == nil {
                    examplesBySymbol[targetSymbol] = snippet
                }
            }
        }

        var chunks: [DocsChunk] = []
        var packageDoc: String?

        for file in goFiles where !file.lastPathComponent.hasSuffix("_test.go") {
            guard matchesBuildFilename(file.lastPathComponent, target: target),
                  let text = try? String(contentsOf: file, encoding: .utf8),
                  matchesBuildConstraints(in: text, target: target) else { continue }
            let parsed = parseGoDocFile(text: text, importPath: importPath, goVersion: goVersion, examples: examplesBySymbol)
            if packageDoc == nil, let doc = parsed.packageDoc, !doc.isEmpty {
                packageDoc = doc
            }
            chunks.append(contentsOf: parsed.chunks)
        }

        if let doc = packageDoc {
            let summary = firstSentence(of: doc)
            let pkgExample = examplesBySymbol[""]
            let pkgChunk = DocsChunk(
                goVersion: goVersion,
                source: .stdlib,
                packageName: importPath,
                documentID: importPath,
                symbol: "",
                kind: .package,
                title: "package \(importPath)",
                anchor: importPath,
                since: nil,
                summary: summary,
                signature: "import \"\(importPath)\"",
                example: pkgExample,
                body: doc
            )
            chunks.insert(pkgChunk, at: 0)
        }

        return deduplicateByStableID(chunks)
    }

    /// Extracts heading-scoped chunks from an official guide Markdown file (e.g. `golang/website/_content/doc/`),
    /// stripping Hugo front matter and shortcode tags (preserving inner prose, M-10), ignoring `#` inside code
    /// fences (M-11), supporting headings H1–H6, and assigning unique document-scoped stable IDs (H-6).
    public static func extractGuideMarkdown(
        text: String,
        documentTitle: String,
        documentID: String? = nil,
        source: DocsSourceKind = .guide,
        goVersion: String
    ) -> [DocsChunk] {
        let docID = documentID ?? slugifyAnchor(documentTitle).lowercased()
        let cleaned = stripHugoFrontMatterAndShortcodes(text)
        let lines = cleaned.components(separatedBy: "\n")

        var chunks: [DocsChunk] = []
        var anchorCounts: [String: Int] = [:]
        var currentHeading = documentTitle
        var currentLines: [String] = []
        var inFence = false
        var fenceMarker = ""

        func flush() {
            let body = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return }
            let baseSlug = slugifyAnchor(currentHeading)
            let count = (anchorCounts[baseSlug] ?? 0) + 1
            anchorCounts[baseSlug] = count
            let anchor = count == 1 ? "#\(baseSlug)" : "#\(baseSlug)-\(count)"
            let example = extractFirstGoFence(from: body)
            let summary = firstSentence(of: stripCodeFences(body))
            let chunk = DocsChunk(
                goVersion: goVersion,
                source: source,
                packageName: "",
                documentID: docID,
                symbol: currentHeading,
                kind: source == .release ? .releaseNote : .section,
                title: "\(documentTitle): \(currentHeading)",
                anchor: anchor,
                since: nil,
                summary: summary.isEmpty ? currentHeading : summary,
                signature: nil,
                example: example,
                body: body
            )
            chunks.append(chunk)
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inFence {
                currentLines.append(line)
                if trimmed.hasPrefix(fenceMarker) && trimmed.dropFirst(fenceMarker.count).trimmingCharacters(in: .whitespaces).isEmpty {
                    inFence = false
                    fenceMarker = ""
                }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let ch = trimmed.first ?? "`"
                fenceMarker = String(trimmed.prefix(while: { $0 == ch }))
                inFence = true
                currentLines.append(line)
                continue
            }
            if let heading = parseMarkdownHeading(line) {
                flush()
                currentHeading = heading
                currentLines = []
            } else {
                currentLines.append(line)
            }
        }
        flush()
        return chunks
    }

    /// Removes Hugo YAML/TOML front matter and shortcode delimiters (`{{< ... >}}`, `{{% ... %}}`),
    /// preserving the prose body inside paired shortcodes like `{{< note >}}...{{< /note >}}` (M-10).
    /// Hugo template comments `{{/* ... */}}` are removed completely.
    public static func stripHugoFrontMatterAndShortcodes(_ raw: String) -> String {
        var text = raw
        if text.hasPrefix("---\n") || text.hasPrefix("---\r\n") {
            let afterOpen = text.dropFirst(4)
            if let closeRange = afterOpen.range(of: "\n---") {
                text = String(afterOpen[closeRange.upperBound...])
                    .trimmingCharacters(in: .newlines)
            }
        } else if text.hasPrefix("+++\n") || text.hasPrefix("+++\r\n") {
            let afterOpen = text.dropFirst(4)
            if let closeRange = afterOpen.range(of: "\n+++") {
                text = String(afterOpen[closeRange.upperBound...])
                    .trimmingCharacters(in: .newlines)
            }
        }
        // Remove template comments entirely: {{/* ... */}}
        text = text.replacingOccurrences(of: #"\{\{/\*[\s\S]*?\*/\}\}"#, with: "", options: .regularExpression)
        // Remove shortcode tags themselves while preserving inner prose of paired shortcodes (M-10).
        text = text.replacingOccurrences(of: #"\{\{[<%][\s\S]*?[%>]\}\}"#, with: "", options: .regularExpression)
        // Strip Hugo heading ID attributes like `{#for_statements}`
        text = text.replacingOccurrences(of: #"\s*\{#[^}]+\}"#, with: "", options: .regularExpression)
        return text
    }

    // MARK: - Build constraints filtering (M-13, R-2: recursive-descent parser + GOOS/GOARCH)

    /// Evaluates filename OS/ARCH suffixes like `foo_windows.go`, `windows_arm64.go`, `bar_linux_amd64.go`, or `asm_386.go` (R-2, S-4).
    public static func matchesBuildFilename(_ fileName: String, target: GoBuildTarget = .hostDefault) -> Bool {
        var base = fileName
        if base.hasSuffix("_test.go") {
            base = String(base.dropLast("_test.go".count))
        } else if base.hasSuffix(".go") {
            base = String(base.dropLast(".go".count))
        }
        let parts = base.split(separator: "_").map(String.init)
        guard parts.count >= 2 else { return true }
        let last = parts[parts.count - 1]
        // S-4: check second-to-last GOOS whenever parts.count >= 2 (matches Go's `go/build` goodOSArchFile rule, e.g. `windows_arm64.go`).
        let prev = parts[parts.count - 2]

        if knownArchNames.contains(last) {
            if last != target.goarch { return false }
            if knownOSNames.contains(prev), prev != target.goos { return false }
            return true
        }
        if knownOSNames.contains(last) {
            return last == target.goos
        }
        return true
    }

    /// Evaluates `//go:build` and legacy `// +build` constraints before the `package` line (R-2).
    public static func matchesBuildConstraints(in text: String, target: GoBuildTarget = .hostDefault) -> Bool {
        var goBuildExpr: String?
        var plusBuildLines: [String] = []
        for raw in text.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("package ") { break }
            if trimmed.hasPrefix("//go:build ") {
                goBuildExpr = String(trimmed.dropFirst("//go:build ".count)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("// +build ") {
                plusBuildLines.append(String(trimmed.dropFirst("// +build ".count)).trimmingCharacters(in: .whitespaces))
            }
        }
        if let expr = goBuildExpr {
            return evaluateGoBuildExpr(expr, target: target)
        }
        if !plusBuildLines.isEmpty {
            return plusBuildLines.allSatisfy { evaluatePlusBuildLine($0, target: target) }
        }
        return true
    }

    /// Recursive-descent evaluator for Go `//go:build` boolean expressions (`||`, `&&`, `!`, parentheses) (R-2).
    public static func evaluateGoBuildExpr(_ expr: String, target: GoBuildTarget = .hostDefault) -> Bool {
        var parser = BuildExprParser(expr: expr, target: target)
        return parser.parseOr()
    }

    private struct BuildExprParser {
        enum Token: Equatable {
            case lparen, rparen, not, and, or, tag(String)
        }

        let tokens: [Token]
        var index: Int = 0
        let target: GoBuildTarget

        init(expr: String, target: GoBuildTarget) {
            self.tokens = Self.tokenize(expr)
            self.target = target
        }

        static func tokenize(_ s: String) -> [Token] {
            var out: [Token] = []
            let chars = Array(s)
            var i = 0
            while i < chars.count {
                let c = chars[i]
                if c.isWhitespace { i += 1; continue }
                if c == "(" { out.append(.lparen); i += 1; continue }
                if c == ")" { out.append(.rparen); i += 1; continue }
                if c == "!" { out.append(.not); i += 1; continue }
                if c == "&", i + 1 < chars.count, chars[i + 1] == "&" { out.append(.and); i += 2; continue }
                if c == "|", i + 1 < chars.count, chars[i + 1] == "|" { out.append(.or); i += 2; continue }
                var word = ""
                while i < chars.count {
                    let ch = chars[i]
                    if ch.isLetter || ch.isNumber || ch == "_" || ch == "." {
                        word.append(ch)
                        i += 1
                    } else {
                        break
                    }
                }
                if !word.isEmpty {
                    out.append(.tag(word))
                } else {
                    i += 1
                }
            }
            return out
        }

        mutating func parseOr() -> Bool {
            var value = parseAnd()
            while index < tokens.count && tokens[index] == .or {
                index += 1
                let rhs = parseAnd()
                value = value || rhs
            }
            return value
        }

        mutating func parseAnd() -> Bool {
            var value = parseUnary()
            while index < tokens.count && tokens[index] == .and {
                index += 1
                let rhs = parseUnary()
                value = value && rhs
            }
            return value
        }

        mutating func parseUnary() -> Bool {
            guard index < tokens.count else { return false }
            switch tokens[index] {
            case .not:
                index += 1
                return !parseUnary()
            case .lparen:
                index += 1
                let inner = parseOr()
                if index < tokens.count && tokens[index] == .rparen { index += 1 }
                return inner
            case .tag(let name):
                index += 1
                return DocsCorpusExtractor.buildTagActive(name, target: target)
            default:
                index += 1
                return false
            }
        }
    }

    private static func evaluatePlusBuildLine(_ line: String, target: GoBuildTarget) -> Bool {
        let clauses = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        return clauses.contains { clause in
            let terms = clause.split(separator: ",")
            return terms.allSatisfy { rawTerm in
                let t = String(rawTerm)
                if t.hasPrefix("!") {
                    return !buildTagActive(String(t.dropFirst()), target: target)
                }
                return buildTagActive(t, target: target)
            }
        }
    }

    private static func buildTagActive(_ tag: String, target: GoBuildTarget) -> Bool {
        if tag == "ignore" { return false }
        if tag == target.goos || tag == target.goarch { return true }
        if tag == "unix" { return unixOSNames.contains(target.goos) }
        if tag == "cgo" || tag == "gc" { return true }
        if knownOSNames.contains(tag) || knownArchNames.contains(tag) { return false }
        if tag.hasPrefix("go1.") {
            // S-7: compare Go release build tag against target pack Go version when known.
            if let tagVer = GoVersion(parsing: tag), let targetVer = target.goVersion {
                return targetVer.isAtLeast(tagVer)
            }
            return true
        }
        return false
    }

    // MARK: - Go Source Parsing (stdlib GoDoc, const/var, multiline func, interface, Examples)

    private struct ParsedFile {
        var packageDoc: String?
        var chunks: [DocsChunk]
    }

    private static func parseGoDocFile(
        text: String,
        importPath: String,
        goVersion: String,
        examples: [String: String]
    ) -> ParsedFile {
        let lines = text.components(separatedBy: "\n")
        var chunks: [DocsChunk] = []
        var pendingComments: [String] = []
        var packageDoc: String?
        var inBlockComment = false
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if inBlockComment {
                if let end = trimmed.range(of: "*/") {
                    let piece = String(trimmed[..<end.lowerBound]).trimmingCharacters(in: .whitespaces)
                    if !piece.isEmpty { pendingComments.append(piece) }
                    inBlockComment = false
                } else {
                    pendingComments.append(trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "* ")))
                }
                i += 1
                continue
            }
            if trimmed.hasPrefix("/*") {
                if let end = trimmed.range(of: "*/") {
                    let inner = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<end.lowerBound])
                        .trimmingCharacters(in: .whitespaces)
                    if !inner.isEmpty { pendingComments.append(inner) }
                } else {
                    inBlockComment = true
                    let inner = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    if !inner.isEmpty { pendingComments.append(inner) }
                }
                i += 1
                continue
            }
            if trimmed.hasPrefix("//") {
                let body = String(trimmed.dropFirst(2))
                if body.hasPrefix("go:") || body.hasPrefix("+build") { i += 1; continue }
                pendingComments.append(body.hasPrefix(" ") ? String(body.dropFirst()) : body)
                i += 1
                continue
            }
            if trimmed.isEmpty {
                pendingComments.removeAll()
                i += 1
                continue
            }
            if trimmed.hasPrefix("package ") {
                if !pendingComments.isEmpty && packageDoc == nil {
                    packageDoc = pendingComments.joined(separator: "\n")
                }
                pendingComments.removeAll()
                i += 1
                continue
            }

            // Exported top-level declarations only (no leading whitespace).
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                let doc = pendingComments.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

                // Grouped const (...) or var (...) blocks (H-1)
                if trimmed.hasPrefix("const (") || trimmed == "const(" || trimmed.hasPrefix("var (") || trimmed == "var(" {
                    let kind: DocsChunkKind = trimmed.hasPrefix("const") ? .constant : .variable
                    let (groupChunks, nextIndex) = parseValueGroup(
                        lines: lines,
                        startIndex: i,
                        kind: kind,
                        groupDoc: doc,
                        importPath: importPath,
                        goVersion: goVersion,
                        examples: examples
                    )
                    chunks.append(contentsOf: groupChunks)
                    pendingComments.removeAll()
                    i = nextIndex
                    continue
                }

                // Single-line `const A, B = 1, 2` or `var A, B int = ...` (H-1, R-7: supports multi-name specs)
                if trimmed.hasPrefix("const ") || trimmed.hasPrefix("var ") {
                    let kind: DocsChunkKind = trimmed.hasPrefix("const ") ? .constant : .variable
                    let keywordLen = kind == .constant ? 6 : 4
                    let rest = String(trimmed.dropFirst(keywordLen)).trimmingCharacters(in: .whitespaces)
                    for name in leadingIdentifierList(rest) where isExported(name) {
                        chunks.append(makeStdlibChunk(
                            importPath: importPath,
                            symbol: name,
                            kind: kind,
                            signature: trimmed,
                            doc: doc,
                            example: examples[name],
                            goVersion: goVersion
                        ))
                    }
                    pendingComments.removeAll()
                    i += 1
                    continue
                }

                // `func` (supports multiline parameter/return lists, M-14)
                if trimmed.hasPrefix("func ") {
                    let (fullSig, nextIdx) = collectFuncSignature(lines: lines, startIndex: i)
                    if let decl = parseExportedFuncSignature(fullSig) {
                        // M-12: attach only exact symbol example (do NOT inherit type example onto every method).
                        chunks.append(makeStdlibChunk(
                            importPath: importPath,
                            symbol: decl.symbol,
                            kind: decl.kind,
                            signature: decl.signature,
                            doc: doc,
                            example: examples[decl.symbol],
                            goVersion: goVersion
                        ))
                    }
                    pendingComments.removeAll()
                    i = nextIdx
                    continue
                }

                // Grouped `type (...)` blocks (R-4)
                if trimmed.hasPrefix("type (") || trimmed == "type(" {
                    let (groupChunks, nextIdx) = parseTypeGroup(
                        lines: lines,
                        startIndex: i,
                        groupDoc: doc,
                        importPath: importPath,
                        goVersion: goVersion,
                        examples: examples
                    )
                    chunks.append(contentsOf: groupChunks)
                    pendingComments.removeAll()
                    i = nextIdx
                    continue
                }

                // Single `type` (preserves full interface method set and struct definition summary, M-14, R-7)
                if trimmed.hasPrefix("type ") {
                    let (declOpt, nextIdx) = parseExportedType(lines: lines, startIndex: i)
                    if let decl = declOpt {
                        chunks.append(makeStdlibChunk(
                            importPath: importPath,
                            symbol: decl.symbol,
                            kind: .type,
                            signature: decl.signature,
                            doc: doc,
                            example: examples[decl.symbol],
                            goVersion: goVersion
                        ))
                    }
                    pendingComments.removeAll()
                    i = nextIdx
                    continue
                }
            }

            pendingComments.removeAll()
            i += 1
        }
        return ParsedFile(packageDoc: packageDoc, chunks: chunks)
    }

    private static func makeStdlibChunk(
        importPath: String,
        symbol: String,
        kind: DocsChunkKind,
        signature: String,
        doc: String,
        example: String?,
        goVersion: String
    ) -> DocsChunk {
        let summary = doc.isEmpty ? firstLine(of: signature) : firstSentence(of: doc)
        let body = doc.isEmpty ? signature : "\(signature)\n\n\(doc)"
        return DocsChunk(
            goVersion: goVersion,
            source: .stdlib,
            packageName: importPath,
            documentID: importPath,
            symbol: symbol,
            kind: kind,
            title: "\(importPath).\(symbol)",
            anchor: "\(importPath).\(symbol)",
            since: nil,
            summary: summary,
            signature: signature,
            example: example,
            body: body
        )
    }

    /// Parses grouped `const (...)` or `var (...)` blocks and emits a chunk per exported identifier (H-1).
    private static func parseValueGroup(
        lines: [String],
        startIndex: Int,
        kind: DocsChunkKind,
        groupDoc: String,
        importPath: String,
        goVersion: String,
        examples: [String: String]
    ) -> ([DocsChunk], Int) {
        var out: [DocsChunk] = []
        var itemComments: [String] = []
        let kw = kind == .constant ? "const" : "var"
        var i = startIndex + 1

        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed == ")" {
                return (out, i + 1)
            }
            if trimmed.isEmpty {
                itemComments.removeAll()
                i += 1
                continue
            }
            if trimmed.hasPrefix("//") {
                let body = String(trimmed.dropFirst(2))
                itemComments.append(body.hasPrefix(" ") ? String(body.dropFirst()) : body)
                i += 1
                continue
            }
            // Extract identifier (and optional inline comment after `//`)
            var codePart = trimmed
            var inlineComment = ""
            if let cIdx = findLineCommentStart(in: trimmed) {
                codePart = String(trimmed[..<cIdx]).trimmingCharacters(in: .whitespaces)
                let rawComment = String(trimmed[trimmed.index(cIdx, offsetBy: 2)...])
                inlineComment = rawComment.hasPrefix(" ") ? String(rawComment.dropFirst()) : rawComment
            }
            // Extract all comma-separated exported identifiers on the LHS (`A, B = 1, 2`, R-7)
            for name in leadingIdentifierList(codePart) where isExported(name) {
                var docParts: [String] = []
                if !itemComments.isEmpty {
                    docParts.append(itemComments.joined(separator: "\n"))
                } else if !groupDoc.isEmpty {
                    docParts.append(groupDoc)
                }
                if !inlineComment.isEmpty { docParts.append(inlineComment) }
                let combinedDoc = docParts.joined(separator: "\n")
                out.append(makeStdlibChunk(
                    importPath: importPath,
                    symbol: name,
                    kind: kind,
                    signature: "\(kw) \(codePart)",
                    doc: combinedDoc,
                    example: examples[name],
                    goVersion: goVersion
                ))
            }
            itemComments.removeAll()
            i += 1
        }
        return (out, i)
    }

    /// Parses grouped `type (...)` blocks, including nested `interface { ... }` and `struct { ... }` bodies (R-4, R-7).
    private static func parseTypeGroup(
        lines: [String],
        startIndex: Int,
        groupDoc: String,
        importPath: String,
        goVersion: String,
        examples: [String: String]
    ) -> ([DocsChunk], Int) {
        var out: [DocsChunk] = []
        var itemComments: [String] = []
        var i = startIndex + 1

        while i < lines.count {
            let rawLine = lines[i]
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed == ")" {
                return (out, i + 1)
            }
            if trimmed.isEmpty {
                itemComments.removeAll()
                i += 1
                continue
            }
            if trimmed.hasPrefix("//") {
                let body = String(trimmed.dropFirst(2))
                itemComments.append(body.hasPrefix(" ") ? String(body.dropFirst()) : body)
                i += 1
                continue
            }
            if let name = leadingIdentifier(trimmed) {
                let (sig, nextIdx) = parseTypeSpecBody(lines: lines, startIndex: i, prefixTypeKeyword: true)
                if isExported(name) {
                    let doc = !itemComments.isEmpty ? itemComments.joined(separator: "\n") : groupDoc
                    out.append(makeStdlibChunk(
                        importPath: importPath,
                        symbol: name,
                        kind: .type,
                        signature: sig,
                        doc: doc,
                        example: examples[name],
                        goVersion: goVersion
                    ))
                }
                itemComments.removeAll()
                i = nextIdx
                continue
            }
            itemComments.removeAll()
            i += 1
        }
        return (out, i)
    }

    /// Collects a `func` signature across multiple lines until the opening `{` or balanced signature ends (M-14).
    private static func collectFuncSignature(lines: [String], startIndex: Int) -> (String, Int) {
        var parts: [String] = []
        var parenDepth = 0
        var bracketDepth = 0
        var i = startIndex

        while i < lines.count && (i - startIndex) < 20 {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let codeOnly: String
            if let cIdx = findLineCommentStart(in: trimmed) {
                codeOnly = String(trimmed[..<cIdx]).trimmingCharacters(in: .whitespaces)
            } else {
                codeOnly = trimmed
            }

            // Stop at top-level `{` once parens/brackets are balanced.
            var foundBodyOpen = false
            var piece = ""
            var inStr = false
            var inRaw = false
            var inRune = false
            var escaped = false
            for ch in codeOnly {
                if inRaw {
                    if ch == "`" { inRaw = false }
                    piece.append(ch)
                    continue
                }
                if escaped { escaped = false; piece.append(ch); continue }
                if (inStr || inRune) && ch == "\\" { escaped = true; piece.append(ch); continue }
                if !inRune && ch == "\"" { inStr.toggle(); piece.append(ch); continue }
                if !inStr && ch == "'" { inRune.toggle(); piece.append(ch); continue }
                if !inStr && !inRune && ch == "`" { inRaw = true; piece.append(ch); continue }
                if !inStr && !inRune {
                    if ch == "(" { parenDepth += 1 }
                    else if ch == ")" { parenDepth = max(0, parenDepth - 1) }
                    else if ch == "[" { bracketDepth += 1 }
                    else if ch == "]" { bracketDepth = max(0, bracketDepth - 1) }
                    else if ch == "{" && parenDepth == 0 && bracketDepth == 0 {
                        foundBodyOpen = true
                        break
                    }
                }
                piece.append(ch)
            }
            let cleaned = piece.trimmingCharacters(in: .whitespaces)
            if !cleaned.isEmpty { parts.append(cleaned) }
            i += 1
            if foundBodyOpen || (parenDepth == 0 && bracketDepth == 0 && parts.joined(separator: " ").contains("(")) {
                break
            }
        }
        return (parts.joined(separator: " "), i)
    }

    private struct ExportedDecl {
        var symbol: String
        var kind: DocsChunkKind
        var signature: String
    }

    private static func parseExportedFuncSignature(_ sig: String) -> ExportedDecl? {
        guard sig.hasPrefix("func ") else { return nil }
        let afterFunc = String(sig.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        if afterFunc.hasPrefix("("), let closeParen = afterFunc.firstIndex(of: ")") {
            let recv = String(afterFunc[afterFunc.index(after: afterFunc.startIndex)..<closeParen])
            let recvType = extractReceiverTypeName(recv)
            let afterRecv = String(afterFunc[afterFunc.index(after: closeParen)...]).trimmingCharacters(in: .whitespaces)
            guard let methodName = leadingIdentifier(afterRecv), isExported(methodName),
                  let recvType, isExported(recvType) else { return nil }
            return ExportedDecl(symbol: "\(recvType).\(methodName)", kind: .method, signature: sig)
        }
        guard let name = leadingIdentifier(afterFunc), isExported(name) else { return nil }
        return ExportedDecl(symbol: name, kind: .function, signature: sig)
    }

    /// Parses an exported single `type` declaration, preserving full `interface { ... }` method sets without 40-line cap (M-14, R-7).
    private static func parseExportedType(lines: [String], startIndex: Int) -> (ExportedDecl?, Int) {
        let first = lines[startIndex].trimmingCharacters(in: .whitespaces)
        let rest = String(first.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        guard let name = leadingIdentifier(rest), isExported(name) else {
            return (nil, startIndex + 1)
        }
        let (sig, nextIdx) = parseTypeSpecBody(lines: lines, startIndex: startIndex, prefixTypeKeyword: false)
        return (ExportedDecl(symbol: name, kind: .type, signature: sig), nextIdx)
    }

    /// Reads a type specification starting at `startIndex`.
    /// For `interface { ... }`, preserves the complete method set until matching closing brace (R-7).
    /// For `struct { ... }`, advances past the full struct block and emits a concise `{ ... }` signature.
    /// Also tracks multi-line `(...)` / `[...]` (e.g. multi-line `func(...)` types or generic parameter lists)
    /// so `type (...)` groups never terminate prematurely on an inner closing `)` (S-5).
    private static func parseTypeSpecBody(lines: [String], startIndex: Int, prefixTypeKeyword: Bool) -> (String, Int) {
        let first = lines[startIndex].trimmingCharacters(in: .whitespaces)
        let header = prefixTypeKeyword ? "type \(first)" : first

        let isInterface = first.contains("interface {") || first.hasSuffix("interface{")
        var state = BraceScanState()
        let firstDelims = state.scanDelimiters(first)
        var braceDepth = firstDelims.brace
        var parenDepth = firstDelims.paren
        var bracketDepth = firstDelims.bracket

        if isInterface && braceDepth > 0 {
            var blockLines = [header]
            var i = startIndex + 1
            while i < lines.count && (braceDepth > 0 || parenDepth > 0 || bracketDepth > 0) {
                let l = lines[i]
                let d = state.scanDelimiters(l)
                braceDepth += d.brace
                parenDepth += d.paren
                bracketDepth += d.bracket
                blockLines.append(l)
                i += 1
            }
            return (blockLines.joined(separator: "\n"), i)
        }

        if braceDepth > 0 {
            // Struct or other braced type body: skip to matching brace so inner fields aren't misparsed inside `type (...)`.
            var i = startIndex + 1
            while i < lines.count && (braceDepth > 0 || parenDepth > 0 || bracketDepth > 0) {
                let d = state.scanDelimiters(lines[i])
                braceDepth += d.brace
                parenDepth += d.paren
                bracketDepth += d.bracket
                i += 1
            }
            let sig = header.hasSuffix("{")
                ? String(header.dropLast()).trimmingCharacters(in: .whitespaces) + " { ... }"
                : header
            return (sig, i)
        }

        if parenDepth > 0 || bracketDepth > 0 {
            // S-5 & T-4: multi-line `func(...)` type OR multi-line generic parameter list `[ ... ] struct/interface { ... }`.
            var headerParts = [header]
            var i = startIndex + 1
            while i < lines.count && braceDepth == 0 && (parenDepth > 0 || bracketDepth > 0) {
                let l = lines[i]
                let d = state.scanDelimiters(l)
                braceDepth += d.brace
                parenDepth += d.paren
                bracketDepth += d.bracket
                let trimmed = l.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { headerParts.append(trimmed) }
                i += 1
            }
            let joinedHeader = headerParts.joined(separator: " ")
            if braceDepth > 0 {
                let isMultilineInterface = joinedHeader.contains("interface {") || joinedHeader.hasSuffix("interface{")
                if isMultilineInterface {
                    var blockLines = [joinedHeader]
                    while i < lines.count && (braceDepth > 0 || parenDepth > 0 || bracketDepth > 0) {
                        let l = lines[i]
                        let d = state.scanDelimiters(l)
                        braceDepth += d.brace
                        parenDepth += d.paren
                        bracketDepth += d.bracket
                        blockLines.append(l)
                        i += 1
                    }
                    return (blockLines.joined(separator: "\n"), i)
                } else {
                    while i < lines.count && (braceDepth > 0 || parenDepth > 0 || bracketDepth > 0) {
                        let d = state.scanDelimiters(lines[i])
                        braceDepth += d.brace
                        parenDepth += d.paren
                        bracketDepth += d.bracket
                        i += 1
                    }
                    let sig = joinedHeader.hasSuffix("{")
                        ? String(joinedHeader.dropLast()).trimmingCharacters(in: .whitespaces) + " { ... }"
                        : joinedHeader
                    return (sig, i)
                }
            }
            return (joinedHeader, i)
        }

        return (header, startIndex + 1)
    }

    /// Parses `func ExampleFoo()` / `func ExampleType_Method()` blocks and returns `[parentSymbol: code]` (M-12).
    public static func parseExamples(from testSource: String) -> [String: String] {
        let lines = testSource.components(separatedBy: "\n")
        var result: [String: String] = [:]
        var i = 0
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("func Example"),
               let openParen = trimmed.firstIndex(of: "("),
               trimmed.contains("()") {
                let rawName = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 5)..<openParen])
                let target = exampleTargetSymbol(from: rawName)
                var bodyLines: [String] = []
                var state = BraceScanState()
                var depth = state.scanLine(lines[i])
                i += 1
                while i < lines.count && depth > 0 {
                    let current = lines[i]
                    depth += state.scanLine(current)
                    if depth > 0 {
                        bodyLines.append(current)
                    }
                    i += 1
                }
                let cleaned = dedent(bodyLines).trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty, result[target] == nil {
                    result[target] = cleaned
                }
                continue
            }
            i += 1
        }
        return result
    }

    /// Stateful Go brace scanner aware of `"..."`, `` `...` `` (multiline raw strings), `'...'`,
    /// `// ...`, and `/* ... */` comments (M-12).
    private struct BraceScanState {
        var inRawString = false
        var inBlockComment = false

        mutating func scanLine(_ line: String) -> Int {
            scanDelimiters(line).brace
        }

        mutating func scanDelimiters(_ line: String) -> (brace: Int, paren: Int, bracket: Int) {
            var brace = 0
            var paren = 0
            var bracket = 0
            var inString = false
            var inRune = false
            var escaped = false
            let chars = Array(line)
            var idx = 0

            while idx < chars.count {
                let ch = chars[idx]
                let next: Character? = (idx + 1 < chars.count) ? chars[idx + 1] : nil

                if inBlockComment {
                    if ch == "*" && next == "/" {
                        inBlockComment = false
                        idx += 2
                        continue
                    }
                    idx += 1
                    continue
                }
                if inRawString {
                    if ch == "`" { inRawString = false }
                    idx += 1
                    continue
                }
                if escaped {
                    escaped = false
                    idx += 1
                    continue
                }
                if inString {
                    if ch == "\\" { escaped = true }
                    else if ch == "\"" { inString = false }
                    idx += 1
                    continue
                }
                if inRune {
                    if ch == "\\" { escaped = true }
                    else if ch == "'" { inRune = false }
                    idx += 1
                    continue
                }
                if ch == "/" && next == "/" {
                    break // rest of line is comment
                }
                if ch == "/" && next == "*" {
                    inBlockComment = true
                    idx += 2
                    continue
                }
                if ch == "\"" { inString = true; idx += 1; continue }
                if ch == "'" { inRune = true; idx += 1; continue }
                if ch == "`" { inRawString = true; idx += 1; continue }
                if ch == "{" { brace += 1 }
                else if ch == "}" { brace -= 1 }
                else if ch == "(" { paren += 1 }
                else if ch == ")" { paren -= 1 }
                else if ch == "[" { bracket += 1 }
                else if ch == "]" { bracket -= 1 }
                idx += 1
            }
            return (brace, paren, bracket)
        }
    }

    private static func braceDelta(_ line: String) -> Int {
        var s = BraceScanState()
        return s.scanLine(line)
    }

    private static func findLineCommentStart(in line: String) -> String.Index? {
        var inStr = false
        var inRaw = false
        var inRune = false
        var escaped = false
        var idx = line.startIndex
        while idx < line.endIndex {
            let ch = line[idx]
            let nextIdx = line.index(after: idx)
            if inRaw {
                if ch == "`" { inRaw = false }
                idx = nextIdx
                continue
            }
            if escaped { escaped = false; idx = nextIdx; continue }
            if (inStr || inRune) && ch == "\\" { escaped = true; idx = nextIdx; continue }
            if !inRune && ch == "\"" { inStr.toggle(); idx = nextIdx; continue }
            if !inStr && ch == "'" { inRune.toggle(); idx = nextIdx; continue }
            if !inStr && !inRune && ch == "`" { inRaw = true; idx = nextIdx; continue }
            if !inStr && !inRune && ch == "/" && nextIdx < line.endIndex && line[nextIdx] == "/" {
                return idx
            }
            idx = nextIdx
        }
        return nil
    }

    private static func exampleTargetSymbol(from funcName: String) -> String {
        guard funcName.hasPrefix("Example") else { return "" }
        let suffix = String(funcName.dropFirst("Example".count))
        if suffix.isEmpty || suffix.hasPrefix("_") { return "" }
        let parts = suffix.split(separator: "_", omittingEmptySubsequences: false).map(String.init)
        if parts.count >= 2, let second = parts[1].first, second.isUppercase {
            return "\(parts[0]).\(parts[1])"
        }
        return parts[0]
    }

    private static func extractReceiverTypeName(_ receiver: String) -> String? {
        let tokens = receiver.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let last = tokens.last else { return nil }
        var typePart = String(last)
        while typePart.hasPrefix("*") { typePart.removeFirst() }
        if let bracket = typePart.firstIndex(of: "[") {
            typePart = String(typePart[..<bracket])
        }
        return leadingIdentifier(typePart)
    }

    private static func leadingIdentifier(_ s: String) -> String? {
        var out = ""
        for ch in s {
            if ch.isLetter || ch.isNumber || ch == "_" {
                out.append(ch)
            } else {
                break
            }
        }
        return out.isEmpty ? nil : out
    }

    /// Parses comma-separated identifiers on the LHS of a const/var spec (`A, B = 1, 2` -> `["A", "B"]`, R-7).
    private static func leadingIdentifierList(_ spec: String) -> [String] {
        var names: [String] = []
        var rest = Substring(spec).drop(while: { $0.isWhitespace })
        while let ident = leadingIdentifier(String(rest)) {
            names.append(ident)
            rest = rest.dropFirst(ident.count).drop(while: { $0.isWhitespace })
            guard rest.first == "," else { break }
            rest = rest.dropFirst().drop(while: { $0.isWhitespace })
        }
        return names
    }

    private static func isExported(_ name: String) -> Bool {
        guard let first = name.first else { return false }
        return first.isUppercase
    }

    private static func dedent(_ lines: [String]) -> String {
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !nonEmpty.isEmpty else { return "" }
        let minTabs = nonEmpty.map { $0.prefix(while: { $0 == "\t" }).count }.min() ?? 0
        return lines.map { line in
            if line.count >= minTabs && line.prefix(minTabs).allSatisfy({ $0 == "\t" }) {
                return String(line.dropFirst(minTabs))
            }
            return line
        }.joined(separator: "\n")
    }

    private static func relativePackagePath(dir: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let dirPath = dir.standardizedFileURL.path
        guard dirPath.hasPrefix(rootPath + "/") else { return "" }
        return String(dirPath.dropFirst(rootPath.count + 1))
    }

    private static func parseMarkdownHeading(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }
        let hashes = trimmed.prefix(while: { $0 == "#" })
        guard hashes.count >= 1 && hashes.count <= 6 else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.hasPrefix(" ") else { return nil }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    private static func slugifyAnchor(_ heading: String) -> String {
        heading
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
    }

    private static func extractFirstGoFence(from body: String) -> String? {
        let lines = body.components(separatedBy: "\n")
        var collecting = false
        var snippet: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !collecting {
                if trimmed == "```go" || trimmed == "```" {
                    collecting = true
                }
            } else {
                if trimmed.hasPrefix("```") {
                    let text = snippet.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    return text.isEmpty ? nil : text
                }
                snippet.append(line)
            }
        }
        return nil
    }

    private static func stripCodeFences(_ body: String) -> String {
        body.replacingOccurrences(of: #"```[\s\S]*?```"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstLine(of text: String) -> String {
        text.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? text
    }

    private static func firstSentence(of text: String) -> String {
        let compact = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if let dot = compact.range(of: ". ") {
            return String(compact[..<dot.upperBound]).trimmingCharacters(in: .whitespaces)
        }
        if compact.count > 220 {
            return String(compact.prefix(220)) + "…"
        }
        return compact
    }

    private static func deduplicateByStableID(_ chunks: [DocsChunk]) -> [DocsChunk] {
        var seen = Set<String>()
        var out: [DocsChunk] = []
        for c in chunks where seen.insert(c.stableID).inserted {
            out.append(c)
        }
        return out
    }
}
