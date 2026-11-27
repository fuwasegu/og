import Foundation

// MARK: - Error-driven Docs Lookup Models (Issue #28, DOC-13, DES-ERR-1..4)

/// Origin of a diagnostic or compiler error signal.
public enum DocsErrorSource: String, Sendable, Hashable, Codable {
    case gopls
    case build
}

/// Stable identity for a diagnostic within a file so dismissals remain sticky while it persists
/// and clear when the diagnostic disappears (DOC-13b, DOC-13c).
public struct DocsErrorDiagnosticKey: Sendable, Hashable, Codable {
    public var fileURI: String
    public var source: DocsErrorSource
    /// 0-based line number.
    public var line: Int
    /// 0-based UTF-16 column number.
    public var column: Int
    public var message: String

    public init(
        fileURI: String,
        source: DocsErrorSource,
        line: Int,
        column: Int,
        message: String
    ) {
        self.fileURI = fileURI
        self.source = source
        self.line = line
        self.column = column
        self.message = message
    }
}

/// Normalized diagnostic from either `gopls` (`publishDiagnostics`) or `go build`/`go vet` output.
public struct DocsErrorDiagnostic: Sendable, Hashable {
    public var key: DocsErrorDiagnosticKey
    /// Document version this diagnostic belongs to (`0` for build-source diagnostics).
    public var docVersion: Int
    public var severity: LSPSeverity
    public var range: LSPRange
    public var diagnosticSource: String?

    public init(
        fileURI: String,
        source: DocsErrorSource,
        docVersion: Int,
        range: LSPRange,
        severity: LSPSeverity = .error,
        message: String,
        diagnosticSource: String? = nil
    ) {
        self.key = DocsErrorDiagnosticKey(
            fileURI: fileURI,
            source: source,
            line: range.start.line,
            column: range.start.character,
            message: message
        )
        self.docVersion = source == .gopls ? docVersion : 0
        self.severity = severity
        self.range = range
        self.diagnosticSource = diagnosticSource
    }

    public init(fileURI: String, docVersion: Int, lspDiagnostic d: LSPDiagnostic) {
        self.init(
            fileURI: fileURI,
            source: .gopls,
            docVersion: docVersion,
            range: d.range,
            severity: d.severity ?? .error,
            message: d.message,
            diagnosticSource: d.source
        )
    }

    public var fileURI: String { key.fileURI }
    public var source: DocsErrorSource { key.source }
    public var message: String { key.message }
}

/// Honest report for an unresolved-import diagnostic whose external dependency is uncached or unindexed (DOC-13a, Issue #27).
/// Never carries fabricated cards or citations (`DepReportHintsCarryNoCards`).
public struct DocsErrorDepReport: Sendable, Hashable {
    public var importPath: String
    public var matchedDependency: GoModuleKey?
    public var isCachedButUnindexed: Bool
    public var message: String

    public init(
        importPath: String,
        matchedDependency: GoModuleKey?,
        isCachedButUnindexed: Bool,
        message: String
    ) {
        self.importPath = importPath
        self.matchedDependency = matchedDependency
        self.isCachedButUnindexed = isCachedButUnindexed
        self.message = message
    }
}

/// Hint payload attached to a live diagnostic (corresponds to `HintKind` in `spec/req/docs_errors.fsl`).
public enum DocsErrorHintContent: Sendable, Hashable {
    case cards(
        cards: [DocsAnswerCard],
        targetVersion: GoVersion,
        searchMode: DocsSearchMode,
        derivedQuery: String
    )
    case depReport(DocsErrorDepReport)
}

/// A live, grounded hint bound to a specific diagnostic and document version (DOC-13a..d).
public struct DocsErrorHint: Sendable, Hashable {
    public var diagnosticKey: DocsErrorDiagnosticKey
    public var docVersion: Int
    public var content: DocsErrorHintContent

    public init(diagnosticKey: DocsErrorDiagnosticKey, docVersion: Int, content: DocsErrorHintContent) {
        self.diagnosticKey = diagnosticKey
        self.docVersion = docVersion
        self.content = content
    }

    public var isDepReport: Bool {
        if case .depReport = content { return true }
        return false
    }

    /// Grounded cards for `.cards` hints; always empty for `.depReport` (`DepReportHintsCarryNoCards`).
    public var cards: [DocsAnswerCard] {
        switch content {
        case .cards(let cards, _, _, _): return cards
        case .depReport: return []
        }
    }

    public var targetVersion: GoVersion? {
        switch content {
        case .cards(_, let ver, _, _): return ver
        case .depReport: return nil
        }
    }

    public var derivedQuery: String? {
        switch content {
        case .cards(_, _, _, let q): return q
        case .depReport(let r): return r.importPath
        }
    }
}

// MARK: - Build / Vet Output Parser (DES-ERR-2)

/// Parses `go build`, `go vet`, and `go test` compiler diagnostic lines (`file.go:line:col: message`)
/// into `DocsErrorDiagnostic` values with resolved `file://` URIs.
public enum DocsBuildErrorParser {
    /// Parses multi-line compiler/vet output relative to `workingDirectory` (and optional `projectRoot`).
    public static func parse(
        output: String,
        workingDirectory: URL,
        projectRoot: URL? = nil
    ) -> [DocsErrorDiagnostic] {
        var results: [DocsErrorDiagnostic] = []
        var seen = Set<DocsErrorDiagnosticKey>()
        let baseDir = workingDirectory.standardizedFileURL
        let rootDir = (projectRoot ?? workingDirectory).standardizedFileURL

        for rawLine in output.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("# ") || trimmed.hasPrefix("FAIL\t") || trimmed.hasPrefix("FAIL ") {
                continue
            }
            // Strip optional `vet: ` prefix.
            let lineText = trimmed.hasPrefix("vet: ") ? String(trimmed.dropFirst(5)) : trimmed
            guard let parsed = parseSingleLine(lineText, workingDirectory: baseDir, projectRoot: rootDir) else {
                continue
            }
            if seen.insert(parsed.key).inserted {
                results.append(parsed)
            }
        }
        return results
    }

    private static func parseSingleLine(
        _ line: String,
        workingDirectory: URL,
        projectRoot: URL
    ) -> DocsErrorDiagnostic? {
        // Match `<path>.go:<line>:<col>: <message>` or `<path>.go:<line>: <message>`.
        let pattern = #"^([^\s:]+\.go):(\d+):(?:(\d+):)?\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else {
            return nil
        }
        let ns = line as NSString
        let rawPath = ns.substring(with: match.range(at: 1))
        guard let lineNum = Int(ns.substring(with: match.range(at: 2))), lineNum >= 1 else {
            return nil
        }
        let colNum: Int
        if match.range(at: 3).location != NSNotFound, let c = Int(ns.substring(with: match.range(at: 3))), c >= 1 {
            colNum = c
        } else {
            colNum = 1
        }
        let message = ns.substring(with: match.range(at: 4)).trimmingCharacters(in: .whitespaces)
        guard !message.isEmpty else { return nil }

        let resolvedURL = resolveGoFileURL(rawPath: rawPath, workingDirectory: workingDirectory, projectRoot: projectRoot)
        let pos = LSPPosition(line: lineNum - 1, character: colNum - 1)
        let range = LSPRange(start: pos, end: pos)
        return DocsErrorDiagnostic(
            fileURI: resolvedURL.lspURI,
            source: .build,
            docVersion: 0,
            range: range,
            severity: .error,
            message: message,
            diagnosticSource: "go build"
        )
    }

    private static func resolveGoFileURL(rawPath: String, workingDirectory: URL, projectRoot: URL) -> URL {
        if rawPath.hasPrefix("/") {
            return URL(fileURLWithPath: rawPath).standardizedFileURL
        }
        let cleaned = rawPath.hasPrefix("./") ? String(rawPath.dropFirst(2)) : rawPath
        let inWork = workingDirectory.appendingPathComponent(cleaned).standardizedFileURL
        if FileManager.default.fileExists(atPath: inWork.path) {
            return inWork
        }
        let inRoot = projectRoot.appendingPathComponent(cleaned).standardizedFileURL
        if FileManager.default.fileExists(atPath: inRoot.path) {
            return inRoot
        }
        return inWork
    }
}

// MARK: - Diagnostic Query Extractor (DES-ERR-2, DES-ERR-3)

/// Structured lookup intent extracted from a Go compiler / gopls diagnostic message.
public struct DocsErrorExtractedQuery: Sendable, Hashable {
    /// Query passed to `ResearchService.search`.
    public var query: String
    /// Unresolved import path if the diagnostic reports a missing/unimported package.
    public var unresolvedImportPath: String?
    /// True when the diagnostic refers to a specific symbol/API rather than a general concept.
    public var isSymbolFocused: Bool

    public init(query: String, unresolvedImportPath: String? = nil, isSymbolFocused: Bool = true) {
        self.query = query
        self.unresolvedImportPath = unresolvedImportPath
        self.isSymbolFocused = isSymbolFocused
    }
}

/// Deterministic extractor mapping Go compiler & gopls error messages to Docs lookup queries.
/// Returns `nil` for noisy or purely local errors (unused variables, syntax punctuation, etc.)
/// so silence is preserved when no documentation evidence applies (DOC-13a).
public enum DocsErrorQueryExtractor {
    private static let ignoredSubstrings: [String] = [
        "declared and not used",
        "imported and not used",
        "but not used",
        "no new variables on left side of :=",
        "No active builds contain",
        "No packages found for open file",
        "expected ';', found",
        "expected ')', found",
        "expected '}', found",
        "expected operand, found",
        "syntax error: unexpected"
    ]

    public static func extract(from rawMessage: String) -> DocsErrorExtractedQuery? {
        let message = rawMessage
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return nil }

        for noise in ignoredSubstrings {
            if message.contains(noise) {
                return nil
            }
        }

        // 1. Unresolved import / missing package.
        if let importPath = extractUnresolvedImport(from: message) {
            return DocsErrorExtractedQuery(
                query: importPath,
                unresolvedImportPath: importPath,
                isSymbolFocused: true
            )
        }

        // 2. Method/field undefined on a concrete or interface type:
        //    e.g. `s.Scan undefined (type *bufio.Scanner has no field or method Scann)`
        //    e.g. `r.ReadAll undefined (type io.Reader has no field or method ReadAll)`
        if let typeQuery = firstCapture(
            in: message,
            pattern: #"undefined \(type \*?([a-z][a-z0-9_/.-]*\.[A-Z][A-Za-z0-9_]*) has no field or method"#
        ) {
            return DocsErrorExtractedQuery(query: typeQuery, isSymbolFocused: true)
        }

        // 3. `undefined: <ident>` (qualified symbol, missing stdlib package import, or bare identifier).
        if let undef = firstCapture(in: message, pattern: #"(?:^|:\s*)undefined:\s*([A-Za-z_][A-Za-z0-9_./]*)"#) {
            let cleaned = undef.trimmingCharacters(in: CharacterSet(charactersIn: "`\"'"))
            if cleaned.contains(".") {
                return DocsErrorExtractedQuery(query: cleaned, isSymbolFocused: true)
            }
            if DocsQueryRouter.knownStdlibPackages.contains(cleaned) {
                // Missing stdlib import such as `undefined: fmt` or `undefined: strings`.
                return DocsErrorExtractedQuery(
                    query: cleaned,
                    unresolvedImportPath: cleaned,
                    isSymbolFocused: true
                )
            }
            // Bare undefined symbol (e.g. `undefined: myLocalVar`): only worth querying if it looks
            // like an exported Go identifier (starts with uppercase) or a well-known builtin;
            // still strictly gated by ResearchService's anti-hallucination check.
            if let first = cleaned.first, first.isUppercase || cleaned == "min" || cleaned == "max" || cleaned == "clear" {
                return DocsErrorExtractedQuery(query: cleaned, isSymbolFocused: true)
            }
            return nil
        }

        // 4. Interface satisfaction mismatch (prioritized over `in argument to ...` so
        //    `cannot use x as io.Reader in argument to io.ReadAll: ... does not implement io.Reader`
        //    points directly at the missing interface contract):
        //    e.g. `does not implement http.Handler (missing method ServeHTTP)`
        if let iface = firstCapture(
            in: message,
            pattern: #"does not implement \*?([a-z][a-z0-9_/.-]*\.[A-Z][A-Za-z0-9_]*)"#
        ) {
            return DocsErrorExtractedQuery(query: iface, isSymbolFocused: true)
        }

        // 5. Argument / call signature mismatch:
        //    e.g. `cannot use x (variable of type string) as int value in argument to strconv.Atoi`
        //    e.g. `not enough arguments in call to strings.Split`
        //    e.g. `too many arguments in call to json.Unmarshal`
        if let callee = firstCapture(
            in: message,
            pattern: #"in (?:argument|call) to ([a-z][a-z0-9_/.-]*\.[A-Z][A-Za-z0-9_]*)"#
        ) {
            return DocsErrorExtractedQuery(query: callee, isSymbolFocused: true)
        }

        // 6. Type conversion / assignment to a qualified Go type:
        if let targetType = firstCapture(
            in: message,
            pattern: #"as \*?([a-z][a-z0-9_/.-]*\.[A-Z][A-Za-z0-9_]*) value"#
        ) {
            return DocsErrorExtractedQuery(query: targetType, isSymbolFocused: true)
        }

        // 6. Fallback: any explicit qualified `pkg.ExportedSymbol` mentioned in the diagnostic.
        if let qualified = firstCapture(
            in: message,
            pattern: #"\b([a-z][a-z0-9]*(?:/[a-z][a-z0-9]*)?\.[A-Z][A-Za-z0-9_]*)\b"#
        ) {
            return DocsErrorExtractedQuery(query: qualified, isSymbolFocused: true)
        }

        return nil
    }

    private static func extractUnresolvedImport(from message: String) -> String? {
        let patterns = [
            #"could not import ([A-Za-z0-9_./-]+)"#,
            #"no required module provides package "?([A-Za-z0-9_./-]+)"?"#,
            #"cannot find package "([A-Za-z0-9_./-]+)""#,
            #"package ([A-Za-z0-9_./-]+) is not in (?:std|GOROOT)"#
        ]
        for p in patterns {
            if let hit = firstCapture(in: message, pattern: p) {
                let cleaned = hit.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`;,()"))
                if !cleaned.isEmpty { return cleaned }
            }
        }
        return nil
    }

    /// Returns true if an import path looks like an external Go module path (contains a domain dot in its first segment).
    public static func isExternalModulePath(_ importPath: String) -> Bool {
        guard let firstSeg = importPath.split(separator: "/").first else { return false }
        return firstSeg.contains(".")
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
              match.numberOfRanges >= 2,
              match.range(at: 1).location != NSNotFound else {
            return nil
        }
        return (text as NSString).substring(with: match.range(at: 1))
    }
}

// MARK: - Error Hint State Machine & Store (spec/design/docs_errors.fsl)

/// Thread-safe actor enforcing every DOC-13 / DES-ERR invariant:
/// - `DisabledHasNoHints`: disabling Docs or error hints immediately clears all shown hints.
/// - `StaleHintsNeverSurvive`: advancing a file's document version clears older gopls hints and drops in-flight results.
/// - `DismissedHintsStayDismissed`: dismissing a hint is sticky while that diagnostic persists.
/// - `HintsAreGroundedAndGated`: only 1..MAX_CARDS cited, version-gated cards from loopback `ResearchService` are stored.
/// - `DepReportHintsCarryNoCards`: unresolved uncached/unindexed dependencies surface an honest report with 0 cards.
public actor DocsErrorHintStore {
    private var docsEnabled: Bool
    private var hintsEnabled: Bool
    private var docVersions: [String: Int] = [:]
    private var diagnostics: [DocsErrorDiagnosticKey: DocsErrorDiagnostic] = [:]
    private var hints: [DocsErrorDiagnosticKey: DocsErrorHint] = [:]
    private var dismissed: Set<DocsErrorDiagnosticKey> = []
    private var buildGeneration: Int = 0

    public init(docsEnabled: Bool = false, hintsEnabled: Bool = true) {
        self.docsEnabled = docsEnabled
        self.hintsEnabled = hintsEnabled
    }

    // MARK: - Settings Switches (DOC-1, DOC-13c)

    public func isDocsEnabled() -> Bool { docsEnabled }
    public func isHintsEnabled() -> Bool { hintsEnabled }

    public func setDocsEnabled(_ on: Bool) {
        docsEnabled = on
        if !on {
            hints.removeAll()
        }
    }

    public func setHintsEnabled(_ on: Bool) {
        hintsEnabled = on
        if !on {
            hints.removeAll()
        }
    }

    // MARK: - Diagnostic Lifecycle (DOC-13b, DES-ERR-2)

    /// Records a fresh `publishDiagnostics` snapshot for `fileURI` at `docVersion`.
    /// Diagnostics absent from the new snapshot (and their hints + sticky dismissals) are cleared.
    @discardableResult
    public func publishGoplsDiagnostics(
        fileURI: String,
        docVersion: Int,
        items: [DocsErrorDiagnostic]
    ) -> [DocsErrorDiagnostic] {
        let latestVer = max(docVersions[fileURI] ?? docVersion, docVersion)
        docVersions[fileURI] = latestVer

        let incomingKeys = Set(items.map(\.key))

        // Remove resolved gopls diagnostics for this file (and their hints + sticky dismissals).
        let existingFileKeys = diagnostics.keys.filter { $0.fileURI == fileURI && $0.source == .gopls }
        for key in existingFileKeys where !incomingKeys.contains(key) {
            diagnostics.removeValue(forKey: key)
            hints.removeValue(forKey: key)
            dismissed.remove(key)
        }

        // Insert or update live diagnostics.
        var toEvaluate: [DocsErrorDiagnostic] = []
        for var item in items {
            item.docVersion = docVersion
            diagnostics[item.key] = item
            // If a previously shown hint was bound to an older version, drop it immediately.
            if let existingHint = hints[item.key], existingHint.docVersion != docVersion {
                hints.removeValue(forKey: item.key)
            }
            if docsEnabled && hintsEnabled && docVersion == latestVer && !dismissed.contains(item.key) && hints[item.key] == nil {
                toEvaluate.append(item)
            }
        }
        return toEvaluate
    }

    /// Advances `fileURI`'s document version and clears all stale gopls hints for that file immediately (`StaleHintsNeverSurvive`).
    public func editDocument(fileURI: String, newVersion: Int) {
        docVersions[fileURI] = newVersion
        for (key, hint) in hints where key.fileURI == fileURI && key.source == .gopls && hint.docVersion != newVersion {
            hints.removeValue(forKey: key)
        }
    }

    /// Starts a new build/vet run, superseding every build-source diagnostic, hint, and dismissal (`new_build_run`).
    public func beginBuildRun() {
        buildGeneration += 1
        let buildKeys = diagnostics.keys.filter { $0.source == .build }
        for key in buildKeys {
            diagnostics.removeValue(forKey: key)
            hints.removeValue(forKey: key)
            dismissed.remove(key)
        }
    }

    /// Registers parsed build/vet diagnostics for the current build run.
    @discardableResult
    public func addBuildDiagnostics(_ items: [DocsErrorDiagnostic]) -> [DocsErrorDiagnostic] {
        var toEvaluate: [DocsErrorDiagnostic] = []
        for item in items where item.source == .build {
            diagnostics[item.key] = item
            if docsEnabled && hintsEnabled && !dismissed.contains(item.key) && hints[item.key] == nil {
                toEvaluate.append(item)
            }
        }
        return toEvaluate
    }

    // MARK: - Dismissal & Queries (DOC-13c)

    /// Dismisses a shown hint sticky for the lifetime of this diagnostic (`DismissedHintsStayDismissed`).
    public func dismissHint(for key: DocsErrorDiagnosticKey) {
        hints.removeValue(forKey: key)
        dismissed.insert(key)
    }

    public func hint(for key: DocsErrorDiagnosticKey) -> DocsErrorHint? {
        guard docsEnabled && hintsEnabled else { return nil }
        return hints[key]
    }

    public func allHints() -> [DocsErrorDiagnosticKey: DocsErrorHint] {
        guard docsEnabled && hintsEnabled else { return [:] }
        return hints
    }

    public func allDiagnostics() -> [DocsErrorDiagnostic] {
        Array(diagnostics.values)
    }

    public func buildDiagnostics() -> [DocsErrorDiagnostic] {
        diagnostics.values.filter { $0.source == .build }
    }

    /// Returns the insertable card only if Docs is enabled, the hint is currently shown with grounded cited cards,
    /// and the card passes the insert gate (`insert_from_hint`).
    public func insertableCard(for key: DocsErrorDiagnosticKey, cardIndex: Int) -> (card: DocsAnswerCard, targetVersion: GoVersion)? {
        guard docsEnabled,
              let hint = hints[key],
              case .cards(let cards, let targetVer, _, _) = hint.content,
              cards.indices.contains(cardIndex) else {
            return nil
        }
        let card = cards[cardIndex]
        guard card.canInsert,
              !card.citation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              GoVersionGate.evaluate(since: card.since, target: targetVer) == .allowed else {
            return nil
        }
        return (card, targetVer)
    }

    // MARK: - Grounded Hint Evaluation (DOC-13a, DES-ERR-3)

    /// Runs the existing `ResearchService` pipeline (cards-only, loopback-only, version-gated)
    /// for a live diagnostic and stores the resulting hint if still fresh and undismissed.
    @discardableResult
    public func evaluateHint(
        for key: DocsErrorDiagnosticKey,
        researchService: ResearchService,
        projectRoot: URL? = nil,
        explicitVersionOverride: GoVersion? = nil,
        editorContext: DocsEditorContext? = nil,
        moduleCacheRoot: URL? = nil,
        toolchainVersionProvider: (@Sendable () -> GoVersion?)? = nil
    ) async -> DocsErrorHint? {
        guard docsEnabled && hintsEnabled else { return nil }
        guard let diag = diagnostics[key] else { return nil }
        guard !dismissed.contains(key) else { return nil }
        if diag.source == .gopls, let currentVer = docVersions[diag.fileURI], diag.docVersion != currentVer {
            return nil
        }
        let capturedBuildGen = buildGeneration
        let capturedDocVer = diag.docVersion

        guard let extracted = DocsErrorQueryExtractor.extract(from: diag.message) else {
            return nil
        }

        // Check unresolved external dependency imports first so uncached/unindexed dependencies
        // produce an honest DepReport rather than fabricated cards (DOC-13a, AC-ERR-6).
        if let importPath = extracted.unresolvedImportPath,
           DocsErrorQueryExtractor.isExternalModulePath(importPath) {
            if let depReport = await evaluateUnresolvedDependency(
                importPath: importPath,
                researchService: researchService,
                projectRoot: projectRoot,
                moduleCacheRoot: moduleCacheRoot
            ) {
                let hint = DocsErrorHint(
                    diagnosticKey: key,
                    docVersion: capturedDocVer,
                    content: .depReport(depReport)
                )
                return storeIfStillValid(hint, diag: diag, capturedDocVer: capturedDocVer, capturedBuildGen: capturedBuildGen)
            }
        }

        // Run existing fixed retrieval pipeline (`includeSynthesis: false` — Q-B cards-only first cut).
        let answer: DocsAnswer
        do {
            answer = try await researchService.search(
                query: extracted.query,
                projectRoot: projectRoot,
                explicitVersionOverride: explicitVersionOverride,
                editorContext: editorContext,
                includeSynthesis: false,
                moduleCacheRoot: moduleCacheRoot,
                toolchainVersionProvider: toolchainVersionProvider
            )
        } catch {
            return nil
        }

        guard answer.status == .found,
              let targetVer = answer.targetVersion,
              !answer.cards.isEmpty else {
            // If it was an unresolved external import and lookup found nothing, report honest DepReport.
            if let importPath = extracted.unresolvedImportPath,
               DocsErrorQueryExtractor.isExternalModulePath(importPath) {
                let report = DocsErrorDepReport(
                    importPath: importPath,
                    matchedDependency: nil,
                    isCachedButUnindexed: false,
                    message: "外部パッケージ `\(importPath)` は go.mod / ローカル module cache で未取得です。`go get` または `go mod download` で取得してください。"
                )
                let hint = DocsErrorHint(
                    diagnosticKey: key,
                    docVersion: capturedDocVer,
                    content: .depReport(report)
                )
                return storeIfStillValid(hint, diag: diag, capturedDocVer: capturedDocVer, capturedBuildGen: capturedBuildGen)
            }
            return nil
        }

        // Defensive verification of every DOC-13a gate:
        // - 1..MAX_CARDS
        // - non-empty citation on every card
        // - Go `since` version gate passed
        // - dependency cards strictly match an active project dependency `(module, version)`
        let activeDepKeys: Set<GoModuleKey> = {
            guard let summary = answer.dependencySummary else { return [] }
            return Set(summary.indexedModules)
        }()

        let validCards: [DocsAnswerCard] = answer.cards.prefix(ResearchService.maxCards).filter { card in
            guard !card.citation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            guard GoVersionGate.evaluate(since: card.since, target: targetVer) == .allowed else { return false }
            if card.sourceKind == .dependency {
                guard let mp = card.modulePath, let mv = card.moduleVersion else { return false }
                let matchesActive = activeDepKeys.contains { $0.modulePath == mp && $0.version == mv }
                guard matchesActive else { return false }
            }
            return true
        }

        guard !validCards.isEmpty else { return nil }

        let hint = DocsErrorHint(
            diagnosticKey: key,
            docVersion: capturedDocVer,
            content: .cards(
                cards: validCards,
                targetVersion: targetVer,
                searchMode: answer.searchMode,
                derivedQuery: extracted.query
            )
        )
        return storeIfStillValid(hint, diag: diag, capturedDocVer: capturedDocVer, capturedBuildGen: capturedBuildGen)
    }

    private func evaluateUnresolvedDependency(
        importPath: String,
        researchService: ResearchService,
        projectRoot: URL?,
        moduleCacheRoot: URL?
    ) async -> DocsErrorDepReport? {
        guard let projectRoot else {
            return DocsErrorDepReport(
                importPath: importPath,
                matchedDependency: nil,
                isCachedButUnindexed: false,
                message: "外部パッケージ `\(importPath)` はローカル module cache に未取得です。"
            )
        }
        let resolvedDeps = GoModuleResolver.resolveDependencies(
            projectRoot: projectRoot,
            moduleCacheRoot: moduleCacheRoot
        )
        // Find longest matching module prefix from go.mod / go.work.
        let matched = resolvedDeps
            .filter { importPath == $0.modulePath || importPath.hasPrefix($0.modulePath + "/") }
            .max { $0.modulePath.count < $1.modulePath.count }

        guard let dep = matched else {
            return DocsErrorDepReport(
                importPath: importPath,
                matchedDependency: nil,
                isCachedButUnindexed: false,
                message: "依存パッケージ `\(importPath)` は go.mod に未登録またはローカル未取得です（根拠のないカードは提示しません）。"
            )
        }

        // If already indexed in packManager, let normal ResearchService lookup serve grounded cards.
        if await researchService.packManager.dependencyManifest(for: dep.packKey) != nil {
            return nil
        }

        if dep.isCached {
            return DocsErrorDepReport(
                importPath: importPath,
                matchedDependency: dep.packKey,
                isCachedButUnindexed: true,
                message: "`\(dep.displayID)` はローカル module cache にありますが未インデックスです。依存ドキュメントを抽出するとカードが表示されます。"
            )
        } else {
            return DocsErrorDepReport(
                importPath: importPath,
                matchedDependency: dep.packKey,
                isCachedButUnindexed: false,
                message: "`\(dep.displayID)` はローカル module cache に未取得です（別バージョンでは代替しません）。`go mod download` を実行してください。"
            )
        }
    }

    /// Re-checks every freshness, dismissal, and enablement invariant after an `await` before storing.
    private func storeIfStillValid(
        _ hint: DocsErrorHint,
        diag: DocsErrorDiagnostic,
        capturedDocVer: Int,
        capturedBuildGen: Int
    ) -> DocsErrorHint? {
        guard docsEnabled && hintsEnabled else { return nil }
        guard let currentDiag = diagnostics[diag.key] else { return nil }
        guard !dismissed.contains(diag.key) else { return nil }
        if diag.source == .build {
            guard buildGeneration == capturedBuildGen else { return nil }
        } else {
            guard currentDiag.docVersion == capturedDocVer else { return nil }
            if let latestVer = docVersions[diag.fileURI], latestVer != capturedDocVer {
                return nil
            }
        }
        hints[diag.key] = hint
        return hint
    }
}
