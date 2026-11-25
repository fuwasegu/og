import Foundation

/// How retrieval was executed for a query (FR-28: UI explicitly displays FTS-only mode).
public enum DocsSearchMode: String, Sendable, Hashable, Codable {
    case ftsOnly = "fts_only"
    case hybridSemantic = "hybrid_semantic"

    public var label: String {
        switch self {
        case .ftsOnly: return "FTS5 (全文検索のみ — 意味検索は未構築/オフ)"
        case .hybridSemantic: return "Hybrid (決定的 + FTS5 + 意味検索)"
        }
    }
}

/// High-level outcome of a lookup (corresponds to `AnswerKind` in `spec/req/research.fsl`).
public enum DocsAnswerStatus: Sendable, Hashable {
    case disabled
    case missingPack(requestedVersion: GoVersion, installedVersions: [String])
    case found
    case notFound
}

/// One grounded answer card (UX-1, UX-2, UX-3, FR-12, FR-13).
public struct DocsAnswerCard: Sendable, Hashable {
    public var stableID: String
    public var title: String
    /// One-line reason / summary explaining why this candidate fits (UC-2, UX-1).
    public var reason: String
    public var signature: String?
    public var example: String?
    /// Citation label: document name + section or symbol (FR-13, G-4).
    public var citation: String
    public var sourceKind: DocsSourceKind
    public var packageName: String
    public var symbol: String
    public var anchor: String
    /// Pack Go version against which this card was verified (G-4, FR-13).
    public var goVersion: String
    /// Introduction version (`nil` when unknown; never guessed — FR-8).
    public var since: String?
    /// True only when a code example exists AND passed the version gate (UX-2, DOC-9).
    public var canInsert: Bool
    public var matchedBy: DocsMatchOrigin

    public init(
        stableID: String,
        title: String,
        reason: String,
        signature: String?,
        example: String?,
        citation: String,
        sourceKind: DocsSourceKind,
        packageName: String,
        symbol: String,
        anchor: String,
        goVersion: String,
        since: String?,
        canInsert: Bool,
        matchedBy: DocsMatchOrigin
    ) {
        self.stableID = stableID
        self.title = title
        self.reason = reason
        self.signature = signature
        self.example = example
        self.citation = citation
        self.sourceKind = sourceKind
        self.packageName = packageName
        self.symbol = symbol
        self.anchor = anchor
        self.goVersion = goVersion
        self.since = since
        self.canInsert = canInsert
        self.matchedBy = matchedBy
    }
}

/// Separated notice for features that exist in Go docs but require a newer Go version than the project (UC-1, FR-10).
/// Never eligible for editor insertion.
public struct DocsNewerVersionNote: Sendable, Hashable {
    public var title: String
    public var since: GoVersion
    public var citation: String

    public init(title: String, since: GoVersion, citation: String) {
        self.title = title
        self.since = since
        self.citation = citation
    }
}

/// Complete response from `ResearchService.search(...)` (UX-1..7, FR-12..15).
public struct DocsAnswer: Sendable, Hashable {
    public var query: String
    public var status: DocsAnswerStatus
    public var language: DocsLanguage
    public var intent: DocsQueryIntent
    public var conclusion: String
    /// Maximum 3 grounded, version-gated cards (UX-3).
    public var cards: [DocsAnswerCard]
    /// Features filtered out by the version gate, separated with explicit "Go X.Y+" notes (UC-1, FR-10).
    public var newerVersionNotes: [DocsNewerVersionNote]
    public var targetVersion: GoVersion?
    public var versionSource: GoVersionSource?
    public var searchMode: DocsSearchMode
    public var usedLLM: Bool
    /// Explicit search scope shown on all answers and especially Not Found (FR-14).
    public var searchedScope: String
    public var licenseNotice: String

    public init(
        query: String,
        status: DocsAnswerStatus,
        language: DocsLanguage,
        intent: DocsQueryIntent,
        conclusion: String,
        cards: [DocsAnswerCard] = [],
        newerVersionNotes: [DocsNewerVersionNote] = [],
        targetVersion: GoVersion? = nil,
        versionSource: GoVersionSource? = nil,
        searchMode: DocsSearchMode = .ftsOnly,
        usedLLM: Bool = false,
        searchedScope: String = "",
        licenseNotice: String = DocsLicense.goBSD3Clause
    ) {
        self.query = query
        self.status = status
        self.language = language
        self.intent = intent
        self.conclusion = conclusion
        self.cards = cards
        self.newerVersionNotes = newerVersionNotes
        self.targetVersion = targetVersion
        self.versionSource = versionSource
        self.searchMode = searchMode
        self.usedLLM = usedLLM
        self.searchedScope = searchedScope
        self.licenseNotice = licenseNotice
    }
}

/// Formats and validates a card snippet for insertion into a Go editor (UX-2, DOC-9).
public enum DocsCodeInserter {
    /// Returns formatted Go code if the card is allowed for `targetVersion`, or `nil` if gated/empty.
    public static func prepareSnippet(
        from card: DocsAnswerCard,
        targetVersion: GoVersion,
        locator: ToolLocator = .shared
    ) -> String? {
        guard card.canInsert, let raw = card.example, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        // Double-check version gate before insertion (DOC-9).
        guard GoVersionGate.evaluate(since: card.since, target: targetVersion) == .allowed else {
            return nil
        }
        return formatGoSnippet(raw, locator: locator)
    }

    /// Runs `gofmt` if available on the machine; wraps statement snippets in a dummy function so `gofmt` accepts them.
    public static func formatGoSnippet(_ snippet: String, locator: ToolLocator = .shared) -> String {
        let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard let gofmt = locator.find("gofmt") else {
            return normalizeIndentation(trimmed)
        }
        // If snippet looks like a full file or top-level declaration, format directly; else wrap in `func _()`.
        let isTopLevel = trimmed.hasPrefix("package ") || trimmed.hasPrefix("func ") || trimmed.hasPrefix("type ")
        if isTopLevel, let formatted = runGofmt(gofmt, input: trimmed, env: locator.environment) {
            return formatted.trimmingCharacters(in: .newlines)
        }
        let wrapped = "package _og\n\nfunc _() {\n" + trimmed + "\n}\n"
        if let formatted = runGofmt(gofmt, input: wrapped, env: locator.environment),
           let unwrapped = unwrapDummyFunc(formatted) {
            return unwrapped
        }
        return normalizeIndentation(trimmed)
    }

    private static func runGofmt(_ executable: String, input: String, env: [String: String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.environment = env
        let inPipe = Pipe()
        let outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return nil
        }
        inPipe.fileHandleForWriting.write(Data(input.utf8))
        try? inPipe.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(2)
        while proc.isRunning && Date() < deadline { usleep(10_000) }
        if proc.isRunning { proc.terminate(); return nil }
        guard proc.terminationStatus == 0 else { return nil }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    private static func unwrapDummyFunc(_ formatted: String) -> String? {
        let lines = formatted.components(separatedBy: "\n")
        guard let startIdx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "func _() {" }),
              let endIdx = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "}" }),
              endIdx > startIdx + 1 else {
            return nil
        }
        let body = Array(lines[(startIdx + 1)..<endIdx]).map { line -> String in
            line.hasPrefix("\t") ? String(line.dropFirst()) : line
        }
        return body.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    private static func normalizeIndentation(_ snippet: String) -> String {
        snippet
            .components(separatedBy: "\n")
            .map { line -> String in
                var s = line
                while s.hasSuffix(" ") || s.hasSuffix("\t") { s.removeLast() }
                return s
            }
            .joined(separator: "\n")
    }
}

/// Fixed-pipeline offline Go documentation research engine (spec/design/research.fsl, §7.3).
///
/// Pipeline (fixed, never an unbounded agent loop):
/// 1. Rule-based routing (`DocsQueryRouter`)
/// 2. Target Go version resolution (FR-2) and exact-pack check (§7.4)
/// 3. Deterministic -> FTS5 -> optional Semantic retrieval & merge (FR-9)
/// 4. Strict version gating (FR-10) + max-3 card cap (UX-3)
/// 5. Grounded card rendering with citations, Go version, and honest Not Found (FR-12..15)
public actor ResearchService {
    public static let maxCards = 3

    public let packManager: DocsPackManager
    private var enabled: Bool
    private var validatedEndpoint: URL?
    private var queryEmbedder: (any DocsEmbedder)?

    public init(packManager: DocsPackManager, enabled: Bool = false) {
        self.packManager = packManager
        self.enabled = enabled
    }

    public func isEnabled() -> Bool { enabled }

    public func setEnabled(_ value: Bool) {
        enabled = value
    }

    /// DES-1 / DOC-6: Validates that any configured model server endpoint is loopback only.
    public func setLocalEndpoint(_ url: URL?) throws {
        guard let url else {
            validatedEndpoint = nil
            return
        }
        guard LocalCompletionClient.isLoopback(url) else {
            throw DocsStorageError.nonLoopbackEndpoint(url.absoluteString)
        }
        validatedEndpoint = url
    }

    public func currentEndpoint() -> URL? { validatedEndpoint }

    /// Configures an optional local embedder for semantic search (Phase 2 / tests).
    public func setEmbedder(_ embedder: (any DocsEmbedder)?) {
        queryEmbedder = embedder
    }

    /// Executes the fixed offline retrieval pipeline (§7.3).
    public func search(
        query rawQuery: String,
        projectRoot: URL? = nil,
        explicitVersionOverride: GoVersion? = nil,
        editorContext: DocsEditorContext? = nil,
        toolchainVersionProvider: (() -> GoVersion?)? = nil
    ) async throws -> DocsAnswer {
        let plan = DocsQueryRouter.route(rawQuery)

        // DOC-1: opt-in check
        guard enabled else {
            let msg = plan.language == .japanese
                ? "Go 調べ物機能は現在オフです。設定画面（⌘,）で有効にしてください。"
                : "Offline Go Docs lookup is disabled. Enable it in Settings (⌘,)."
            return DocsAnswer(
                query: plan.originalQuery,
                status: .disabled,
                language: plan.language,
                intent: plan.intent,
                conclusion: msg
            )
        }

        // Empty query returns a gentle prompt without fabricating results.
        guard !plan.originalQuery.isEmpty else {
            let msg = plan.language == .japanese
                ? "調べたい内容（例: 「ファイルを1行ずつ読みたい」「for ループの書き方」「json.Encoder」）を入力してください。"
                : "Enter a Go question or symbol (e.g. \"read file line by line\", \"json.Encoder\")."
            return DocsAnswer(
                query: "",
                status: .notFound,
                language: plan.language,
                intent: plan.intent,
                conclusion: msg
            )
        }

        // Step 2: Resolve target Go version (FR-2).
        let resolved: ResolvedGoVersion
        if let override = explicitVersionOverride {
            resolved = ResolvedGoVersion(version: override, source: .manualOverride)
        } else if let detected = GoVersionResolver.resolve(projectRoot: projectRoot, toolchainVersionProvider: toolchainVersionProvider) {
            resolved = detected
        } else {
            let fallbackVer = GoVersion(parsing: BundledGoCorpus.defaultVersion) ?? GoVersion(major: 1, minor: 23)
            resolved = ResolvedGoVersion(version: fallbackVer, source: .bundledDefault)
        }

        let targetVer = resolved.version
        let packKey = targetVer.minorKey

        // §7.4 / DOC-2: Never silently answer from a different Go version's pack when the matching pack is missing.
        guard let manifest = await packManager.manifest(for: packKey),
              let index = try await packManager.openIndex(for: packKey) else {
            let installed = await packManager.installedPacks().map(\.goVersion)
            let msg: String
            if plan.language == .japanese {
                let avail = installed.isEmpty ? "なし" : installed.map { "go\($0)" }.joined(separator: ", ")
                msg = "Go \(packKey) 用のドキュメントパックが未インストールです（導入済み: \(avail)）。別バージョンで勝手に回答せず停止しました。パックを追加するか、バージョンを明示的に切り替えてください。"
            } else {
                let avail = installed.isEmpty ? "none" : installed.map { "go\($0)" }.joined(separator: ", ")
                msg = "No documentation pack installed for Go \(packKey) (installed: \(avail)). Install the matching pack or explicitly select another version."
            }
            return DocsAnswer(
                query: plan.originalQuery,
                status: .missingPack(requestedVersion: targetVer, installedVersions: installed),
                language: plan.language,
                intent: plan.intent,
                conclusion: msg,
                targetVersion: targetVer,
                versionSource: resolved.source,
                searchMode: .ftsOnly,
                usedLLM: false,
                searchedScope: "Go \(packKey) (pack not installed)"
            )
        }
        defer { index.close() }

        // Step 3: Fixed hybrid candidate collection: deterministic -> FTS5 -> optional semantic (FR-9, §7.3).
        var combined: [String: (chunk: DocsChunk, score: Double, origin: DocsMatchOrigin)] = [:]

        func merge(_ hits: [DocsIndexHit], weight: Double) {
            for hit in hits {
                let weighted = hit.score * weight
                if var existing = combined[hit.chunk.stableID] {
                    existing.score += weighted
                    if hit.matchedBy == .deterministicExact {
                        existing.origin = .deterministicExact
                    }
                    combined[hit.chunk.stableID] = existing
                } else {
                    combined[hit.chunk.stableID] = (hit.chunk, weighted, hit.matchedBy)
                }
            }
        }

        // 3a. Deterministic lookup (FR-1, FR-9a)
        if let sym = plan.exactSymbolCandidate {
            let detHits = try index.deterministicSearch(symbolOrPackage: sym, limit: 8)
            merge(detHits, weight: 2.0)
        }

        // 3b. SQLite FTS5 full-text search (FR-9b)
        if !plan.searchTerms.isEmpty {
            let ftsHits = try index.ftsSearch(terms: plan.searchTerms, limit: 15)
            merge(ftsHits, weight: 1.0)
        }

        // 3c. Optional semantic search ONLY when pack is Ready AND model matches (FR-27, FR-28, DOC-4)
        var searchMode: DocsSearchMode = .ftsOnly
        if manifest.status == .ready,
           let embedder = queryEmbedder,
           manifest.embeddingModelID == embedder.descriptor.id,
           manifest.embeddingModelVersion == embedder.descriptor.version {
            if let qVec = try? await embedder.embed(plan.originalQuery) {
                let semHits = try await index.semanticSearch(
                    queryVector: qVec,
                    model: embedder.descriptor,
                    sharedStore: packManager.sharedVectorStore,
                    limit: 10
                )
                merge(semHits, weight: 1.2)
                searchMode = .hybridSemantic
            }
        }

        // Step 3d: Anti-hallucination / stop-word signal filter (FR-14).
        // When there are meaningful signal terms, require at least one signal match (unless matched semantically).
        let candidates = combined.values.filter { entry in
            if entry.origin == .deterministicExact || entry.origin == .semantic {
                return true
            }
            guard !plan.requiredSignalTerms.isEmpty else { return false }
            let hay = (
                entry.chunk.title + " " +
                entry.chunk.packageName + " " +
                entry.chunk.symbol + " " +
                entry.chunk.summary + " " +
                entry.chunk.body + " " +
                entry.chunk.searchAliases.joined(separator: " ")
            ).lowercased()
            return plan.requiredSignalTerms.contains { hay.contains($0) }
        }

        // Step 4: Version gating BEFORE final ranking (FR-10, UC-1).
        var allowedEntries: [(chunk: DocsChunk, score: Double, origin: DocsMatchOrigin)] = []
        var newerNotes: [DocsNewerVersionNote] = []

        for entry in candidates {
            switch GoVersionGate.evaluate(since: entry.chunk.since, target: targetVer) {
            case .allowed:
                var adjusted = entry.score
                // Intent-aware source affinity (UC-1 favors spec + guide; UC-2/UC-3 favor stdlib).
                switch plan.intent {
                case .syntaxHowTo:
                    if entry.chunk.source == .spec { adjusted += 18.0 }
                    else if entry.chunk.source == .guide { adjusted += 14.0 }
                case .exactSymbol, .existenceCheck, .needsReverseLookup:
                    if entry.chunk.source == .stdlib { adjusted += 10.0 }
                case .releaseSince:
                    if entry.chunk.source == .release { adjusted += 20.0 }
                case .idiomOrWhy:
                    if entry.chunk.source == .guide || entry.chunk.source == .spec { adjusted += 12.0 }
                }
                // FR-3: weak signal from currently edited file's imports (never leaves machine).
                if let ctx = editorContext, !entry.chunk.packageName.isEmpty,
                   ctx.importedPackages.contains(entry.chunk.packageName) {
                    adjusted += 1.5
                }
                allowedEntries.append((entry.chunk, adjusted, entry.origin))
            case .requiresNewer(let since):
                newerNotes.append(DocsNewerVersionNote(
                    title: entry.chunk.title,
                    since: since,
                    citation: entry.chunk.citationLabel
                ))
            }
        }

        allowedEntries.sort {
            if abs($0.score - $1.score) > 0.001 { return $0.score > $1.score }
            return $0.chunk.stableID < $1.chunk.stableID
        }
        newerNotes.sort { ($0.since, $0.title) < ($1.since, $1.title) }

        let scopeText = "Go \(packKey) pack (\(manifest.chunkCount) chunks: Language Spec, Official Guides, Standard Library)"

        // Step 5: Honest Not Found when zero grounded, version-gated candidates match (FR-12, FR-14, UX-4).
        guard !allowedEntries.isEmpty else {
            let msg: String
            if plan.language == .japanese {
                msg = "標準ライブラリ・公式ドキュメント（Go \(packKey)）には該当する機能が見つかりませんでした。根拠のないシンボルは提示しません。"
            } else {
                msg = "No matching symbol or guide was found in the Go \(packKey) offline documentation pack."
            }
            return DocsAnswer(
                query: plan.originalQuery,
                status: .notFound,
                language: plan.language,
                intent: plan.intent,
                conclusion: msg,
                cards: [],
                newerVersionNotes: Array(newerNotes.prefix(3)),
                targetVersion: targetVer,
                versionSource: resolved.source,
                searchMode: searchMode,
                usedLLM: false,
                searchedScope: scopeText
            )
        }

        // UX-3: cap to maximum 3 grounded cards.
        let top = allowedEntries.prefix(Self.maxCards)
        let cards: [DocsAnswerCard] = top.map { entry in
            let c = entry.chunk
            let hasCode = !(c.example?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            let canInsert = hasCode && GoVersionGate.evaluate(since: c.since, target: targetVer) == .allowed
            return DocsAnswerCard(
                stableID: c.stableID,
                title: c.title,
                reason: c.summary,
                signature: c.signature,
                example: c.example,
                citation: c.citationLabel,
                sourceKind: c.source,
                packageName: c.packageName,
                symbol: c.symbol,
                anchor: c.anchor,
                goVersion: packKey,
                since: c.since,
                canInsert: canInsert,
                matchedBy: entry.origin
            )
        }

        let conclusion = buildConclusion(plan: plan, cards: cards, targetVersion: targetVer)

        return DocsAnswer(
            query: plan.originalQuery,
            status: .found,
            language: plan.language,
            intent: plan.intent,
            conclusion: conclusion,
            cards: cards,
            newerVersionNotes: Array(newerNotes.prefix(3)),
            targetVersion: targetVer,
            versionSource: resolved.source,
            searchMode: searchMode,
            usedLLM: false,
            searchedScope: scopeText
        )
    }

    private func buildConclusion(
        plan: DocsRoutingPlan,
        cards: [DocsAnswerCard],
        targetVersion: GoVersion
    ) -> String {
        guard let top = cards.first else { return "" }
        let verLabel = targetVersion.description
        switch (plan.intent, plan.language) {
        case (.existenceCheck, .japanese):
            let name = top.packageName.isEmpty ? top.symbol : (top.symbol.isEmpty ? top.packageName : "\(top.packageName).\(top.symbol)")
            return "あります（\(verLabel)）: `\(name)` が標準ライブラリで利用できます。"
        case (.existenceCheck, .english):
            let name = top.packageName.isEmpty ? top.symbol : (top.symbol.isEmpty ? top.packageName : "\(top.packageName).\(top.symbol)")
            return "Yes (\(verLabel)): `\(name)` is available in the Go standard library."
        case (.syntaxHowTo, .japanese):
            return "\(verLabel) で使える書き方と指針（\(cards.count)件）:"
        case (.syntaxHowTo, .english):
            return "Syntax and guidance for \(verLabel) (\(cards.count) match\(cards.count == 1 ? "" : "es")):"
        case (.exactSymbol, .japanese):
            return "\(verLabel) の公式リファレンス（\(top.citation)）:"
        case (.exactSymbol, .english):
            return "Official reference for \(verLabel) (\(top.citation)):"
        case (_, .japanese):
            let name = top.packageName.isEmpty ? top.title : "\(top.packageName).\(top.symbol)"
            return "あります（\(verLabel)）: 第一候補は `\(name)` です（候補 \(cards.count)件）。"
        case (_, .english):
            let name = top.packageName.isEmpty ? top.title : "\(top.packageName).\(top.symbol)"
            return "Found for \(verLabel): top match `\(name)` (\(cards.count) result\(cards.count == 1 ? "" : "s"))."
        }
    }
}
