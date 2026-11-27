import Foundation

/// How retrieval was executed for a query (FR-28: UI explicitly displays active retrieval mode).
public enum DocsSearchMode: String, Sendable, Hashable, Codable {
    case ftsOnly = "fts_only"
    case ftsReranked = "fts_reranked"
    case hybridSemantic = "hybrid_semantic"
    case hybridReranked = "hybrid_reranked"

    public var label: String {
        switch self {
        case .ftsOnly: return "FTS5 (全文検索のみ — 意味検索は未構築/オフ)"
        case .ftsReranked: return "FTS5 + Rerank (全文検索 + リランク)"
        case .hybridSemantic: return "Hybrid (決定的 + FTS5 + 意味検索)"
        case .hybridReranked: return "Hybrid + Rerank (決定的 + FTS5 + 意味検索 + リランク)"
        }
    }

    public var shortLabel: String {
        switch self {
        case .ftsOnly: return "FTS5 のみ"
        case .ftsReranked: return "FTS5 + Rerank"
        case .hybridSemantic: return "Hybrid"
        case .hybridReranked: return "Hybrid + Rerank"
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
    /// Citation label: document name + section or symbol (FR-13, G-4, R-9).
    public var citation: String
    public var sourceKind: DocsSourceKind
    /// Provenance distinguishing directly extracted official GoDoc from bundled curated summaries (R-9).
    public var provenance: DocsProvenance
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
    /// For `.dependency` cards: module path from `go.mod` / `go.work` (Issue #27).
    public var modulePath: String?
    /// For `.dependency` cards: exact module version from `go.mod` / `go.work` (Issue #27).
    public var moduleVersion: String?
    /// For `.dependency` cards: optional concise SPDX-style license identifier (DES-DEP-4).
    public var license: String?
    /// For `.officialWebsiteSnapshot` cards: canonical official URL on `go.dev` (Issue #26, DOC-14b).
    public var sourceURL: String?
    /// For `.officialWebsiteSnapshot` cards: ISO-8601 snapshot date (`YYYY-MM-DD`) (Issue #26, DOC-14b).
    public var snapshotDate: String?

    public init(
        stableID: String,
        title: String,
        reason: String,
        signature: String?,
        example: String?,
        citation: String,
        sourceKind: DocsSourceKind,
        provenance: DocsProvenance = .officialExtracted,
        packageName: String,
        symbol: String,
        anchor: String,
        goVersion: String,
        since: String?,
        canInsert: Bool,
        matchedBy: DocsMatchOrigin,
        modulePath: String? = nil,
        moduleVersion: String? = nil,
        license: String? = nil,
        sourceURL: String? = nil,
        snapshotDate: String? = nil
    ) {
        self.stableID = stableID
        self.title = title
        self.reason = reason
        self.signature = signature
        self.example = example
        self.citation = citation
        self.sourceKind = sourceKind
        self.provenance = provenance
        self.packageName = packageName
        self.symbol = symbol
        self.anchor = anchor
        self.goVersion = goVersion
        self.since = since
        self.canInsert = canInsert
        self.matchedBy = matchedBy
        self.modulePath = modulePath
        self.moduleVersion = moduleVersion
        self.license = license
        self.sourceURL = sourceURL
        self.snapshotDate = snapshotDate
    }
}

/// Summary of project dependency packs active during a search (Issue #27, DOC-12).
public struct DocsDependencySearchSummary: Sendable, Hashable {
    /// Dependencies whose exact-version packs were searched.
    public var indexedModules: [GoModuleKey]
    /// Dependencies present in local GOMODCACHE but not yet extracted into a pack.
    public var unindexedCachedModules: [GoModuleKey]
    /// Dependencies absent from local GOMODCACHE ("未取得"; never substituted with another version).
    public var uncachedModules: [GoModuleKey]

    public init(
        indexedModules: [GoModuleKey] = [],
        unindexedCachedModules: [GoModuleKey] = [],
        uncachedModules: [GoModuleKey] = []
    ) {
        self.indexedModules = indexedModules
        self.unindexedCachedModules = unindexedCachedModules
        self.uncachedModules = uncachedModules
    }

    public var totalDependencies: Int {
        indexedModules.count + unindexedCachedModules.count + uncachedModules.count
    }

    public var hasAnyDependency: Bool {
        totalDependencies > 0
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

/// Complete response from `ResearchService.search(...)` (UX-1..7, FR-12..15, DOC-11).
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
    /// Optional Phase 3 synthesized answer with citations and local snippet verification (DOC-11, Issue #24).
    public var generatedAnswer: DocsGeneratedAnswer?
    public var targetVersion: GoVersion?
    public var versionSource: GoVersionSource?
    public var searchMode: DocsSearchMode
    public var usedLLM: Bool
    /// True when the local cross-encoder reranker re-scored the returned cards (DOC-10, Issue #21).
    public var usedReranker: Bool
    /// Explicit search scope shown on all answers and especially Not Found (FR-14).
    public var searchedScope: String
    public var licenseNotice: String
    /// Dependency pack coverage for the active project (Issue #27, DOC-12). `nil` for stdlib-only projects.
    public var dependencySummary: DocsDependencySearchSummary?

    public init(
        query: String,
        status: DocsAnswerStatus,
        language: DocsLanguage,
        intent: DocsQueryIntent,
        conclusion: String,
        cards: [DocsAnswerCard] = [],
        newerVersionNotes: [DocsNewerVersionNote] = [],
        generatedAnswer: DocsGeneratedAnswer? = nil,
        targetVersion: GoVersion? = nil,
        versionSource: GoVersionSource? = nil,
        searchMode: DocsSearchMode = .ftsOnly,
        usedLLM: Bool = false,
        usedReranker: Bool = false,
        searchedScope: String = "",
        licenseNotice: String = DocsLicense.goBSD3Clause,
        dependencySummary: DocsDependencySearchSummary? = nil
    ) {
        self.query = query
        self.status = status
        self.language = language
        self.intent = intent
        self.conclusion = conclusion
        self.cards = cards
        self.newerVersionNotes = newerVersionNotes
        self.generatedAnswer = generatedAnswer
        self.targetVersion = targetVersion
        self.versionSource = versionSource
        self.searchMode = searchMode
        self.usedLLM = usedLLM
        self.usedReranker = usedReranker
        self.searchedScope = searchedScope
        self.licenseNotice = licenseNotice
        self.dependencySummary = dependencySummary
    }
}

/// Formatted snippet ready for insertion, explicitly recording whether `gofmt` succeeded (L-11).
public struct DocsPreparedSnippet: Sendable, Hashable {
    public var code: String
    public var formattedByGofmt: Bool

    public init(code: String, formattedByGofmt: Bool) {
        self.code = code
        self.formattedByGofmt = formattedByGofmt
    }
}

/// Formats and validates a card snippet for insertion into a Go editor (UX-2, DOC-9, M-3, L-11, R-10c).
public enum DocsCodeInserter {
    /// Async preparation that runs `gofmt` off the main thread and terminates `gofmt` immediately on Task cancellation (M-3, R-10c).
    public static func prepareSnippetAsync(
        from card: DocsAnswerCard,
        targetVersion: GoVersion,
        locator: ToolLocator = .shared
    ) async -> DocsPreparedSnippet? {
        guard !Task.isCancelled else { return nil }
        guard card.canInsert, let raw = card.example, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        guard GoVersionGate.evaluate(since: card.since, target: targetVersion) == .allowed else {
            return nil
        }
        let prepared = await formatGoSnippetDetailedAsync(raw, locator: locator)
        guard !Task.isCancelled else { return nil }
        return prepared
    }

    /// Async preparation for a verified Phase 3 generated snippet (DOC-11, DOC-9).
    public static func prepareSnippetAsync(
        from generated: DocsGeneratedAnswer,
        targetVersion: GoVersion,
        locator: ToolLocator = .shared
    ) async -> DocsPreparedSnippet? {
        guard !Task.isCancelled else { return nil }
        guard generated.canInsert,
              generated.targetVersion.minorKey == targetVersion.minorKey,
              let raw = generated.snippet,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let prepared = await formatGoSnippetDetailedAsync(raw, locator: locator)
        guard !Task.isCancelled else { return nil }
        return prepared
    }

    /// Synchronous convenience helper (for unit tests and non-UI callers).
    public static func prepareSnippet(
        from card: DocsAnswerCard,
        targetVersion: GoVersion,
        locator: ToolLocator = .shared
    ) -> String? {
        guard card.canInsert, let raw = card.example, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        guard GoVersionGate.evaluate(since: card.since, target: targetVersion) == .allowed else {
            return nil
        }
        return formatGoSnippetDetailed(raw, locator: locator).code
    }

    /// Runs `gofmt` asynchronously with cancellation propagation; returns explicit `formattedByGofmt` status (L-11, R-10c).
    public static func formatGoSnippetDetailedAsync(_ snippet: String, locator: ToolLocator = .shared) async -> DocsPreparedSnippet {
        let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return DocsPreparedSnippet(code: "", formattedByGofmt: false) }
        guard !Task.isCancelled, let gofmt = locator.find("gofmt") else {
            return DocsPreparedSnippet(code: normalizeIndentation(trimmed), formattedByGofmt: false)
        }
        let isTopLevel = trimmed.hasPrefix("package ") || trimmed.hasPrefix("func ") || trimmed.hasPrefix("type ")
        if isTopLevel, let formatted = await runGofmtAsync(gofmt, input: trimmed, env: locator.environment) {
            return DocsPreparedSnippet(code: formatted.trimmingCharacters(in: .newlines), formattedByGofmt: true)
        }
        guard !Task.isCancelled else {
            return DocsPreparedSnippet(code: normalizeIndentation(trimmed), formattedByGofmt: false)
        }
        let wrapped = "package _og\n\nfunc _() {\n" + trimmed + "\n}\n"
        if let formatted = await runGofmtAsync(gofmt, input: wrapped, env: locator.environment),
           let unwrapped = unwrapDummyFunc(formatted) {
            return DocsPreparedSnippet(code: unwrapped, formattedByGofmt: true)
        }
        return DocsPreparedSnippet(code: normalizeIndentation(trimmed), formattedByGofmt: false)
    }

    /// Runs `gofmt` if available; returns explicit `formattedByGofmt` status (L-11).
    public static func formatGoSnippetDetailed(_ snippet: String, locator: ToolLocator = .shared) -> DocsPreparedSnippet {
        let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return DocsPreparedSnippet(code: "", formattedByGofmt: false) }
        guard let gofmt = locator.find("gofmt") else {
            return DocsPreparedSnippet(code: normalizeIndentation(trimmed), formattedByGofmt: false)
        }
        let isTopLevel = trimmed.hasPrefix("package ") || trimmed.hasPrefix("func ") || trimmed.hasPrefix("type ")
        if isTopLevel, let formatted = runGofmt(gofmt, input: trimmed, env: locator.environment) {
            return DocsPreparedSnippet(code: formatted.trimmingCharacters(in: .newlines), formattedByGofmt: true)
        }
        let wrapped = "package _og\n\nfunc _() {\n" + trimmed + "\n}\n"
        if let formatted = runGofmt(gofmt, input: wrapped, env: locator.environment),
           let unwrapped = unwrapDummyFunc(formatted) {
            return DocsPreparedSnippet(code: unwrapped, formattedByGofmt: true)
        }
        return DocsPreparedSnippet(code: normalizeIndentation(trimmed), formattedByGofmt: false)
    }

    public static func formatGoSnippet(_ snippet: String, locator: ToolLocator = .shared) -> String {
        formatGoSnippetDetailed(snippet, locator: locator).code
    }

    private static func runGofmtAsync(_ executable: String, input: String, env: [String: String]) async -> String? {
        guard !Task.isCancelled else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.environment = env
        let inPipe = Pipe()
        let outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice

        let output: String? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                    return
                }
                let finished = LockedFlag()
                let timeoutTask = Task.detached(priority: .utility) {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if finished.trySet() {
                        if proc.isRunning { proc.terminate() }
                        continuation.resume(returning: nil)
                    }
                }
                proc.terminationHandler = { p in
                    timeoutTask.cancel()
                    if finished.trySet() {
                        guard p.terminationStatus == 0 else {
                            continuation.resume(returning: nil)
                            return
                        }
                        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                        continuation.resume(returning: String(data: data, encoding: .utf8))
                    }
                }
                do {
                    try proc.run()
                    // S-6: never write stdin after cancellation or process termination; use throwing write(contentsOf:) to avoid EPIPE NSException.
                    if Task.isCancelled || !proc.isRunning {
                        try? inPipe.fileHandleForWriting.close()
                        if proc.isRunning { proc.terminate() }
                        return
                    }
                    try inPipe.fileHandleForWriting.write(contentsOf: Data(input.utf8))
                    try? inPipe.fileHandleForWriting.close()
                } catch {
                    try? inPipe.fileHandleForWriting.close()
                    if proc.isRunning { proc.terminate() }
                    timeoutTask.cancel()
                    if finished.trySet() {
                        continuation.resume(returning: nil)
                    }
                }
            }
        } onCancel: {
            if proc.isRunning { proc.terminate() }
        }
        return Task.isCancelled ? nil : output
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
        let sema = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in sema.signal() }
        do {
            try proc.run()
            try inPipe.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try? inPipe.fileHandleForWriting.close()
        } catch {
            try? inPipe.fileHandleForWriting.close()
            if proc.isRunning { proc.terminate() }
            return nil
        }
        if sema.wait(timeout: .now() + .seconds(2)) == .timedOut {
            proc.terminate()
            return nil
        }
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

/// Fixed two-stage offline Go documentation research engine (spec/design/research.fsl, §7.3, Issue #21).
///
/// Pipeline (fixed, never an unbounded agent loop):
/// 1. Rule-based routing (`DocsQueryRouter`)
/// 2. Target Go version resolution (FR-2) and exact-pack check (§7.4)
/// 3. Stage 1 retrieval: collect Deterministic (up to 10) + FTS5 (up to 20) + optional Semantic (up to 30) candidates
/// 4. Per-chunk `since` version gating BEFORE final ranking (FR-10, DOC-2, DOC-10)
/// 5. Stage 2 balanced union pool (capped at `retrievalPoolLimit = 30`) -> optional local cross-encoder reranking (`DocsReranker`) + anti-hallucination gating + max-3 cap (UX-3, Issue #21)
///    Falls back cleanly to Stage 1 (Phase 1 behavior) when no reranker is configured or if reranking fails.
/// 6. Grounded card rendering with citations, Go version, and honest Not Found (FR-12..15)
public actor ResearchService {
    public static let maxCards = 3
    /// Candidate pool size passed to Stage 2 cross-encoder reranking (benchmarked in Issue #21: N=30, ~318ms median).
    public static let retrievalPoolLimit = 30
    /// Minimum cosine similarity for semantic candidates (calibrated on real GOROOT with bge-m3-mlx-8bit, Issue #21;
    /// replaces Phase 1 provisional 0.35; positive top-1 measured 0.541..0.692, negative max 0.522).
    public static let minimumSemanticSimilarity = 0.45
    /// Threshold (similarity * 100) above which a semantic-only match without lexical overlap may pass when no reranker
    /// is active (calibrated on real GOROOT with bge-m3-mlx-8bit, Issue #21; replaces Phase 1 provisional 80.0;
    /// sits in the measured separation band between negative max 52.2 and positive min 54.1).
    public static let highConfidenceSemanticScore = 53.5
    /// Minimum cross-encoder probability `[0, 1]` for semantic-only / ungrounded candidates (calibrated on real GOROOT
    /// with bge-reranker-v2-m3-mlx-8bit, Issue #21: positive min 0.018 / median 0.758 vs negative max 0.002).
    public static let minimumRerankScore = 0.015
    /// Stricter cross-encoder threshold for `existenceCheck` queries without lexical signal overlap (FR-14).
    public static let minimumExistenceRerankScore = 0.05

    public let packManager: DocsPackManager
    private var enabled: Bool
    private var validatedEndpoint: URL?
    private var queryEmbedder: (any DocsEmbedder)?
    private var reranker: (any DocsReranker)?
    private var answerGenerator: (any DocsAnswerGenerator)?
    private var snippetVerifier: any DocsSnippetVerifying = DocsSnippetVerifier()
    private var includeEditorContextInGeneration = true
    private var conceptRulesOverride: [DocsConceptRule]?

    public init(packManager: DocsPackManager, enabled: Bool = false) {
        self.packManager = packManager
        self.enabled = enabled
    }

    public func isEnabled() -> Bool { enabled }

    public func setEnabled(_ value: Bool) {
        enabled = value
    }

    /// Overrides the temporary Phase 1 data-driven cross-lingual concept rules (R-1, S-3).
    /// Pass `nil` to revert to loading rules dynamically from `packManager.loadConceptRules(forGoVersion:)`.
    public func setConceptRules(_ rules: [DocsConceptRule]?) {
        conceptRulesOverride = rules
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

    /// Configures an optional local cross-encoder reranker for Stage 2 ranking (Issue #21, DOC-10).
    public func setReranker(_ reranker: (any DocsReranker)?) {
        self.reranker = reranker
    }

    public func hasReranker() -> Bool {
        reranker != nil
    }

    /// Configures an optional local LLM answer generator for Phase 3 synthesis (DOC-11, Issue #24).
    public func setAnswerGenerator(_ generator: (any DocsAnswerGenerator)?) {
        answerGenerator = generator
    }

    /// Configures the local Go snippet verifier (defaults to `DocsSnippetVerifier`).
    public func setSnippetVerifier(_ verifier: any DocsSnippetVerifying) {
        snippetVerifier = verifier
    }

    /// Controls whether editor file imports/context are included in Phase 3 answer generation (Issue #24).
    public func setIncludeEditorContextInGeneration(_ include: Bool) {
        includeEditorContextInGeneration = include
    }

    public func hasAnswerGenerator() -> Bool {
        answerGenerator != nil
    }

    /// Executes the fixed offline retrieval pipeline (§7.3) with cancellation checkpoints (M-4).
    /// Set `includeSynthesis` to `false` to return Phase 2 cards immediately and run `synthesizeAnswer(for:editorContext:)` asynchronously (Y-3).
    public func search(
        query rawQuery: String,
        projectRoot: URL? = nil,
        explicitVersionOverride: GoVersion? = nil,
        editorContext: DocsEditorContext? = nil,
        includeSynthesis: Bool = true,
        moduleCacheRoot: URL? = nil,
        toolchainVersionProvider: (@Sendable () -> GoVersion?)? = nil
    ) async throws -> DocsAnswer {
        try Task.checkCancellation()
        let trimmedQuery = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let detectedLang = DocsLanguage.detect(in: trimmedQuery)

        // DOC-1: opt-in check
        guard enabled else {
            let plan = DocsQueryRouter.route(rawQuery, conceptRules: conceptRulesOverride ?? BundledGoCorpus.defaultConceptRules)
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

        guard !trimmedQuery.isEmpty else {
            let msg = detectedLang == .japanese
                ? "調べたい内容（例: 「ファイルを1行ずつ読みたい」「for ループの書き方」「json.Encoder」）を入力してください。"
                : "Enter a Go question or symbol (e.g. \"read file line by line\", \"json.Encoder\")."
            return DocsAnswer(
                query: "",
                status: .notFound,
                language: detectedLang,
                intent: .needsReverseLookup,
                conclusion: msg
            )
        }

        // Step 2: Resolve target Go version asynchronously (FR-2, S-2: never blocks a thread with semaphore wait).
        let resolved: ResolvedGoVersion
        if let override = explicitVersionOverride {
            resolved = ResolvedGoVersion(version: override, source: .manualOverride)
        } else if let detected = await GoVersionResolver.resolveAsync(projectRoot: projectRoot, toolchainVersionProvider: toolchainVersionProvider) {
            resolved = detected
        } else {
            let fallbackVer = GoVersion(parsing: BundledGoCorpus.defaultVersion) ?? GoVersion(major: 1, minor: 23)
            resolved = ResolvedGoVersion(version: fallbackVer, source: .bundledDefault)
        }

        try Task.checkCancellation()
        let targetVer = resolved.version
        let packKey = targetVer.minorKey

        // Step 1 (data-driven routing): load global + per-pack concept rules (R-1, S-3).
        let activeRules: [DocsConceptRule]
        if let overrideRules = conceptRulesOverride {
            let packRules = await packManager.loadPackConceptRules(forGoVersion: packKey)
            activeRules = packRules.isEmpty ? overrideRules : (overrideRules + packRules)
        } else {
            activeRules = await packManager.loadConceptRules(forGoVersion: packKey)
        }
        let plan = DocsQueryRouter.route(rawQuery, conceptRules: activeRules)

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

        // Step 2b (Issue #27, DOC-12): Resolve active project dependencies from go.mod/go.work
        // and open ONLY dependency packs strictly matching exact (modulePath, version).
        var activeDepPacks: [(dep: GoModuleDependency, manifest: DocsDependencyPackManifest, index: DocsIndex)] = []
        var depSummary: DocsDependencySearchSummary?
        if let projectRoot {
            let resolvedDeps = GoModuleResolver.resolveDependencies(
                projectRoot: projectRoot,
                moduleCacheRoot: moduleCacheRoot
            )
            if !resolvedDeps.isEmpty {
                var indexedKeys: [GoModuleKey] = []
                var unindexedCachedKeys: [GoModuleKey] = []
                var uncachedKeys: [GoModuleKey] = []
                for dep in resolvedDeps {
                    // U-3: Isolate corrupt dependency pack DBs so one damaged pack degrades to unindexed
                    // instead of aborting stdlib and remaining dependency lookup.
                    if let depManifest = await packManager.dependencyManifest(for: dep.packKey) {
                        do {
                            if let depIndex = try await packManager.openDependencyIndex(for: dep.packKey) {
                                activeDepPacks.append((dep, depManifest, depIndex))
                                indexedKeys.append(dep.packKey)
                                continue
                            }
                        } catch {
                            // Fall through to cached-unindexed / uncached degradation below.
                        }
                    }
                    if dep.isCached {
                        unindexedCachedKeys.append(dep.packKey)
                    } else {
                        uncachedKeys.append(dep.packKey)
                    }
                }
                depSummary = DocsDependencySearchSummary(
                    indexedModules: indexedKeys,
                    unindexedCachedModules: unindexedCachedKeys,
                    uncachedModules: uncachedKeys
                )
            }
        }
        defer {
            for pack in activeDepPacks {
                pack.index.close()
            }
        }

        // Step 2c (Issue #26, DOC-14a/b): Open optional version-independent golang/website snapshot pack.
        // Only searched after `packs/go<packKey>` is confirmed present (`NeverAnswersWithoutMatchingPack`).
        var activeWebsitePack: (manifest: DocsWebsitePackManifest, index: DocsIndex)?
        if let webManifest = await packManager.websiteManifest(),
           let webIndex = try? await packManager.openWebsiteIndex() {
            activeWebsitePack = (webManifest, webIndex)
        }
        defer {
            activeWebsitePack?.index.close()
        }

        // Step 3: Stage 1 hybrid candidate collection: deterministic -> FTS5 -> optional semantic (FR-9, §7.3, Issue #21, #27).
        struct Candidate {
            var chunk: DocsChunk
            var score: Double
            var origin: DocsMatchOrigin
            var lexicalMatched: Bool
            var lexicalRank: Int?
            var semanticRawScore: Double
            var semanticRank: Int?
            var hasSignalOverlap: Bool
        }
        var combined: [String: Candidate] = [:]

        func merge(_ hits: [DocsIndexHit], weight: Double) {
            for (rankIdx, hit) in hits.enumerated() {
                let weighted = hit.score * weight
                let isLexical = (hit.matchedBy == .deterministicExact || hit.matchedBy == .fts5)
                let semRaw = hit.matchedBy == .semantic ? hit.score : 0.0
                if var existing = combined[hit.chunk.stableID] {
                    existing.score += weighted
                    existing.lexicalMatched = existing.lexicalMatched || isLexical
                    if hit.matchedBy == .fts5 {
                        existing.lexicalRank = min(existing.lexicalRank ?? rankIdx, rankIdx)
                    }
                    if hit.matchedBy == .semantic {
                        existing.semanticRawScore = max(existing.semanticRawScore, semRaw)
                        existing.semanticRank = min(existing.semanticRank ?? rankIdx, rankIdx)
                    }
                    if hit.matchedBy == .deterministicExact {
                        existing.origin = .deterministicExact
                    }
                    combined[hit.chunk.stableID] = existing
                } else {
                    combined[hit.chunk.stableID] = Candidate(
                        chunk: hit.chunk,
                        score: weighted,
                        origin: hit.matchedBy,
                        lexicalMatched: isLexical,
                        lexicalRank: hit.matchedBy == .fts5 ? rankIdx : nil,
                        semanticRawScore: semRaw,
                        semanticRank: hit.matchedBy == .semantic ? rankIdx : nil,
                        hasSignalOverlap: false
                    )
                }
            }
        }

        // 3a. Deterministic lookup (FR-1, FR-9a, Issue #27)
        if let sym = plan.exactSymbolCandidate {
            let detHits = try index.deterministicSearch(symbolOrPackage: sym, limit: 10)
            merge(detHits, weight: 2.0)
            for depPack in activeDepPacks {
                // U-3: ignore corrupt dependency SQLite errors without failing stdlib search
                if let depDetHits = try? depPack.index.deterministicSearch(symbolOrPackage: sym, limit: 10) {
                    merge(depDetHits, weight: 2.0)
                }
            }
        }

        try Task.checkCancellation()

        // 3b. SQLite FTS5 full-text search (FR-9b, Issue #26, #27)
        if !plan.searchTerms.isEmpty {
            let ftsHits = try index.ftsSearch(terms: plan.searchTerms, limit: 20)
            merge(ftsHits, weight: 1.0)
            for depPack in activeDepPacks {
                if let depFtsHits = try? depPack.index.ftsSearch(terms: plan.searchTerms, limit: 12) {
                    merge(depFtsHits, weight: 1.0)
                }
            }
            if let webPack = activeWebsitePack,
               let webFtsHits = try? webPack.index.ftsSearch(terms: plan.searchTerms, limit: 12) {
                // Slightly below stdlib weight (0.9 vs 1.0) so exact stdlib matches retain priority.
                merge(webFtsHits, weight: 0.9)
            }
        }

        try Task.checkCancellation()

        // 3c. Optional semantic search ONLY when pack is Ready AND model matches (FR-27, FR-28, DOC-4, DOC-12, DOC-14c).
        // Any non-cancellation failure from the embedder or vector store degrades cleanly to Phase 1 FTS (V-4).
        var usedSemantic = false
        if let embedder = queryEmbedder {
            let stdSemanticReady = manifest.status == .ready
                && manifest.embeddingModelID == embedder.descriptor.id
                && manifest.embeddingModelVersion == embedder.descriptor.version
            let readyDepPacks = activeDepPacks.filter {
                $0.manifest.status == .ready
                    && $0.manifest.embeddingModelID == embedder.descriptor.id
                    && $0.manifest.embeddingModelVersion == embedder.descriptor.version
            }
            let webSemanticReady: Bool = {
                guard let webPack = activeWebsitePack else { return false }
                return webPack.manifest.status == .ready
                    && webPack.manifest.embeddingModelID == embedder.descriptor.id
                    && webPack.manifest.embeddingModelVersion == embedder.descriptor.version
            }()
            if stdSemanticReady || !readyDepPacks.isEmpty || webSemanticReady {
                do {
                    let qVec = try await embedder.embedQuery(plan.originalQuery)
                    try Task.checkCancellation()
                    if stdSemanticReady {
                        let semHits = try await index.semanticSearch(
                            queryVector: qVec,
                            model: embedder.descriptor,
                            sharedStore: packManager.sharedVectorStore,
                            minimumSimilarity: Self.minimumSemanticSimilarity,
                            limit: Self.retrievalPoolLimit
                        )
                        // Balanced weight so semantic assists recall without swamping deterministic/FTS precision (M-1).
                        merge(semHits, weight: 0.4)
                        usedSemantic = true
                    }
                    for depPack in readyDepPacks {
                        try Task.checkCancellation()
                        let depSemHits = try await depPack.index.semanticSearch(
                            queryVector: qVec,
                            model: embedder.descriptor,
                            sharedStore: packManager.sharedVectorStore,
                            minimumSimilarity: Self.minimumSemanticSimilarity,
                            limit: Self.retrievalPoolLimit
                        )
                        merge(depSemHits, weight: 0.4)
                        usedSemantic = true
                    }
                    if webSemanticReady, let webPack = activeWebsitePack {
                        try Task.checkCancellation()
                        let webSemHits = try await webPack.index.semanticSearch(
                            queryVector: qVec,
                            model: embedder.descriptor,
                            sharedStore: packManager.sharedVectorStore,
                            minimumSimilarity: Self.minimumSemanticSimilarity,
                            limit: Self.retrievalPoolLimit
                        )
                        merge(webSemHits, weight: 0.4)
                        usedSemantic = true
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    usedSemantic = false
                }
            }
        }

        let activeReranker = reranker

        // Step 3d: Anti-hallucination signal verification (FR-14, M-1, Issue #21).
        var candidates: [Candidate] = []
        candidates.reserveCapacity(combined.count)
        for var entry in combined.values {
            if entry.origin == .deterministicExact {
                entry.hasSignalOverlap = true
                candidates.append(entry)
                continue
            }
            let hay = (
                entry.chunk.title + " " +
                entry.chunk.packageName + " " +
                entry.chunk.symbol + " " +
                entry.chunk.summary + " " +
                entry.chunk.body + " " +
                entry.chunk.searchAliases.joined(separator: " ")
            ).lowercased()
            let hasSignalOverlap = !plan.requiredSignalTerms.isEmpty && plan.requiredSignalTerms.contains { hay.contains($0) }
            entry.hasSignalOverlap = hasSignalOverlap

            if entry.origin == .semantic && !entry.lexicalMatched {
                if activeReranker != nil {
                    // Stage 2 cross-encoder performs precision & anti-hallucination gating on cross-lingual candidates.
                    candidates.append(entry)
                } else {
                    // Phase 1 / reranker-disabled fallback: require signal overlap or calibrated high similarity.
                    if plan.intent == .existenceCheck {
                        if hasSignalOverlap { candidates.append(entry) }
                    } else if hasSignalOverlap || entry.semanticRawScore >= Self.highConfidenceSemanticScore {
                        candidates.append(entry)
                    }
                }
                continue
            }

            if !plan.requiredSignalTerms.isEmpty && hasSignalOverlap {
                candidates.append(entry)
            }
        }

        // Step 4: Version gating BEFORE Stage 2 reranking & final ranking (FR-10, UC-1, DOC-2, DOC-10).
        struct ScoredCandidate {
            var candidate: Candidate
            var intentBonus: Double
            var stage1Score: Double
            var finalScore: Double
        }

        let lowerSearchTerms = plan.searchTerms.map { $0.lowercased() }.filter { $0.count >= 2 }
        var allowedEntries: [ScoredCandidate] = []
        var newerNotes: [DocsNewerVersionNote] = []

        for entry in candidates {
            switch GoVersionGate.evaluate(since: entry.chunk.since, target: targetVer) {
            case .allowed:
                var intentBonus = 0.0
                switch plan.intent {
                case .syntaxHowTo:
                    if entry.chunk.source == .spec { intentBonus += 18.0 }
                    else if entry.chunk.source == .guide { intentBonus += 14.0 }
                case .exactSymbol, .existenceCheck, .needsReverseLookup:
                    // U-1: Stdlib retains slight priority over dependency chunks on ambiguous ties.
                    if entry.chunk.source == .stdlib {
                        if entry.chunk.kind == .example && plan.intent != .needsReverseLookup {
                            intentBonus += 7.0
                        } else {
                            intentBonus += 10.0
                        }
                    } else if entry.chunk.source == .dependency {
                        if entry.chunk.kind == .example && plan.intent != .needsReverseLookup {
                            intentBonus += 5.0
                        } else {
                            intentBonus += 8.0
                        }
                    }
                    if plan.intent == .needsReverseLookup && entry.chunk.kind != .package {
                        intentBonus += 3.0
                        if entry.chunk.kind != .example && !entry.chunk.symbol.contains(".") {
                            intentBonus += 2.0
                        }
                    }
                    if entry.lexicalMatched {
                        let symLower = entry.chunk.symbol.lowercased()
                        let pkgLower = entry.chunk.packageName.lowercased()
                        let shortPkg = DocsIndex.shortPackageName(for: pkgLower)
                        if !symLower.isEmpty && lowerSearchTerms.contains(symLower) {
                            intentBonus += 12.0
                        }
                        if !pkgLower.isEmpty && (lowerSearchTerms.contains(pkgLower) || lowerSearchTerms.contains(shortPkg)) {
                            intentBonus += 4.0
                        }
                    }
                case .releaseSince:
                    if entry.chunk.source == .release { intentBonus += 20.0 }
                case .idiomOrWhy:
                    if entry.chunk.source == .guide || entry.chunk.source == .spec { intentBonus += 12.0 }
                }
                // FR-3: weak signal from currently edited file's imports (never leaves machine).
                if let ctx = editorContext, !entry.chunk.packageName.isEmpty,
                   ctx.importedPackages.contains(entry.chunk.packageName) {
                    intentBonus += 1.5
                }
                let stage1 = entry.score + intentBonus
                allowedEntries.append(ScoredCandidate(
                    candidate: entry,
                    intentBonus: intentBonus,
                    stage1Score: stage1,
                    finalScore: stage1
                ))
            case .requiresNewer(let since):
                newerNotes.append(DocsNewerVersionNote(
                    title: entry.chunk.title,
                    since: since,
                    citation: entry.chunk.citationLabel
                ))
            }
        }

        // Default Stage 1 ordering (used directly when reranker is absent or fails).
        // U-1: Tie-break stdlib/official sources ahead of dependency chunks before comparing stableID.
        allowedEntries.sort {
            if abs($0.stage1Score - $1.stage1Score) > 0.001 { return $0.stage1Score > $1.stage1Score }
            let p0 = $0.candidate.chunk.source == .dependency ? 1 : 0
            let p1 = $1.candidate.chunk.source == .dependency ? 1 : 0
            if p0 != p1 { return p0 < p1 }
            return $0.candidate.chunk.stableID < $1.candidate.chunk.stableID
        }

        // Step 5: Stage 2 optional local cross-encoder reranking (Issue #21, FR-11, DOC-10).
        var usedReranker = false
        if let activeReranker, !allowedEntries.isEmpty {
            // Build balanced top-N union pool: deterministic hits first, then top FTS hits and top semantic hits
            // so neither high-BM25 FTS nor semantic retrieval starves the other.
            let limit = Self.retrievalPoolLimit
            var pool: [ScoredCandidate] = []
            pool.reserveCapacity(min(limit, allowedEntries.count))
            var seenIDs = Set<String>()

            func take(_ entry: ScoredCandidate) {
                guard pool.count < limit else { return }
                if seenIDs.insert(entry.candidate.chunk.stableID).inserted {
                    pool.append(entry)
                }
            }

            for entry in allowedEntries where entry.candidate.origin == .deterministicExact {
                take(entry)
            }
            let ftsSorted = allowedEntries
                .filter { $0.candidate.lexicalRank != nil }
                .sorted { ($0.candidate.lexicalRank ?? Int.max) < ($1.candidate.lexicalRank ?? Int.max) }
            let ftsQuota = min(limit / 2, ftsSorted.count)
            for entry in ftsSorted.prefix(ftsQuota) {
                take(entry)
            }
            let semSorted = allowedEntries
                .filter { $0.candidate.semanticRank != nil }
                .sorted { ($0.candidate.semanticRank ?? Int.max) < ($1.candidate.semanticRank ?? Int.max) }
            for entry in semSorted {
                take(entry)
            }
            for entry in allowedEntries {
                take(entry)
            }

            let documents = pool.map(\.candidate.chunk.rerankDocumentText)

            try Task.checkCancellation()
            let rerankOutcome: [DocsRerankerResult]?
            do {
                rerankOutcome = try await activeReranker.rerank(
                    query: plan.originalQuery,
                    documents: documents,
                    topN: documents.count
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                rerankOutcome = nil
            }
            if let rerankResults = rerankOutcome, !rerankResults.isEmpty {
                try Task.checkCancellation()
                var rrScoreByIndex: [Int: Double] = [:]
                rrScoreByIndex.reserveCapacity(rerankResults.count)
                for res in rerankResults {
                    rrScoreByIndex[res.index] = res.score
                }

                var rerankedEntries: [ScoredCandidate] = []
                rerankedEntries.reserveCapacity(pool.count)

                for (idx, var item) in pool.enumerated() {
                    let rr = rrScoreByIndex[idx] ?? 0.0
                    let cand = item.candidate
                    let isDet = (cand.origin == .deterministicExact)

                    // Anti-hallucination gate for semantic-only candidates (Issue #21).
                    if cand.origin == .semantic && !cand.lexicalMatched {
                        let threshold = (plan.intent == .existenceCheck)
                            ? Self.minimumExistenceRerankScore
                            : Self.minimumRerankScore
                        if rr < threshold {
                            continue
                        }
                    }

                    let lexicalStrength = Self.lexicalMatchStrength(
                        chunk: cand.chunk,
                        lexicalMatched: cand.lexicalMatched,
                        lowerTerms: lowerSearchTerms,
                        intent: plan.intent
                    )

                    // Drop noisy body-only FTS hits (e.g. a single incidental word match) when cross-encoder rejects them.
                    if !isDet && lexicalStrength == 0 && rr < Self.minimumRerankScore {
                        continue
                    }

                    if isDet {
                        // Explicit symbol query stays #1 while reranker refines sibling ordering.
                        item.finalScore = 220.0 + rr * 50.0 + item.stage1Score * 0.2
                    } else {
                        let ftsRankBonus: Double
                        if let rank = cand.lexicalRank {
                            ftsRankBonus = 8.0 / Double(rank + 1)
                        } else {
                            ftsRankBonus = 0.0
                        }
                        let lexicalBonus: Double
                        if lexicalStrength >= 2 {
                            // Exact symbol or guide/spec title match (e.g. bufio.Scanner, json.Decoder, json.Encoder).
                            // Equal across siblings of the same family so cross-encoder breaks ties decisively.
                            lexicalBonus = 50.0 + ftsRankBonus
                        } else if lexicalStrength == 1 {
                            // Package-level or method-prefix lexical match.
                            lexicalBonus = 38.0 + ftsRankBonus
                        } else if cand.lexicalMatched {
                            lexicalBonus = ftsRankBonus
                        } else {
                            lexicalBonus = 0.0
                        }
                        item.finalScore = rr * 100.0 + lexicalBonus + item.intentBonus
                    }
                    rerankedEntries.append(item)
                }

                rerankedEntries.sort {
                    if abs($0.finalScore - $1.finalScore) > 0.001 { return $0.finalScore > $1.finalScore }
                    let p0 = $0.candidate.chunk.source == .dependency ? 1 : 0
                    let p1 = $1.candidate.chunk.source == .dependency ? 1 : 0
                    if p0 != p1 { return p0 < p1 }
                    return $0.candidate.chunk.stableID < $1.candidate.chunk.stableID
                }
                allowedEntries = rerankedEntries
                usedReranker = !allowedEntries.isEmpty
            } else {
                // Reranker unavailable or failed: fall back cleanly to Phase 1 anti-hallucination gating.
                allowedEntries = allowedEntries.filter { item in
                    let cand = item.candidate
                    if cand.origin == .semantic && !cand.lexicalMatched {
                        if plan.intent == .existenceCheck { return cand.hasSignalOverlap }
                        return cand.hasSignalOverlap || cand.semanticRawScore >= Self.highConfidenceSemanticScore
                    }
                    return true
                }
            }
        }

        let searchMode: DocsSearchMode
        switch (usedSemantic, usedReranker) {
        case (true, true): searchMode = .hybridReranked
        case (true, false): searchMode = .hybridSemantic
        case (false, true): searchMode = .ftsReranked
        case (false, false): searchMode = .ftsOnly
        }

        newerNotes.sort { ($0.since, $0.title) < ($1.since, $1.title) }

        var scopeParts = ["Go \(packKey) pack (\(manifest.chunkCount) chunks: Language Spec, Official Guides, Standard Library)"]
        if let webPack = activeWebsitePack {
            scopeParts.append("Go Website (\(webPack.manifest.chunkCount) chunks, snapshot \(webPack.manifest.snapshotDate))")
        }
        if let depSummary, depSummary.hasAnyDependency {
            var depParts: [String] = []
            if !depSummary.indexedModules.isEmpty {
                let depChunks = activeDepPacks.reduce(0) { $0 + $1.manifest.chunkCount }
                depParts.append("\(depSummary.indexedModules.count) indexed (\(depChunks) chunks)")
            }
            if !depSummary.unindexedCachedModules.isEmpty {
                depParts.append("\(depSummary.unindexedCachedModules.count) cached/unindexed")
            }
            if !depSummary.uncachedModules.isEmpty {
                let names = depSummary.uncachedModules.prefix(3).map(\.displayID).joined(separator: ", ")
                let more = depSummary.uncachedModules.count > 3 ? " +\(depSummary.uncachedModules.count - 3)" : ""
                depParts.append("\(depSummary.uncachedModules.count) uncached: \(names)\(more)")
            }
            scopeParts.append("Dependencies [\(depParts.joined(separator: ", "))]")
        }
        let scopeText = scopeParts.joined(separator: " + ")

        // Step 6: Honest Not Found when zero grounded, version-gated candidates match (FR-12, FR-14, UX-4).
        guard !allowedEntries.isEmpty else {
            let msg: String
            if plan.language == .japanese {
                if let depSummary, !depSummary.uncachedModules.isEmpty {
                    let names = depSummary.uncachedModules.prefix(3).map(\.displayID).joined(separator: ", ")
                    msg = "標準ライブラリ・導入済み依存ドキュメント（Go \(packKey)）には該当する機能が見つかりませんでした（module cache 未取得の依存あり: \(names)）。根拠のないシンボルや別バージョンは提示しません。"
                } else {
                    msg = "標準ライブラリ・公式ドキュメント（Go \(packKey)）には該当する機能が見つかりませんでした。根拠のないシンボルは提示しません。"
                }
            } else {
                if let depSummary, !depSummary.uncachedModules.isEmpty {
                    let names = depSummary.uncachedModules.prefix(3).map(\.displayID).joined(separator: ", ")
                    msg = "No matching symbol or guide was found in the Go \(packKey) offline documentation pack (uncached dependencies not substituted: \(names))."
                } else {
                    msg = "No matching symbol or guide was found in the Go \(packKey) offline documentation pack."
                }
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
                searchMode: usedSemantic ? .hybridSemantic : .ftsOnly,
                usedLLM: false,
                usedReranker: false,
                searchedScope: scopeText,
                dependencySummary: depSummary
            )
        }

        // UX-3: cap to maximum 3 grounded cards.
        let top = allowedEntries.prefix(Self.maxCards)
        let cards: [DocsAnswerCard] = top.map { entry in
            let c = entry.candidate.chunk
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
                provenance: c.provenance,
                packageName: c.packageName,
                symbol: c.symbol,
                anchor: c.anchor,
                goVersion: packKey,
                since: c.since,
                canInsert: canInsert,
                matchedBy: entry.candidate.origin,
                modulePath: c.modulePath,
                moduleVersion: c.moduleVersion,
                license: c.license,
                sourceURL: c.sourceURL,
                snapshotDate: c.snapshotDate
            )
        }

        let conclusion = buildConclusion(plan: plan, cards: cards, targetVersion: targetVer)
        let topEntries = Array(top)
        let generated: DocsGeneratedAnswer?
        if includeSynthesis {
            generated = await synthesizeAnswerIfNeeded(
                plan: plan,
                topEntries: topEntries.map(\.candidate.chunk),
                cards: cards,
                newerNotes: newerNotes,
                targetVersion: targetVer,
                editorContext: includeEditorContextInGeneration ? editorContext : nil
            )
        } else {
            generated = nil
        }

        return DocsAnswer(
            query: plan.originalQuery,
            status: .found,
            language: plan.language,
            intent: plan.intent,
            conclusion: conclusion,
            cards: cards,
            newerVersionNotes: Array(newerNotes.prefix(3)),
            generatedAnswer: generated,
            targetVersion: targetVer,
            versionSource: resolved.source,
            searchMode: searchMode,
            usedLLM: generated != nil,
            usedReranker: usedReranker,
            searchedScope: scopeText,
            dependencySummary: depSummary
        )
    }

    /// Runs Phase 3 synthesis asynchronously for an already-rendered Phase 2 `DocsAnswer` (Y-3).
    public func synthesizeAnswer(
        for answer: DocsAnswer,
        editorContext: DocsEditorContext? = nil
    ) async -> DocsGeneratedAnswer? {
        guard enabled, answer.status == .found, let targetVer = answer.targetVersion, !answer.cards.isEmpty else {
            return nil
        }
        guard Self.shouldSynthesize(intent: answer.intent, cards: answer.cards) else { return nil }
        let evidence = answer.cards.map { card in
            DocsAnswerEvidence(
                citation: card.citation,
                title: card.title,
                packageName: card.packageName,
                symbol: card.symbol,
                signature: card.signature,
                summary: card.reason,
                example: card.example,
                body: card.reason + "\n" + (card.example ?? ""),
                since: card.since,
                isDependency: card.sourceKind == .dependency,
                moduleLabel: (card.modulePath != nil && card.moduleVersion != nil) ? "\(card.modulePath!)@\(card.moduleVersion!)" : nil
            )
        }
        return await runSynthesis(
            query: answer.query,
            language: answer.language,
            evidence: evidence,
            newerNotes: answer.newerVersionNotes,
            targetVersion: targetVer,
            editorContext: includeEditorContextInGeneration ? editorContext : nil
        )
    }

    public static func shouldSynthesize(intent: DocsQueryIntent, cards: [DocsAnswerCard]) -> Bool {
        guard !cards.isEmpty else { return false }
        switch intent {
        case .exactSymbol, .existenceCheck:
            return false
        case .needsReverseLookup, .syntaxHowTo, .idiomOrWhy, .releaseSince:
            return true
        }
    }

    private func synthesizeAnswerIfNeeded(
        plan: DocsRoutingPlan,
        topEntries: [DocsChunk],
        cards: [DocsAnswerCard],
        newerNotes: [DocsNewerVersionNote],
        targetVersion: GoVersion,
        editorContext: DocsEditorContext?
    ) async -> DocsGeneratedAnswer? {
        guard Self.shouldSynthesize(intent: plan.intent, cards: cards) else { return nil }
        let evidence = topEntries.map { chunk in
            DocsAnswerEvidence(
                citation: chunk.citationLabel,
                title: chunk.title,
                packageName: chunk.packageName,
                symbol: chunk.symbol,
                signature: chunk.signature,
                summary: chunk.summary,
                example: chunk.example,
                body: chunk.body,
                since: chunk.since,
                isDependency: chunk.source == .dependency,
                moduleLabel: (chunk.modulePath != nil && chunk.moduleVersion != nil) ? "\(chunk.modulePath!)@\(chunk.moduleVersion!)" : nil
            )
        }
        return await runSynthesis(
            query: plan.originalQuery,
            language: plan.language,
            evidence: evidence,
            newerNotes: newerNotes,
            targetVersion: targetVersion,
            editorContext: editorContext
        )
    }

    private func runSynthesis(
        query: String,
        language: DocsLanguage,
        evidence: [DocsAnswerEvidence],
        newerNotes: [DocsNewerVersionNote],
        targetVersion: GoVersion,
        editorContext: DocsEditorContext?
    ) async -> DocsGeneratedAnswer? {
        guard let generator = answerGenerator, !evidence.isEmpty else { return nil }

        let req = DocsAnswerGenerationRequest(
            query: query,
            language: language,
            targetVersion: targetVersion,
            evidence: evidence,
            editorContext: editorContext
        )

        let rawOutput: DocsAnswerGenerationOutput?
        do {
            rawOutput = try await generator.generate(request: req)
        } catch {
            return nil
        }
        guard let output = rawOutput, !output.insufficientEvidence else { return nil }

        // Y-1: Strict citation matching (exact citation label or exact qualified symbol / title).
        let matchedCitations = Self.matchGroundedCitations(output.citedLabels, against: evidence)
        guard !matchedCitations.isEmpty else {
            return nil
        }

        // Y-2: Grounding check with word boundaries.
        // When a snippet is present, verify the snippet references cited symbols/packages
        // (so natural Japanese explanations without Latin identifiers are not falsely rejected).
        // When no snippet is present (explanation-only), verify the explanation itself.
        if let snippet = output.snippet, !snippet.isEmpty {
            if !Self.verifySnippetGroundedInEvidence(snippet: snippet, evidence: evidence, matchedCitations: matchedCitations) {
                return nil
            }
        } else {
            if !Self.verifyExplanationGroundedInEvidence(explanation: output.explanation, evidence: evidence, matchedCitations: matchedCitations) {
                return nil
            }
        }

        // Y-4 & U-2: Version gate and external-dependency check on generated output & snippet (DOC-2, DOC-11, Issue #27).
        let externalDepEvidence = evidence.filter(\.isDependency)
        let knownExternalPackageIdents = Set(externalDepEvidence.compactMap { ev -> String? in
            guard !ev.packageName.isEmpty else { return nil }
            return DocsIndex.shortPackageName(for: ev.packageName)
        })

        let verification: DocsSnippetVerificationStatus
        if let reqVer = output.requiredNewerGoVersion, reqVer > targetVersion {
            verification = .newerVersionRequired(since: reqVer)
        } else if let snippet = output.snippet, !snippet.isEmpty {
            if let newerHit = Self.detectNewerAPIMention(in: snippet, newerNotes: newerNotes, targetVersion: targetVersion) {
                verification = .newerVersionRequired(since: newerHit)
            } else {
                // Only short-circuit to `.unverified` when the snippet itself references a dependency package
                // (so a snippet using only stdlib even when a dependency was cited still gets real `go build` verification).
                let referencedDepLabels = externalDepEvidence
                    .filter { ev in
                        let pkg = ev.packageName
                        guard !pkg.isEmpty else { return false }
                        let shortPkg = DocsIndex.shortPackageName(for: pkg)
                        return snippet.contains("\"\(pkg)\"")
                            || snippet.range(of: "(?<![A-Za-z0-9_])\(NSRegularExpression.escapedPattern(for: shortPkg))\\.", options: .regularExpression) != nil
                    }
                    .compactMap { $0.moduleLabel ?? ($0.packageName.isEmpty ? nil : $0.packageName) }

                if !referencedDepLabels.isEmpty {
                    let label = Array(Set(referencedDepLabels)).sorted().prefix(2).joined(separator: ", ")
                    verification = .unverified(reason: "外部依存パッケージ（\(label)）を含むため単体モジュール検証の対象外です")
                } else {
                    verification = await snippetVerifier.verify(
                        snippet: snippet,
                        targetVersion: targetVersion,
                        knownExternalPackageIdents: knownExternalPackageIdents
                    )
                }
            }
        } else {
            verification = .unverified(reason: "スニペットなし")
        }

        return DocsGeneratedAnswer(
            explanation: output.explanation,
            snippet: output.snippet,
            citations: matchedCitations,
            targetVersion: targetVersion,
            verification: verification,
            modelID: generator.modelID
        )
    }

    /// Y-1: Strict citation matching without loose bidirectional substring matches.
    static func matchGroundedCitations(_ cited: [String], against evidence: [DocsAnswerEvidence]) -> [String] {
        var matched: [String] = []
        var seen = Set<String>()
        for raw in cited {
            let trimmed = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "`\"'"))
            guard !trimmed.isEmpty else { continue }
            let hit = evidence.first { ev in
                if ev.citation.caseInsensitiveCompare(trimmed) == .orderedSame {
                    return true
                }
                if !ev.title.isEmpty && ev.title.caseInsensitiveCompare(trimmed) == .orderedSame {
                    return true
                }
                if !ev.packageName.isEmpty && !ev.symbol.isEmpty {
                    let qualified = "\(ev.packageName).\(ev.symbol)"
                    if qualified.caseInsensitiveCompare(trimmed) == .orderedSame {
                        return true
                    }
                }
                return false
            }
            if let hit, seen.insert(hit.citation).inserted {
                matched.append(hit.citation)
            }
        }
        return matched
    }

    /// Word-boundary identifier check (`(?<![A-Za-z0-9_])token(?![A-Za-z0-9_])`) to prevent substring collisions
    /// such as `Set` matching `Settings`, `io` matching `position`, or `min(` matching `admin(`.
    static func containsWordToken(_ token: String, in text: String, caseInsensitive: Bool = false) -> Bool {
        guard !token.isEmpty else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: token)
        let pattern = "(?<![A-Za-z0-9_])\(escaped)(?![A-Za-z0-9_])"
        var opts: String.CompareOptions = [.regularExpression]
        if caseInsensitive { opts.insert(.caseInsensitive) }
        return text.range(of: pattern, options: opts) != nil
    }

    /// Y-2: Verifies that an explanation-only answer mentions at least one cited symbol or package (word-boundary matched).
    static func verifyExplanationGroundedInEvidence(
        explanation: String,
        evidence: [DocsAnswerEvidence],
        matchedCitations: [String]
    ) -> Bool {
        let citedEvidence = evidence.filter { matchedCitations.contains($0.citation) }
        guard !citedEvidence.isEmpty else { return false }
        for ev in citedEvidence {
            if ev.symbol.count >= 3 && containsWordToken(ev.symbol, in: explanation, caseInsensitive: true) { return true }
            let symTail = ev.symbol.split(separator: ".").last.map(String.init) ?? ""
            if symTail.count >= 3 && containsWordToken(symTail, in: explanation, caseInsensitive: true) { return true }
            if !ev.packageName.isEmpty {
                let pkgTail = ev.packageName.split(separator: "/").last.map(String.init) ?? ev.packageName
                if containsWordToken(ev.packageName, in: explanation, caseInsensitive: true)
                    || containsWordToken(pkgTail, in: explanation, caseInsensitive: true) {
                    return true
                }
            }
            if !ev.title.isEmpty && containsWordToken(ev.title, in: explanation, caseInsensitive: true) {
                return true
            }
        }
        return false
    }

    /// Y-2: Verifies that a generated snippet references symbols/packages from the cited evidence using word boundaries.
    static func verifySnippetGroundedInEvidence(
        snippet: String,
        evidence: [DocsAnswerEvidence],
        matchedCitations: [String]
    ) -> Bool {
        let citedEvidence = evidence.filter { matchedCitations.contains($0.citation) }
        guard !citedEvidence.isEmpty else { return false }
        for ev in citedEvidence {
            let symTail = ev.symbol.split(separator: ".").last.map(String.init) ?? ev.symbol
            let hasPackage = !ev.packageName.isEmpty
            let pkgTail = ev.packageName.split(separator: "/").last.map(String.init) ?? ev.packageName
            let mentionsPkg = hasPackage && (
                snippet.range(of: "(?<![A-Za-z0-9_])\(NSRegularExpression.escapedPattern(for: pkgTail))\\.", options: .regularExpression) != nil
                || snippet.contains("\"\(ev.packageName)\"")
            )

            if !ev.symbol.isEmpty && ev.symbol.count >= 3 && (containsWordToken(ev.symbol, in: snippet) || containsWordToken("New" + ev.symbol, in: snippet)) {
                return true
            }
            if symTail.count >= 3 && (containsWordToken(symTail, in: snippet) || containsWordToken("New" + symTail, in: snippet)) {
                return true
            }
            if mentionsPkg && (symTail.isEmpty || containsWordToken(symTail, in: snippet) || containsWordToken("New" + symTail, in: snippet)) {
                return true
            }
        }
        return false
    }

    /// Y-4: Checks both gated-out search notes and known stdlib `since` entries above `targetVersion` with word boundaries.
    static func detectNewerAPIMention(
        in snippet: String,
        newerNotes: [DocsNewerVersionNote],
        targetVersion: GoVersion
    ) -> GoVersion? {
        for note in newerNotes where note.since > targetVersion {
            let symbolTail = note.title.split(separator: ".").last.map(String.init) ?? note.title
            if symbolTail.count >= 4 && containsWordToken(symbolTail, in: snippet) {
                return note.since
            }
        }
        let knownNewerStdlib: [(pattern: String, since: GoVersion)] = [
            (#""slices""#, GoVersion(major: 1, minor: 21)),
            (#""maps""#, GoVersion(major: 1, minor: 21)),
            (#""cmp""#, GoVersion(major: 1, minor: 21)),
            (#""log/slog""#, GoVersion(major: 1, minor: 21)),
            (#"(?<![A-Za-z0-9_])sync\.OnceFunc\b"#, GoVersion(major: 1, minor: 21)),
            (#"(?<![A-Za-z0-9_])sync\.OnceValue\b"#, GoVersion(major: 1, minor: 21)),
            (#"(?<![A-Za-z0-9_])context\.AfterFunc\b"#, GoVersion(major: 1, minor: 21)),
            (#"(?<![A-Za-z0-9_])context\.WithDeadlineCause\b"#, GoVersion(major: 1, minor: 21)),
            (#"(?<![A-Za-z0-9_.])min\("#, GoVersion(major: 1, minor: 21)),
            (#"(?<![A-Za-z0-9_.])max\("#, GoVersion(major: 1, minor: 21)),
            (#"(?<![A-Za-z0-9_.])clear\("#, GoVersion(major: 1, minor: 21)),
            (#""math/rand/v2""#, GoVersion(major: 1, minor: 22)),
            (#"(?<![A-Za-z0-9_])slices\.Concat\b"#, GoVersion(major: 1, minor: 22)),
            (#"(?<![A-Za-z0-9_])cmp\.Or\b"#, GoVersion(major: 1, minor: 22)),
            (#""iter""#, GoVersion(major: 1, minor: 23)),
            (#""unique""#, GoVersion(major: 1, minor: 23)),
            (#"(?<![A-Za-z0-9_])slices\.Collect\b"#, GoVersion(major: 1, minor: 23)),
            (#"(?<![A-Za-z0-9_])maps\.Keys\b"#, GoVersion(major: 1, minor: 23)),
            (#""weak""#, GoVersion(major: 1, minor: 24))
        ]
        for entry in knownNewerStdlib where entry.since > targetVersion {
            if snippet.range(of: entry.pattern, options: .regularExpression) != nil {
                return entry.since
            }
        }
        return nil
    }

    /// Returns 2 for an exact symbol or spec/guide title match, 1 for a package or method-prefix match, 0 otherwise.
    private static func lexicalMatchStrength(
        chunk: DocsChunk,
        lexicalMatched: Bool,
        lowerTerms: [String],
        intent: DocsQueryIntent = .needsReverseLookup
    ) -> Int {
        guard lexicalMatched, !lowerTerms.isEmpty else { return 0 }
        let sym = chunk.symbol.lowercased()
        let pkg = chunk.packageName.lowercased()
        let shortPkg = DocsIndex.shortPackageName(for: pkg)
        if chunk.source == .stdlib || chunk.source == .dependency {
            if !sym.isEmpty && lowerTerms.contains(sym) { return 2 }
            if lowerTerms.contains(where: { (!sym.isEmpty && sym.hasPrefix($0 + ".")) || pkg == $0 || shortPkg == $0 }) {
                return 1
            }
            return 0
        }
        let title = chunk.title.lowercased()
        if lowerTerms.contains(where: { (!sym.isEmpty && sym.contains($0)) || title.contains($0) }) {
            // Website snapshot prose complements stdlib without displacing exact stdlib symbols on symbol/existence/reverse lookups.
            if chunk.provenance == .officialWebsiteSnapshot && intent != .syntaxHowTo && intent != .idiomOrWhy {
                return 1
            }
            return 2
        }
        return 0
    }

    private func buildConclusion(
        plan: DocsRoutingPlan,
        cards: [DocsAnswerCard],
        targetVersion: GoVersion
    ) -> String {
        guard let top = cards.first else { return "" }
        let verLabel = targetVersion.description
        let isDep = top.sourceKind == .dependency
        let depLabel: String? = (isDep && top.modulePath != nil && top.moduleVersion != nil)
            ? "\(top.modulePath!)@\(top.moduleVersion!)"
            : nil
        switch (plan.intent, plan.language) {
        case (.existenceCheck, .japanese):
            let name = top.packageName.isEmpty ? top.symbol : (top.symbol.isEmpty ? top.packageName : "\(top.packageName).\(top.symbol)")
            if let depLabel {
                return "あります（\(depLabel)）: `\(name)` が依存パッケージで利用できます。"
            }
            return "あります（\(verLabel)）: `\(name)` が標準ライブラリで利用できます。"
        case (.existenceCheck, .english):
            let name = top.packageName.isEmpty ? top.symbol : (top.symbol.isEmpty ? top.packageName : "\(top.packageName).\(top.symbol)")
            if let depLabel {
                return "Yes (\(depLabel)): `\(name)` is available in project dependencies."
            }
            return "Yes (\(verLabel)): `\(name)` is available in the Go standard library."
        case (.syntaxHowTo, .japanese):
            return "\(verLabel) で使える書き方と指針（\(cards.count)件）:"
        case (.syntaxHowTo, .english):
            return "Syntax and guidance for \(verLabel) (\(cards.count) match\(cards.count == 1 ? "" : "es")):"
        case (.exactSymbol, .japanese):
            if depLabel != nil {
                return "依存パッケージのリファレンス（\(top.citation)）:"
            }
            return "\(verLabel) の公式リファレンス（\(top.citation)）:"
        case (.exactSymbol, .english):
            if depLabel != nil {
                return "Dependency reference (\(top.citation)):"
            }
            return "Official reference for \(verLabel) (\(top.citation)):"
        case (_, .japanese):
            let name = top.packageName.isEmpty ? top.title : (top.symbol.isEmpty ? top.packageName : "\(top.packageName).\(top.symbol)")
            let scopeTag = depLabel ?? verLabel
            return "あります（\(scopeTag)）: 第一候補は `\(name)` です（候補 \(cards.count)件）。"
        case (_, .english):
            let name = top.packageName.isEmpty ? top.title : (top.symbol.isEmpty ? top.packageName : "\(top.packageName).\(top.symbol)")
            let scopeTag = depLabel ?? verLabel
            return "Found for \(scopeTag): top match `\(name)` (\(cards.count) result\(cards.count == 1 ? "" : "s"))."
        }
    }
}
