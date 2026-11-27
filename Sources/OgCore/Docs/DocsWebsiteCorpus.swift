import Foundation

/// Options controlling extraction of a local `golang/website` checkout (Issue #26, DOC-14a, DES-WEB-2).
public struct DocsWebsiteExtractionOptions: Sendable, Hashable {
    /// ISO-8601 snapshot date (`YYYY-MM-DD`). When `nil`, detected from git commit date or current UTC date.
    public var snapshotDate: String?
    /// Optional git commit hash/tag. When `nil`, detected via `git rev-parse --short HEAD` when `.git` is present.
    public var snapshotCommit: String?
    public var includeEffectiveGo: Bool
    public var includeTour: Bool
    public var includeFAQ: Bool
    public var includeGuides: Bool
    public var includeBlog: Bool

    public init(
        snapshotDate: String? = nil,
        snapshotCommit: String? = nil,
        includeEffectiveGo: Bool = true,
        includeTour: Bool = true,
        includeFAQ: Bool = true,
        includeGuides: Bool = true,
        includeBlog: Bool = true
    ) {
        self.snapshotDate = snapshotDate
        self.snapshotCommit = snapshotCommit
        self.includeEffectiveGo = includeEffectiveGo
        self.includeTour = includeTour
        self.includeFAQ = includeFAQ
        self.includeGuides = includeGuides
        self.includeBlog = includeBlog
    }

    public static let `default` = DocsWebsiteExtractionOptions()
}

/// Record of an excluded file during `golang/website` extraction and why it was skipped (Issue #26).
public struct DocsWebsiteExcludedFile: Sendable, Hashable {
    public var relativePath: String
    public var reason: String

    public init(relativePath: String, reason: String) {
        self.relativePath = relativePath
        self.reason = reason
    }
}

/// Result of extracting a local `golang/website` snapshot checkout (Issue #26, DES-WEB-2).
public struct DocsWebsiteExtractionResult: Sendable, Hashable {
    public var chunks: [DocsChunk]
    /// Git-derived or explicitly supplied snapshot date (`YYYY-MM-DD`); `nil` when unavailable (never fabricated from import execution date, C-1).
    public var snapshotDate: String?
    public var snapshotCommit: String?
    public var includedFiles: [String]
    public var excludedFiles: [DocsWebsiteExcludedFile]
    public var categoryCounts: [String: Int]

    public init(
        chunks: [DocsChunk],
        snapshotDate: String? = nil,
        snapshotCommit: String? = nil,
        includedFiles: [String] = [],
        excludedFiles: [DocsWebsiteExcludedFile] = [],
        categoryCounts: [String: Int] = [:]
    ) {
        self.chunks = chunks
        self.snapshotDate = snapshotDate
        self.snapshotCommit = snapshotCommit
        self.includedFiles = includedFiles
        self.excludedFiles = excludedFiles
        self.categoryCounts = categoryCounts
    }
}

/// Extracts heading-scoped, provenance-stamped `DocsChunk` items from a local `golang/website`
/// checkout without network access (Issue #26, DOC-14a, DES-WEB-2).
///
/// Supported formats in `golang/website/_content/`:
/// 1. Effective Go (`_content/doc/effective_go.html`) — HTML with JSON comment front matter and `<h2/h3 id="...">` headings
/// 2. Tour of Go (`_content/tour/*.article`) — Go `present` format with `.play` / `.code` `.go` snippet resolution
/// 3. FAQ (`_content/doc/faq.md`) — Markdown with YAML front matter and `{#Anchor}` IDs
/// 4. Official Tutorials, Guides, Database, Modules, Ref/Mod, Wiki (`_content/doc/tutorial/`, `_content/doc/database/`,
///    `_content/doc/modules/`, `_content/doc/articles/`, `_content/doc/*.{md,html}`, `_content/ref/mod.md`, `_content/wiki/*.md`)
/// 5. Official Go Blog (`_content/blog/*.md`) — technical articles only (excluding surveys, event reports, and release announcements),
///    resolving `{{code ...}}` / `{{play ...}}` directives from sibling directories when available.
///
/// All chunks carry:
/// - `goVersion = "website"` (version-independent snapshot pack)
/// - `source = .guide`, `provenance = .officialWebsiteSnapshot`, `since = nil` (excluded from `since` gating)
/// - `documentID = "website/<relPathWithoutExt>"` (guaranteed non-colliding with FR-31 stdlib/dependency/bundled IDs)
/// - `sourceURL = "https://go.dev/..."` and `snapshotDate = "<YYYY-MM-DD>"`
public enum DocsWebsiteCorpusExtractor {
    public static let canonicalBaseURL = "https://go.dev"
    public static let websiteVersionTag = "website"

    /// Tour chapters in canonical Tour of Go order.
    private static let tourChapters: [(file: String, chapterSlug: String, displayName: String)] = [
        ("welcome.article", "welcome", "A Tour of Go (Welcome)"),
        ("basics.article", "basics", "A Tour of Go (Basics)"),
        ("flowcontrol.article", "flowcontrol", "A Tour of Go (Flow Control)"),
        ("moretypes.article", "moretypes", "A Tour of Go (More Types)"),
        ("methods.article", "methods", "A Tour of Go (Methods and Interfaces)"),
        ("generics.article", "generics", "A Tour of Go (Generics)"),
        ("concurrency.article", "concurrency", "A Tour of Go (Concurrency)")
    ]

    /// Standalone top-level `_content/doc/` files that are high-value Go programming references.
    private static let includedTopLevelDocFiles: Set<String> = [
        "comment.md",
        "fuzz.md",
        "pgo.md",
        "toolchain.md",
        "build-cover.md",
        "jsonv2-migration.md",
        "code.html",
        "diagnostics.html",
        "gc-guide.html",
        "go1compat.html"
    ]

    /// Blog filename prefixes/patterns excluded because they are non-technical surveys, events, or announcements.
    private static let excludedBlogPrefixes: [String] = [
        "survey",
        "gophercon",
        "gopherchina",
        "gothamgo",
        "gouk",
        "contributor",
        "oscon",
        "io20",
        "gophergala",
        "brand",
        "go-brand",
        "store",
        "turkey-doodle",
        "qihoo",
        "stackoverflow",
        "stathat",
        "ismmkeynote",
        "toward-go2"
    ]

    /// Extracts all curated content from a local `golang/website` checkout (either repo root or `_content/` dir).
    public static func extractWebsite(
        fromWebsiteRoot root: URL,
        options: DocsWebsiteExtractionOptions = .default
    ) -> DocsWebsiteExtractionResult {
        let fm = FileManager.default
        let contentRoot: URL
        let repoRoot: URL
        let candidateContent = root.appendingPathComponent("_content", isDirectory: true)
        if fm.fileExists(atPath: candidateContent.path) {
            contentRoot = candidateContent
            repoRoot = root
        } else {
            contentRoot = root
            repoRoot = root.deletingLastPathComponent()
        }

        let detectedGit = detectGitSnapshotMetadata(in: repoRoot)
        // C-1: Only record a snapshot date when explicitly supplied or derived from git commit metadata;
        // never fabricate today's import date as the content's snapshot date.
        let snapshotDate = options.snapshotDate ?? detectedGit.date
        let snapshotCommit = options.snapshotCommit ?? detectedGit.commit

        var chunks: [DocsChunk] = []
        var includedFiles: [String] = []
        var excludedFiles: [DocsWebsiteExcludedFile] = []
        var categoryCounts: [String: Int] = [:]

        // 1. Effective Go (_content/doc/effective_go.html)
        if options.includeEffectiveGo {
            let effURL = contentRoot.appendingPathComponent("doc/effective_go.html")
            if let raw = try? String(contentsOf: effURL, encoding: .utf8) {
                let extracted = extractHTMLDocument(
                    html: raw,
                    fallbackTitle: "Effective Go",
                    documentID: "website/doc/effective_go",
                    canonicalPageURL: "\(canonicalBaseURL)/doc/effective_go",
                    snapshotDate: snapshotDate
                )
                chunks.append(contentsOf: extracted)
                includedFiles.append("doc/effective_go.html")
                categoryCounts["effective_go", default: 0] += extracted.count
            }
        }

        // 2. Tour of Go (_content/tour/*.article + .go snippets)
        if options.includeTour {
            let tourDir = contentRoot.appendingPathComponent("tour", isDirectory: true)
            for chapter in tourChapters {
                let articleURL = tourDir.appendingPathComponent(chapter.file)
                guard let raw = try? String(contentsOf: articleURL, encoding: .utf8) else { continue }
                let extracted = extractTourArticle(
                    text: raw,
                    chapterSlug: chapter.chapterSlug,
                    fallbackTitle: chapter.displayName,
                    tourDirectory: tourDir,
                    snapshotDate: snapshotDate
                )
                chunks.append(contentsOf: extracted)
                includedFiles.append("tour/\(chapter.file)")
                categoryCounts["tour", default: 0] += extracted.count
            }
        }

        // 3. FAQ (_content/doc/faq.md)
        if options.includeFAQ {
            let faqURL = contentRoot.appendingPathComponent("doc/faq.md")
            if let raw = try? String(contentsOf: faqURL, encoding: .utf8) {
                let extracted = extractWebsiteMarkdown(
                    text: raw,
                    fallbackTitle: "Frequently Asked Questions (FAQ)",
                    documentID: "website/doc/faq",
                    canonicalPageURL: "\(canonicalBaseURL)/doc/faq",
                    baseDirectory: faqURL.deletingLastPathComponent(),
                    snapshotDate: snapshotDate
                )
                chunks.append(contentsOf: extracted)
                includedFiles.append("doc/faq.md")
                categoryCounts["faq", default: 0] += extracted.count
            }
        }

        // 4. Official Guides, Tutorials, Database, Modules, Ref/Mod, Wiki
        if options.includeGuides {
            let docDir = contentRoot.appendingPathComponent("doc", isDirectory: true)
            if let docEntries = try? fm.contentsOfDirectory(at: docDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                for entry in docEntries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    let name = entry.lastPathComponent
                    let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    if isDir { continue }
                    if name == "effective_go.html" || name == "faq.md" { continue }
                    let rel = "doc/\(name)"
                    if name == "go_faq.md" {
                        excludedFiles.append(DocsWebsiteExcludedFile(relativePath: rel, reason: "duplicate/redirect of doc/faq.md"))
                        continue
                    }
                    if isReleaseNoteFilename(name) {
                        excludedFiles.append(DocsWebsiteExcludedFile(relativePath: rel, reason: "version-specific release notes; handled by versioned Go packs"))
                        continue
                    }
                    guard includedTopLevelDocFiles.contains(name) else {
                        if name.hasSuffix(".md") || name.hasSuffix(".html") {
                            excludedFiles.append(DocsWebsiteExcludedFile(relativePath: rel, reason: "installation/governance/meta documentation"))
                        }
                        continue
                    }
                    let extracted = extractSingleWebsiteFile(
                        fileURL: entry,
                        relativePath: rel,
                        webPath: webPathForDocFile(rel),
                        snapshotDate: snapshotDate
                    )
                    if !extracted.isEmpty {
                        chunks.append(contentsOf: extracted)
                        includedFiles.append(rel)
                        categoryCounts["guides", default: 0] += extracted.count
                    }
                }
            }

            // Curated subdirectories under _content/doc/
            let guideSubdirs = ["doc/tutorial", "doc/database", "doc/modules", "doc/articles"]
            for sub in guideSubdirs {
                let dir = contentRoot.appendingPathComponent(sub, isDirectory: true)
                guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
                for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    if isDir { continue }
                    let name = entry.lastPathComponent
                    let rel = "\(sub)/\(name)"
                    guard name.hasSuffix(".md") || name.hasSuffix(".html") else { continue }
                    if name == "index.html" || name == "index.md" {
                        excludedFiles.append(DocsWebsiteExcludedFile(relativePath: rel, reason: "directory index page"))
                        continue
                    }
                    let extracted = extractSingleWebsiteFile(
                        fileURL: entry,
                        relativePath: rel,
                        webPath: webPathForDocFile(rel),
                        snapshotDate: snapshotDate
                    )
                    if !extracted.isEmpty {
                        chunks.append(contentsOf: extracted)
                        includedFiles.append(rel)
                        categoryCounts["guides", default: 0] += extracted.count
                    }
                }
            }

            // _content/ref/mod.md
            let refModURL = contentRoot.appendingPathComponent("ref/mod.md")
            if fm.fileExists(atPath: refModURL.path) {
                let extracted = extractSingleWebsiteFile(
                    fileURL: refModURL,
                    relativePath: "ref/mod.md",
                    webPath: "/ref/mod",
                    snapshotDate: snapshotDate
                )
                if !extracted.isEmpty {
                    chunks.append(contentsOf: extracted)
                    includedFiles.append("ref/mod.md")
                    categoryCounts["guides", default: 0] += extracted.count
                }
            }

            // _content/wiki/*.md (excluding index.md)
            let wikiDir = contentRoot.appendingPathComponent("wiki", isDirectory: true)
            if let wikiEntries = try? fm.contentsOfDirectory(at: wikiDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for entry in wikiEntries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    let name = entry.lastPathComponent
                    guard name.hasSuffix(".md") else { continue }
                    let rel = "wiki/\(name)"
                    if name == "index.md" {
                        excludedFiles.append(DocsWebsiteExcludedFile(relativePath: rel, reason: "directory index page"))
                        continue
                    }
                    let extracted = extractSingleWebsiteFile(
                        fileURL: entry,
                        relativePath: rel,
                        webPath: webPathForDocFile(rel),
                        snapshotDate: snapshotDate
                    )
                    if !extracted.isEmpty {
                        chunks.append(contentsOf: extracted)
                        includedFiles.append(rel)
                        categoryCounts["wiki", default: 0] += extracted.count
                    }
                }
            }
        }

        // 5. Official Go Blog (_content/blog/*.md, technical posts only)
        if options.includeBlog {
            let blogDir = contentRoot.appendingPathComponent("blog", isDirectory: true)
            if let blogEntries = try? fm.contentsOfDirectory(at: blogDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                for entry in blogEntries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    if isDir { continue }
                    let name = entry.lastPathComponent
                    guard name.hasSuffix(".md") else { continue }
                    let slug = String(name.dropLast(3))
                    let rel = "blog/\(name)"
                    if let skipReason = blogExclusionReason(slug: slug) {
                        excludedFiles.append(DocsWebsiteExcludedFile(relativePath: rel, reason: skipReason))
                        continue
                    }
                    guard let raw = try? String(contentsOf: entry, encoding: .utf8) else { continue }
                    let extracted = extractWebsiteMarkdown(
                        text: raw,
                        fallbackTitle: slug.replacingOccurrences(of: "-", with: " ").capitalized,
                        documentID: "website/blog/\(slug)",
                        canonicalPageURL: "\(canonicalBaseURL)/blog/\(slug)",
                        baseDirectory: blogDir,
                        snapshotDate: snapshotDate
                    )
                    if !extracted.isEmpty {
                        chunks.append(contentsOf: extracted)
                        includedFiles.append(rel)
                        categoryCounts["blog", default: 0] += extracted.count
                    }
                }
            }
        }

        // Deduplicate by stableID preserving first occurrence.
        var seen = Set<String>()
        var deduped: [DocsChunk] = []
        deduped.reserveCapacity(chunks.count)
        for chunk in chunks {
            if seen.insert(chunk.stableID).inserted {
                deduped.append(chunk)
            }
        }

        return DocsWebsiteExtractionResult(
            chunks: deduped,
            snapshotDate: snapshotDate,
            snapshotCommit: snapshotCommit,
            includedFiles: includedFiles,
            excludedFiles: excludedFiles,
            categoryCounts: categoryCounts
        )
    }

    // MARK: - Format-Specific Extractors

    /// Extracts heading-scoped chunks from a `golang/website` Markdown document (YAML/TOML front matter,
    /// `{#Anchor}` explicit IDs, `{{code ...}}` / `{{play ...}}` directive resolution, and Go code blocks).
    public static func extractWebsiteMarkdown(
        text: String,
        fallbackTitle: String,
        documentID: String,
        canonicalPageURL: String,
        baseDirectory: URL? = nil,
        snapshotDate: String?
    ) -> [DocsChunk] {
        let parsedFM = parseMarkdownFrontMatter(text)
        let docTitle = parsedFM.title ?? fallbackTitle
        let expandedCode = resolveBlogCodeDirectives(in: parsedFM.body, baseDirectory: baseDirectory)
        // Strip Hugo template comments & shortcodes while keeping `{#Anchor}` intact until heading parse
        // so duplicate heading titles with distinct `{#id}` anchors never collide.
        let cleaned = stripHugoCommentsAndShortcodesPreservingHeadingAnchors(expandedCode)
        let lines = cleaned.components(separatedBy: "\n")

        var chunks: [DocsChunk] = []
        var anchorCounts: [String: Int] = [:]
        var currentHeading = docTitle
        var currentExplicitAnchor: String?
        var currentLines: [String] = []
        var inFence = false
        var fenceMarker = ""

        func flush() {
            let body = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return }
            let baseSlug = currentExplicitAnchor ?? slugifyAnchor(currentHeading)
            let count = (anchorCounts[baseSlug] ?? 0) + 1
            anchorCounts[baseSlug] = count
            let fragment = count == 1 ? baseSlug : "\(baseSlug)-\(count)"
            let anchor = "#\(fragment)"
            let fullURL = currentHeading == docTitle && currentExplicitAnchor == nil
                ? canonicalPageURL
                : "\(canonicalPageURL)\(anchor)"
            let example = extractFirstGoFence(from: body)
            let summarySource = stripCodeFences(body)
            let summary = firstSentence(of: summarySource)
            let sectionTitle = currentHeading == docTitle ? docTitle : "\(docTitle): \(currentHeading)"

            let chunk = DocsChunk(
                goVersion: websiteVersionTag,
                source: .guide,
                provenance: .officialWebsiteSnapshot,
                packageName: "",
                documentID: documentID,
                symbol: currentHeading,
                kind: .section,
                title: sectionTitle,
                anchor: anchor,
                since: nil,
                summary: summary.isEmpty ? sectionTitle : summary,
                signature: nil,
                example: example,
                body: body,
                searchAliases: parsedFM.tags,
                sourceURL: fullURL,
                snapshotDate: snapshotDate
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
            if let (heading, explicitID) = parseMarkdownHeadingWithAnchor(line) {
                flush()
                currentHeading = heading
                currentExplicitAnchor = explicitID
                currentLines = []
            } else {
                currentLines.append(line)
            }
        }
        flush()
        return chunks
    }

    private static func stripHugoCommentsAndShortcodesPreservingHeadingAnchors(_ raw: String) -> String {
        var text = raw
        text = text.replacingOccurrences(of: #"\{\{/\*[\s\S]*?\*/\}\}"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\{\{[<%][\s\S]*?[%>]\}\}"#, with: "", options: .regularExpression)
        return text
    }

    /// Extracts heading-scoped chunks from `golang/website` HTML documents (e.g. `effective_go.html`,
    /// `code.html`, `diagnostics.html`, `gc-guide.html`, `tutorial/*.html`).
    public static func extractHTMLDocument(
        html: String,
        fallbackTitle: String,
        documentID: String,
        canonicalPageURL: String,
        snapshotDate: String?
    ) -> [DocsChunk] {
        let parsed = parseHTMLJSONFrontMatter(html)
        let docTitle = parsed.title ?? fallbackTitle
        let content = parsed.body

        // Find all <h2 ...>...</h2> and <h3 ...>...</h3> tags.
        let headingPattern = #"<h([23])(?:\s+[^>]*?id="([^"]+)")?[^>]*>([\s\S]*?)</h\1>"#
        guard let regex = try? NSRegularExpression(pattern: headingPattern, options: [.caseInsensitive]) else {
            return []
        }
        let ns = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else {
            let plain = stripHTMLToPlainText(content)
            guard !plain.isEmpty else { return [] }
            let example = extractFirstHTMLPreCode(from: content)
            return [DocsChunk(
                goVersion: websiteVersionTag,
                source: .guide,
                provenance: .officialWebsiteSnapshot,
                packageName: "",
                documentID: documentID,
                symbol: docTitle,
                kind: .section,
                title: docTitle,
                anchor: "#top",
                since: nil,
                summary: firstSentence(of: plain),
                signature: nil,
                example: example,
                body: plain,
                sourceURL: canonicalPageURL,
                snapshotDate: snapshotDate
            )]
        }

        var chunks: [DocsChunk] = []
        var anchorCounts: [String: Int] = [:]

        for (idx, match) in matches.enumerated() {
            let idRange = match.range(at: 2)
            let explicitID: String? = idRange.location != NSNotFound ? ns.substring(with: idRange) : nil
            let rawHeading = ns.substring(with: match.range(at: 3))
            let heading = stripHTMLToPlainText(rawHeading).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !heading.isEmpty else { continue }

            let bodyStart = match.range.location + match.range.length
            let bodyEnd = (idx + 1 < matches.count) ? matches[idx + 1].range.location : ns.length
            guard bodyEnd > bodyStart else { continue }
            let sectionHTML = ns.substring(with: NSRange(location: bodyStart, length: bodyEnd - bodyStart))

            let example = extractFirstHTMLPreCode(from: sectionHTML)
            let bodyText = stripHTMLToPlainText(sectionHTML)
            guard !bodyText.isEmpty else { continue }

            let baseSlug = explicitID ?? slugifyAnchor(heading)
            let count = (anchorCounts[baseSlug] ?? 0) + 1
            anchorCounts[baseSlug] = count
            let fragment = count == 1 ? baseSlug : "\(baseSlug)-\(count)"
            let anchor = "#\(fragment)"
            let summary = firstSentence(of: bodyText)
            let sectionTitle = "\(docTitle): \(heading)"

            chunks.append(DocsChunk(
                goVersion: websiteVersionTag,
                source: .guide,
                provenance: .officialWebsiteSnapshot,
                packageName: "",
                documentID: documentID,
                symbol: heading,
                kind: .section,
                title: sectionTitle,
                anchor: anchor,
                since: nil,
                summary: summary.isEmpty ? sectionTitle : summary,
                signature: nil,
                example: example,
                body: bodyText,
                sourceURL: "\(canonicalPageURL)\(anchor)",
                snapshotDate: snapshotDate
            ))
        }
        return chunks
    }

    /// Extracts slide-scoped chunks from a Tour of Go `.article` file (`present` format), resolving
    /// `.play` / `.code` directives to sibling `.go` files as `example` snippets.
    public static func extractTourArticle(
        text: String,
        chapterSlug: String,
        fallbackTitle: String,
        tourDirectory: URL,
        snapshotDate: String?
    ) -> [DocsChunk] {
        let lines = text.components(separatedBy: "\n")
        let chapterTitle = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = (chapterTitle?.isEmpty == false) ? "A Tour of Go: \(chapterTitle!)" : fallbackTitle

        var chunks: [DocsChunk] = []
        var slideIndex = 0
        var currentHeading: String?
        var proseLines: [String] = []
        var snippetCode: String?

        func flushSlide() {
            guard let heading = currentHeading else { return }
            slideIndex += 1
            let prose = proseLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prose.isEmpty || snippetCode != nil else { return }

            let anchor = "#slide-\(slideIndex)-\(slugifyAnchor(heading))"
            let slideURL = "\(canonicalBaseURL)/tour/\(chapterSlug)/\(slideIndex)"
            let body: String
            if let snippetCode, !snippetCode.isEmpty {
                body = prose.isEmpty ? "```go\n\(snippetCode)\n```" : "\(prose)\n\n```go\n\(snippetCode)\n```"
            } else {
                body = prose
            }
            let summary = firstSentence(of: prose)
            let title = "\(resolvedTitle) — \(heading)"

            chunks.append(DocsChunk(
                goVersion: websiteVersionTag,
                source: .guide,
                provenance: .officialWebsiteSnapshot,
                packageName: "",
                documentID: "website/tour/\(chapterSlug)",
                symbol: heading,
                kind: .section,
                title: title,
                anchor: anchor,
                since: nil,
                summary: summary.isEmpty ? title : summary,
                signature: nil,
                example: snippetCode,
                body: body,
                sourceURL: slideURL,
                snapshotDate: snapshotDate
            ))
        }

        for line in lines {
            if line.hasPrefix("* ") {
                flushSlide()
                currentHeading = String(line.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                proseLines = []
                snippetCode = nil
                continue
            }
            guard currentHeading != nil else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") && !trimmed.hasPrefix("##") {
                // `present` comment line
                continue
            }
            if trimmed.hasPrefix(".play ") || trimmed.hasPrefix(".code ") {
                let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
                if parts.count >= 2 {
                    let relPath = String(parts[1])
                    let goURL = tourDirectory.appendingPathComponent(relPath)
                    if let code = loadPresentGoSnippet(at: goURL) {
                        if snippetCode == nil {
                            snippetCode = code
                        }
                    }
                }
                continue
            }
            if trimmed.hasPrefix(".image ") || trimmed.hasPrefix(".link ") || trimmed.hasPrefix(".caption ") {
                continue
            }
            proseLines.append(line)
        }
        flushSlide()
        return chunks
    }

    // MARK: - Helpers

    private static func extractSingleWebsiteFile(
        fileURL: URL,
        relativePath: String,
        webPath: String,
        snapshotDate: String?
    ) -> [DocsChunk] {
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        let noExt = relativePath.replacingOccurrences(of: #"\.(md|html)$"#, with: "", options: .regularExpression)
        let docID = "website/\(noExt)"
        let canonicalURL = "\(canonicalBaseURL)\(webPath)"
        let fallbackTitle = fileURL.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized

        if relativePath.hasSuffix(".html") {
            return extractHTMLDocument(
                html: raw,
                fallbackTitle: fallbackTitle,
                documentID: docID,
                canonicalPageURL: canonicalURL,
                snapshotDate: snapshotDate
            )
        }
        return extractWebsiteMarkdown(
            text: raw,
            fallbackTitle: fallbackTitle,
            documentID: docID,
            canonicalPageURL: canonicalURL,
            baseDirectory: fileURL.deletingLastPathComponent(),
            snapshotDate: snapshotDate
        )
    }

    private static func webPathForDocFile(_ relativePath: String) -> String {
        let stripped = relativePath.replacingOccurrences(of: #"\.(md|html)$"#, with: "", options: .regularExpression)
        return "/\(stripped)"
    }

    static func isReleaseNoteFilename(_ fileName: String) -> Bool {
        fileName.range(of: #"^go1(\.\d+)?\.md$"#, options: .regularExpression) != nil
    }

    static func blogExclusionReason(slug: String) -> String? {
        let lower = slug.lowercased()
        if lower.range(of: #"^go1(\.\d+)"#, options: .regularExpression) != nil {
            return "Go version release announcement; version-specific"
        }
        if lower.hasSuffix("years") || lower.contains("anniversary") {
            return "anniversary/milestone post"
        }
        for prefix in excludedBlogPrefixes {
            if lower.hasPrefix(prefix) {
                return "non-technical survey/event/announcement post"
            }
        }
        return nil
    }

    private static func parseMarkdownFrontMatter(_ raw: String) -> (title: String?, tags: [String], body: String) {
        var title: String?
        var tags: [String] = []
        var body = raw

        if raw.hasPrefix("---\n") || raw.hasPrefix("---\r\n") {
            let afterOpen = raw.dropFirst(4)
            if let closeRange = afterOpen.range(of: "\n---") {
                let fmText = String(afterOpen[..<closeRange.lowerBound])
                body = String(afterOpen[closeRange.upperBound...]).trimmingCharacters(in: .newlines)
                var inTags = false
                for line in fmText.components(separatedBy: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("title:") {
                        inTags = false
                        let val = trimmed.dropFirst("title:".count)
                            .trimmingCharacters(in: .whitespaces)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                        if !val.isEmpty { title = val }
                    } else if trimmed == "tags:" {
                        inTags = true
                    } else if inTags && trimmed.hasPrefix("- ") {
                        let tag = String(trimmed.dropFirst(2))
                            .trimmingCharacters(in: .whitespaces)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                        if !tag.isEmpty { tags.append(tag) }
                    } else if !trimmed.isEmpty && !trimmed.hasPrefix("-") {
                        inTags = false
                    }
                }
            }
        }
        return (title, tags, body)
    }

    private static func parseHTMLJSONFrontMatter(_ html: String) -> (title: String?, body: String) {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<!--{"),
              let endRange = trimmed.range(of: "}-->") else {
            return (nil, html)
        }
        let jsonStr = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 4)..<endRange.lowerBound]) + "}"
        let body = String(trimmed[endRange.upperBound...])
        var title: String?
        if let data = jsonStr.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let t = obj["Title"] as? String, !t.isEmpty {
            title = t
        }
        return (title, body)
    }

    /// Resolves `golang/website` blog directives like `{{code "context/interface.go" ...}}` or
    /// `{{play "foo/bar.go"}}` into fenced Go code blocks when the referenced `.go` file exists locally.
    private static func resolveBlogCodeDirectives(in text: String, baseDirectory: URL?) -> String {
        guard let baseDirectory else { return text }
        let pattern = #"\{\{(?:code|play)\s+"([^"]+)"[^}]*\}\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        var result = text
        for match in matches.reversed() {
            let relPath = ns.substring(with: match.range(at: 1))
            let fileURL = baseDirectory.appendingPathComponent(relPath)
            guard let code = loadPresentGoSnippet(at: fileURL) else { continue }
            let replacement = "```go\n\(code)\n```"
            if let swiftRange = Range(match.range, in: result) {
                result.replaceSubrange(swiftRange, with: replacement)
            }
        }
        return result
    }

    private static func loadPresentGoSnippet(at url: URL) -> String? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let filtered = raw.components(separatedBy: "\n").filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("//go:build OMIT") || t.hasPrefix("// +build OMIT") || t.contains("OMIT") {
                return false
            }
            return true
        }
        let joined = filtered.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else { return nil }
        return joined.count > 1_800 ? String(joined.prefix(1_800)) : joined
    }

    private static func extractFirstHTMLPreCode(from html: String) -> String? {
        let pattern = #"<pre[^>]*>([\s\S]*?)</pre>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = html as NSString
        guard let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let raw = ns.substring(with: match.range(at: 1))
        let stripped = raw.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        let decoded = decodeHTMLEntities(stripped).trimmingCharacters(in: .whitespacesAndNewlines)
        return decoded.isEmpty ? nil : decoded
    }

    private static func stripHTMLToPlainText(_ html: String) -> String {
        var s = html
        // Remove HTML comments and scripts/styles
        s = s.replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<(script|style)[^>]*>[\s\S]*?</\1>"#, with: "", options: .regularExpression)
        // Preserve line breaks for block tags
        s = s.replacingOccurrences(of: #"</?(?:p|div|li|br|tr|pre|blockquote|h[1-6])[^>]*>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        // Remove remaining tags
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        s = decodeHTMLEntities(s)
        // Collapse excessive blank lines
        let lines = s.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var out: [String] = []
        var prevEmpty = true
        for line in lines {
            if line.isEmpty {
                if !prevEmpty { out.append("") }
                prevEmpty = true
            } else {
                out.append(line)
                prevEmpty = false
            }
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeHTMLEntities(_ text: String) -> String {
        var s = text
        let entities: [(String, String)] = [
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&amp;", "&"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&apos;", "'"),
            ("&mdash;", "—"),
            ("&ndash;", "–"),
            ("&nbsp;", " "),
            ("&ldquo;", "\""),
            ("&rdquo;", "\""),
            ("&lsquo;", "'"),
            ("&rsquo;", "'")
        ]
        for (entity, replacement) in entities {
            s = s.replacingOccurrences(of: entity, with: replacement)
        }
        return s
    }

    private static func parseMarkdownHeadingWithAnchor(_ line: String) -> (title: String, explicitID: String?)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var hashes = 0
        for ch in trimmed {
            if ch == "#" { hashes += 1 } else { break }
        }
        guard (1...6).contains(hashes) else { return nil }
        let after = trimmed.dropFirst(hashes)
        guard after.first == " " || after.first == "\t" else { return nil }
        var title = after.trimmingCharacters(in: .whitespaces)
        var explicitID: String?
        if let idRange = title.range(of: #"\s*\{#([^}]+)\}\s*$"#, options: .regularExpression) {
            let matched = String(title[idRange])
            if let hashIdx = matched.firstIndex(of: "#"), let closeIdx = matched.firstIndex(of: "}") {
                explicitID = String(matched[matched.index(after: hashIdx)..<closeIdx]).trimmingCharacters(in: .whitespaces)
            }
            title = String(title[..<idRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        guard !title.isEmpty else { return nil }
        return (title, explicitID)
    }

    private static func parseMarkdownHeading(_ line: String) -> String? {
        parseMarkdownHeadingWithAnchor(line)?.title
    }

    private static func extractFirstGoFence(from markdown: String) -> String? {
        let lines = markdown.components(separatedBy: "\n")
        var inGo = false
        var collected: [String] = []
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !inGo {
                if t.hasPrefix("```go") || t == "```" {
                    inGo = true
                    collected = []
                }
            } else {
                if t.hasPrefix("```") {
                    let code = collected.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !code.isEmpty { return code }
                    inGo = false
                } else {
                    collected.append(line)
                }
            }
        }
        return nil
    }

    private static func stripCodeFences(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        var out: [String] = []
        var inFence = false
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") || t.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if !inFence { out.append(line) }
        }
        return out.joined(separator: "\n")
    }

    private static func firstSentence(of text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return "" }
        if let dot = collapsed.range(of: ". ") {
            let s = String(collapsed[..<dot.upperBound]).trimmingCharacters(in: .whitespaces)
            return s.count > 260 ? String(s.prefix(260)) + "…" : s
        }
        return collapsed.count > 260 ? String(collapsed.prefix(260)) + "…" : collapsed
    }

    private static func slugifyAnchor(_ heading: String) -> String {
        var out = ""
        var prevSep = false
        for ch in heading {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                prevSep = false
            } else if !prevSep && !out.isEmpty {
                out.append("_")
                prevSep = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return trimmed.isEmpty ? "section" : trimmed
    }

    private static func detectGitSnapshotMetadata(in repoRoot: URL) -> (date: String?, commit: String?) {
        let gitDir = repoRoot.appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: gitDir.path),
              let gitExe = ToolLocator.shared.find("git") else {
            return (nil, nil)
        }
        func runGit(_ args: [String]) -> String? {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: gitExe)
            proc.arguments = args
            proc.currentDirectoryURL = repoRoot
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            proc.standardInput = FileHandle.nullDevice
            do {
                try proc.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                guard proc.terminationStatus == 0 else { return nil }
                let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return (s?.isEmpty == false) ? s : nil
            } catch {
                return nil
            }
        }
        let commit = runGit(["rev-parse", "--short", "HEAD"])
        let date = runGit(["log", "-1", "--format=%cs"])
        return (date, commit)
    }
}
