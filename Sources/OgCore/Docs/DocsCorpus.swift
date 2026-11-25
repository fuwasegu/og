import Foundation

/// Extracts structured `DocsChunk` items from authoritative Go sources without HTML scraping (FR-4, FR-7):
/// 1. Local GOROOT `src/` `.go` files (GoDoc comments + exported symbols + `Example*` tests)
/// 2. `golang/website` Markdown guides (stripping Hugo front matter and shortcodes)
/// 3. Language specification / release notes sections (Markdown or heading-structured docs)
public enum DocsCorpusExtractor {
    /// Extracts standard library chunks from a local `GOROOT/src` directory (FR-4-1, FR-7).
    /// Skips `internal/`, `vendor/`, `testdata/`, `cmd/` and non-example `_test.go` files.
    public static func extractStdlib(fromGorootSrc srcRoot: URL, goVersion: String) -> [DocsChunk] {
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
                if name == "internal" || name == "vendor" || name == "testdata" || name == "cmd" || name == "builtin" {
                    enumerator.skipDescendants()
                    continue
                }
                packageDirs.append(url)
            }
        }

        var chunks: [DocsChunk] = []
        for dir in packageDirs.sorted(by: { $0.path < $1.path }) {
            let relPath = relativePackagePath(dir: dir, root: srcRoot)
            guard !relPath.isEmpty else { continue }
            chunks.append(contentsOf: extractStdlibPackage(directory: dir, importPath: relPath, goVersion: goVersion))
        }
        return chunks
    }

    /// Extracts exported symbols and attaches `Example*` functions from one Go package directory (FR-7).
    public static func extractStdlibPackage(directory: URL, importPath: String, goVersion: String) -> [DocsChunk] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        let goFiles = entries.filter { $0.pathExtension == "go" }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        // First collect examples from `*_test.go` files keyed by parent symbol name.
        var examplesBySymbol: [String: String] = [:]
        for file in goFiles where file.lastPathComponent.hasSuffix("_test.go") {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (targetSymbol, snippet) in parseExamples(from: text) {
                if examplesBySymbol[targetSymbol] == nil {
                    examplesBySymbol[targetSymbol] = snippet
                }
            }
        }

        var chunks: [DocsChunk] = []
        var packageDoc: String?

        for file in goFiles where !file.lastPathComponent.hasSuffix("_test.go") {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
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
    /// removing Hugo front matter (`--- ... ---`) and shortcodes (`{{< ... >}}`, `{{% ... %}}`) (FR-4-3, FR-7).
    public static func extractGuideMarkdown(
        text: String,
        documentTitle: String,
        source: DocsSourceKind = .guide,
        goVersion: String
    ) -> [DocsChunk] {
        let cleaned = stripHugoFrontMatterAndShortcodes(text)
        let lines = cleaned.components(separatedBy: "\n")

        var chunks: [DocsChunk] = []
        var currentHeading = documentTitle
        var currentLines: [String] = []

        func flush() {
            let body = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return }
            let anchor = "#" + slugifyAnchor(currentHeading)
            let example = extractFirstGoFence(from: body)
            let summary = firstSentence(of: stripCodeFences(body))
            let chunk = DocsChunk(
                goVersion: goVersion,
                source: source,
                packageName: "",
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
            if let heading = parseMarkdownHeading(line) {
                flush()
                currentHeading = heading
                currentLines = []
            } else {
                currentLines.append(line)
            }
        }
        flush()
        return deduplicateByStableID(chunks)
    }

    /// Removes Hugo YAML/TOML front matter and `{{< ... >}}` / `{{% ... %}}` shortcodes (FR-4-3).
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
        // Strip paired Hugo shortcodes first: {{< name ... >}}...{{< /name >}} and {{% name ... %}}...{{% /name %}}
        text = text.replacingOccurrences(
            of: #"\{\{<\s*([a-zA-Z0-9_-]+)[^>]*>\}\}[\s\S]*?\{\{<\s*/\1\s*>\}\}"#,
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"\{\{%\s*([a-zA-Z0-9_-]+)[^%]*%\}\}[\s\S]*?\{\{%\s*/\1\s*%\}\}"#,
            with: "",
            options: .regularExpression
        )
        // Strip remaining standalone Hugo shortcodes: {{< ... >}} and {{% ... %}}
        text = text.replacingOccurrences(of: #"\{\{[<%][\s\S]*?[%>]\}\}"#, with: "", options: .regularExpression)
        // Strip Hugo heading ID attributes like `{#for_statements}`
        text = text.replacingOccurrences(of: #"\s*\{#[^}]+\}"#, with: "", options: .regularExpression)
        return text
    }

    // MARK: - Go Source Parsing (stdlib GoDoc & Examples)

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

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inBlockComment {
                if let end = trimmed.range(of: "*/") {
                    let piece = String(trimmed[..<end.lowerBound]).trimmingCharacters(in: .whitespaces)
                    if !piece.isEmpty { pendingComments.append(piece) }
                    inBlockComment = false
                } else {
                    pendingComments.append(trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "* ")))
                }
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
                continue
            }
            if trimmed.hasPrefix("//") {
                let body = String(trimmed.dropFirst(2))
                // Ignore build tags and directives
                if body.hasPrefix("go:") || body.hasPrefix("+build") { continue }
                pendingComments.append(body.hasPrefix(" ") ? String(body.dropFirst()) : body)
                continue
            }
            if trimmed.isEmpty {
                pendingComments.removeAll()
                continue
            }
            if trimmed.hasPrefix("package ") {
                if !pendingComments.isEmpty && packageDoc == nil {
                    packageDoc = pendingComments.joined(separator: "\n")
                }
                pendingComments.removeAll()
                continue
            }

            // Exported top-level declarations only (no leading whitespace).
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                if let decl = parseExportedDeclaration(line: trimmed) {
                    let doc = pendingComments.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    let example = examples[decl.symbol] ?? examples[decl.baseTypeName ?? ""]
                    let summary = doc.isEmpty ? decl.signature : firstSentence(of: doc)
                    let chunk = DocsChunk(
                        goVersion: goVersion,
                        source: .stdlib,
                        packageName: importPath,
                        symbol: decl.symbol,
                        kind: decl.kind,
                        title: "\(importPath).\(decl.symbol)",
                        anchor: "\(importPath).\(decl.symbol)",
                        since: nil,
                        summary: summary,
                        signature: decl.signature,
                        example: example,
                        body: doc.isEmpty ? decl.signature : "\(decl.signature)\n\n\(doc)"
                    )
                    chunks.append(chunk)
                }
            }
            pendingComments.removeAll()
        }
        return ParsedFile(packageDoc: packageDoc, chunks: chunks)
    }

    private struct ExportedDecl {
        var symbol: String
        var baseTypeName: String?
        var kind: DocsChunkKind
        var signature: String
    }

    private static func parseExportedDeclaration(line: String) -> ExportedDecl? {
        if line.hasPrefix("func ") {
            let sig = line.hasSuffix("{") ? String(line.dropLast()).trimmingCharacters(in: .whitespaces) : line
            let afterFunc = String(sig.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            // Method: `func (r *Type) Method(...) ...`
            if afterFunc.hasPrefix("("), let closeParen = afterFunc.firstIndex(of: ")") {
                let recv = String(afterFunc[afterFunc.index(after: afterFunc.startIndex)..<closeParen])
                let recvType = extractReceiverTypeName(recv)
                let afterRecv = String(afterFunc[afterFunc.index(after: closeParen)...]).trimmingCharacters(in: .whitespaces)
                guard let methodName = leadingIdentifier(afterRecv), isExported(methodName),
                      let recvType, isExported(recvType) else { return nil }
                return ExportedDecl(symbol: "\(recvType).\(methodName)", baseTypeName: recvType, kind: .method, signature: sig)
            }
            // Function: `func Name(...) ...`
            guard let name = leadingIdentifier(afterFunc), isExported(name) else { return nil }
            return ExportedDecl(symbol: name, baseTypeName: nil, kind: .function, signature: sig)
        }
        if line.hasPrefix("type ") {
            let rest = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard let name = leadingIdentifier(rest), isExported(name) else { return nil }
            let sig = line.hasSuffix("{") ? String(line.dropLast()).trimmingCharacters(in: .whitespaces) + " { ... }" : line
            return ExportedDecl(symbol: name, baseTypeName: name, kind: .type, signature: sig)
        }
        return nil
    }

    /// Parses `func ExampleFoo()` / `func ExampleType_Method()` blocks and returns `[parentSymbol: code]`.
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
                var depth = braceDelta(lines[i])
                i += 1
                while i < lines.count && depth > 0 {
                    let current = lines[i]
                    depth += braceDelta(current)
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

    private static func isExported(_ name: String) -> Bool {
        guard let first = name.first else { return false }
        return first.isUppercase
    }

    private static func braceDelta(_ line: String) -> Int {
        var delta = 0
        var inString = false
        var escaped = false
        for ch in line {
            if escaped { escaped = false; continue }
            if ch == "\\" && inString { escaped = true; continue }
            if ch == "\"" { inString.toggle(); continue }
            if inString { continue }
            if ch == "{" { delta += 1 }
            if ch == "}" { delta -= 1 }
        }
        return delta
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
        guard hashes.count >= 1 && hashes.count <= 4 else { return nil }
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
