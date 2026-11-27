import Testing
@testable import OgCore

@Suite("Error-driven Docs Lookup (Issue #28, DOC-13)")
struct DocsErrorHintTests {

    // MARK: - Query Extractor

    @Test("Extracts actionable lookup queries from representative Go compiler errors and stays silent on noise")
    func extractsRepresentativeQueriesAndIgnoresNoise() {
        // Undefined qualified symbol
        let undefSym = DocsErrorQueryExtractor.extract(from: "undefined: slices.Contains")
        #expect(undefSym?.query == "slices.Contains")
        #expect(undefSym?.unresolvedImportPath == nil)

        // Missing stdlib import (`undefined: fmt`)
        let missingStdImport = DocsErrorQueryExtractor.extract(from: "undefined: fmt")
        #expect(missingStdImport?.query == "fmt")
        #expect(missingStdImport?.unresolvedImportPath == "fmt")

        // Undefined method on a stdlib type
        let undefMethod = DocsErrorQueryExtractor.extract(
            from: "s.Scann undefined (type *bufio.Scanner has no field or method Scann)"
        )
        #expect(undefMethod?.query == "bufio.Scanner")

        // Argument type mismatch
        let argMismatch = DocsErrorQueryExtractor.extract(
            from: "cannot use x (variable of type string) as int value in argument to strconv.Atoi"
        )
        #expect(argMismatch?.query == "strconv.Atoi")

        // Call arity mismatch
        let arityMismatch = DocsErrorQueryExtractor.extract(
            from: "not enough arguments in call to strings.Split"
        )
        #expect(arityMismatch?.query == "strings.Split")

        // Interface satisfaction mismatch
        let ifaceMismatch = DocsErrorQueryExtractor.extract(
            from: "cannot use buf (variable of type myBuf) as io.Reader value in argument to io.ReadAll: myBuf does not implement io.Reader (missing method Read)"
        )
        #expect(ifaceMismatch?.query == "io.Reader")

        // Unresolved external import
        let unresolvedExt = DocsErrorQueryExtractor.extract(
            from: "could not import github.com/go-chi/chi/v5 (no required module provides package \"github.com/go-chi/chi/v5\")"
        )
        #expect(unresolvedExt?.unresolvedImportPath == "github.com/go-chi/chi/v5")
        #expect(DocsErrorQueryExtractor.isExternalModulePath("github.com/go-chi/chi/v5"))
        #expect(!DocsErrorQueryExtractor.isExternalModulePath("fmt"))

        // Noise / purely local errors must yield nil (silence)
        #expect(DocsErrorQueryExtractor.extract(from: "x declared and not used") == nil)
        #expect(DocsErrorQueryExtractor.extract(from: "imported and not used: \"fmt\"") == nil)
        #expect(DocsErrorQueryExtractor.extract(from: "syntax error: unexpected }, expecting expression") == nil)
        #expect(DocsErrorQueryExtractor.extract(from: "undefined: myLocalHelper") == nil)
        #expect(DocsErrorQueryExtractor.extract(from: "No active builds contain /tmp/a.go") == nil)
    }

    // MARK: - Build Output Parser

    @Test("Parses go build / go vet compiler diagnostics and resolves file URIs")
    func parsesBuildAndVetOutput() {
        let dir = TempDir()
        defer { dir.cleanup() }
        let mainFile = dir.file("main.go", "package main\nfunc main() {}\n")

        let output = """
        # example.com/app
        ./main.go:12:5: undefined: fmt.Printl
        vet: ./main.go:18:2: fmt.Printf format %d has arg s of wrong type string
        ./main.go:12:5: undefined: fmt.Printl
        ./main.go:25: not enough arguments in call to strings.Split
        FAIL\texample.com/app [build failed]
        """

        let parsed = DocsBuildErrorParser.parse(output: output, workingDirectory: dir.url, projectRoot: dir.url)
        #expect(parsed.count == 3)
        #expect(parsed[0].fileURI == uri(mainFile))
        #expect(parsed[0].source == .build)
        #expect(parsed[0].range.start.line == 11)
        #expect(parsed[0].range.start.character == 4)
        #expect(parsed[0].message == "undefined: fmt.Printl")
        #expect(parsed[1].range.start.line == 17)
        #expect(parsed[2].range.start.line == 24)
        #expect(parsed[2].range.start.character == 0)
    }

    // MARK: - Grounded Cards vs Silence (Acceptance Criteria + Degradation)

    @Test("Surfaces cited grounded cards for representative errors and stays silent when no evidence exists (degraded deterministic/FTS mode)")
    func surfacesGroundedCardsAndStaysSilentWithoutEvidence() async throws {
        let storageDir = TempDir()
        let projDir = TempDir()
        defer {
            storageDir.cleanup()
            projDir.cleanup()
        }

        _ = projDir.file("go.mod", "module example.com/demo\n\ngo 1.23\n")
        let mainGo = projDir.file("main.go", "package main\nfunc main() {}\n")
        let fileURI = uri(mainGo)

        let packManager = try DocsPackManager(rootDirectory: storageDir.url)
        _ = try await packManager.ensureBundledPackInstalled(goVersion: "1.23")
        // No embedder / no reranker configured -> verifies deterministic + FTS5 degraded mode.
        let service = ResearchService(packManager: packManager, enabled: true)

        let store = DocsErrorHintStore(docsEnabled: true, hintsEnabled: true)

        let diagUndefSymbol = DocsErrorDiagnostic(
            fileURI: fileURI,
            source: .gopls,
            docVersion: 1,
            range: LSPRange(start: LSPPosition(line: 3, character: 2), end: LSPPosition(line: 3, character: 15)),
            message: "s.Scann undefined (type *bufio.Scanner has no field or method Scann)"
        )
        let diagTypeMismatch = DocsErrorDiagnostic(
            fileURI: fileURI,
            source: .gopls,
            docVersion: 1,
            range: LSPRange(start: LSPPosition(line: 5, character: 2), end: LSPPosition(line: 5, character: 20)),
            message: "cannot use x (variable of type string) as []byte value in argument to json.Unmarshal"
        )
        let diagMissingImport = DocsErrorDiagnostic(
            fileURI: fileURI,
            source: .gopls,
            docVersion: 1,
            range: LSPRange(start: LSPPosition(line: 7, character: 2), end: LSPPosition(line: 7, character: 5)),
            message: "undefined: fmt"
        )
        let diagNoEvidence = DocsErrorDiagnostic(
            fileURI: fileURI,
            source: .gopls,
            docVersion: 1,
            range: LSPRange(start: LSPPosition(line: 9, character: 2), end: LSPPosition(line: 9, character: 25)),
            message: "undefined: NonExistentCustomSymbolXYZ999"
        )

        _ = await store.publishGoplsDiagnostics(
            fileURI: fileURI,
            docVersion: 1,
            items: [diagUndefSymbol, diagTypeMismatch, diagMissingImport, diagNoEvidence]
        )

        let h1 = await store.evaluateHint(
            for: diagUndefSymbol.key,
            researchService: service,
            projectRoot: projDir.url,
            toolchainVersionProvider: { GoVersion(major: 1, minor: 23) }
        )
        #expect(h1 != nil)
        #expect(h1?.isDepReport == false)
        #expect((1...ResearchService.maxCards).contains(h1?.cards.count ?? 0))
        #expect(h1?.cards.allSatisfy { !$0.citation.isEmpty } == true)

        let h2 = await store.evaluateHint(
            for: diagTypeMismatch.key,
            researchService: service,
            projectRoot: projDir.url,
            toolchainVersionProvider: { GoVersion(major: 1, minor: 23) }
        )
        #expect(h2 != nil)
        #expect((1...ResearchService.maxCards).contains(h2?.cards.count ?? 0))
        #expect(h2?.cards.allSatisfy { !$0.citation.isEmpty } == true)

        let h3 = await store.evaluateHint(
            for: diagMissingImport.key,
            researchService: service,
            projectRoot: projDir.url,
            toolchainVersionProvider: { GoVersion(major: 1, minor: 23) }
        )
        #expect(h3 != nil)
        #expect((1...ResearchService.maxCards).contains(h3?.cards.count ?? 0))

        // No evidence -> silence (no hint stored)
        let h4 = await store.evaluateHint(
            for: diagNoEvidence.key,
            researchService: service,
            projectRoot: projDir.url,
            toolchainVersionProvider: { GoVersion(major: 1, minor: 23) }
        )
        #expect(h4 == nil)
        #expect(await store.hint(for: diagNoEvidence.key) == nil)
        // FB-ERR-7: cannot insert from a diagnostic without a shown Cards hint
        #expect(await store.insertableCard(for: diagNoEvidence.key, cardIndex: 0) == nil)
    }

    // MARK: - Lifecycle, Freshness & Dismissal Invariants (DOC-13b, DOC-13c)

    @Test("Clears hints on diagnostic resolution, document version advance, new build run, dismissal, and disable")
    func enforcesFreshnessDismissalAndDisableInvariants() async throws {
        let storageDir = TempDir()
        let projDir = TempDir()
        defer {
            storageDir.cleanup()
            projDir.cleanup()
        }

        _ = projDir.file("go.mod", "module example.com/lifecycle\n\ngo 1.23\n")
        let mainGo = projDir.file("main.go", "package main\nfunc main() {}\n")
        let fileURI = uri(mainGo)

        let packManager = try DocsPackManager(rootDirectory: storageDir.url)
        _ = try await packManager.ensureBundledPackInstalled(goVersion: "1.23")
        let service = ResearchService(packManager: packManager, enabled: true)
        let store = DocsErrorHintStore(docsEnabled: true, hintsEnabled: true)

        let diag = DocsErrorDiagnostic(
            fileURI: fileURI,
            source: .gopls,
            docVersion: 1,
            range: LSPRange(start: LSPPosition(line: 2, character: 0), end: LSPPosition(line: 2, character: 10)),
            message: "s.Scann undefined (type *bufio.Scanner has no field or method Scann)"
        )
        _ = await store.publishGoplsDiagnostics(fileURI: fileURI, docVersion: 1, items: [diag])
        let shown = await store.evaluateHint(
            for: diag.key,
            researchService: service,
            projectRoot: projDir.url,
            toolchainVersionProvider: { GoVersion(major: 1, minor: 23) }
        )
        #expect(shown != nil)

        // AC-ERR-3 / FB-ERR-2: editing document clears stale gopls hints and rejects re-evaluation for old version
        await store.editDocument(fileURI: fileURI, newVersion: 2)
        #expect(await store.hint(for: diag.key) == nil)
        let staleEval = await store.evaluateHint(
            for: diag.key,
            researchService: service,
            projectRoot: projDir.url,
            toolchainVersionProvider: { GoVersion(major: 1, minor: 23) }
        )
        #expect(staleEval == nil)

        // Re-publish at version 2 -> hint can appear again
        let diagV2 = DocsErrorDiagnostic(
            fileURI: fileURI,
            source: .gopls,
            docVersion: 2,
            range: diag.range,
            message: diag.message
        )
        _ = await store.publishGoplsDiagnostics(fileURI: fileURI, docVersion: 2, items: [diagV2])
        #expect(await store.evaluateHint(
            for: diagV2.key,
            researchService: service,
            projectRoot: projDir.url,
            toolchainVersionProvider: { GoVersion(major: 1, minor: 23) }
        ) != nil)

        // FB-ERR-4: dismissing a hint is sticky while the diagnostic persists
        await store.dismissHint(for: diagV2.key)
        #expect(await store.hint(for: diagV2.key) == nil)
        #expect(await store.evaluateHint(
            for: diagV2.key,
            researchService: service,
            projectRoot: projDir.url,
            toolchainVersionProvider: { GoVersion(major: 1, minor: 23) }
        ) == nil)

        // AC-ERR-2 & AC-ERR-4: resolving clears dismissal; a genuinely new occurrence can surface a hint again
        _ = await store.publishGoplsDiagnostics(fileURI: fileURI, docVersion: 2, items: [])
        _ = await store.publishGoplsDiagnostics(fileURI: fileURI, docVersion: 2, items: [diagV2])
        #expect(await store.evaluateHint(
            for: diagV2.key,
            researchService: service,
            projectRoot: projDir.url,
            toolchainVersionProvider: { GoVersion(major: 1, minor: 23) }
        ) != nil)

        // Independent hints switch clears all shown hints immediately (`DisabledHasNoHints`)
        await store.setHintsEnabled(false)
        #expect(await store.hint(for: diagV2.key) == nil)
        #expect(await store.allHints().isEmpty)
        await store.setHintsEnabled(true)

        // AC-ERR-5: new_build_run supersedes build-source diagnostics and their hints
        let buildDiag = DocsErrorDiagnostic(
            fileURI: fileURI,
            source: .build,
            docVersion: 0,
            range: LSPRange(start: LSPPosition(line: 4, character: 0), end: LSPPosition(line: 4, character: 10)),
            message: "not enough arguments in call to strings.Split"
        )
        _ = await store.addBuildDiagnostics([buildDiag])
        #expect(await store.evaluateHint(
            for: buildDiag.key,
            researchService: service,
            projectRoot: projDir.url,
            toolchainVersionProvider: { GoVersion(major: 1, minor: 23) }
        ) != nil)
        await store.beginBuildRun()
        #expect(await store.hint(for: buildDiag.key) == nil)
        #expect(await store.buildDiagnostics().isEmpty)
    }

    // MARK: - Version Gate & Uncached Dependency Report (FB-ERR-5, AC-ERR-6)

    @Test("Version gate blocks newer Go features from being hinted and uncached dependencies yield honest DepReport")
    func enforcesVersionGateAndDepReport() async throws {
        let storageDir = TempDir()
        let projDir = TempDir()
        let modCacheDir = TempDir()
        defer {
            storageDir.cleanup()
            projDir.cleanup()
            modCacheDir.cleanup()
        }

        // Project targets Go 1.20 with an uncached external dependency
        _ = projDir.file("go.mod", """
        module example.com/older

        go 1.20

        require github.com/go-chi/chi/v5 v5.1.0
        """)
        let mainGo = projDir.file("main.go", "package main\nfunc main() {}\n")
        let fileURI = uri(mainGo)

        let packManager = try DocsPackManager(rootDirectory: storageDir.url)
        // Install a Go 1.20 pack containing a chunk gated to `since: "1.21"` (`slices.Contains`)
        let newerChunk = DocsChunk(
            goVersion: "1.20",
            source: .stdlib,
            packageName: "slices",
            symbol: "Contains",
            kind: .function,
            title: "slices.Contains",
            anchor: "slices#Contains",
            since: "1.21",
            summary: "Contains reports whether v is present in s.",
            signature: "func Contains[S ~[]E, E comparable](s S, v E) bool",
            example: "ok := slices.Contains([]int{1, 2, 3}, 2)",
            body: "Contains reports whether v is present in s."
        )
        _ = try await packManager.ingest(goVersion: "1.20", chunks: [newerChunk])

        let service = ResearchService(packManager: packManager, enabled: true)
        let store = DocsErrorHintStore(docsEnabled: true, hintsEnabled: true)

        // FB-ERR-5: `slices.Contains` (since 1.21) must NOT be hinted for a Go 1.20 project
        let newerDiag = DocsErrorDiagnostic(
            fileURI: fileURI,
            source: .gopls,
            docVersion: 1,
            range: LSPRange(start: LSPPosition(line: 1, character: 0), end: LSPPosition(line: 1, character: 15)),
            message: "undefined: slices.Contains"
        )
        // AC-ERR-6: unresolved import for uncached dependency yields honest DepReport with 0 cards
        let depDiag = DocsErrorDiagnostic(
            fileURI: fileURI,
            source: .gopls,
            docVersion: 1,
            range: LSPRange(start: LSPPosition(line: 2, character: 0), end: LSPPosition(line: 2, character: 30)),
            message: "could not import github.com/go-chi/chi/v5 (no required module provides package \"github.com/go-chi/chi/v5\")"
        )

        _ = await store.publishGoplsDiagnostics(fileURI: fileURI, docVersion: 1, items: [newerDiag, depDiag])

        let newerHint = await store.evaluateHint(
            for: newerDiag.key,
            researchService: service,
            projectRoot: projDir.url,
            moduleCacheRoot: modCacheDir.url,
            toolchainVersionProvider: { GoVersion(major: 1, minor: 20) }
        )
        #expect(newerHint == nil)

        let depHint = await store.evaluateHint(
            for: depDiag.key,
            researchService: service,
            projectRoot: projDir.url,
            moduleCacheRoot: modCacheDir.url,
            toolchainVersionProvider: { GoVersion(major: 1, minor: 20) }
        )
        #expect(depHint != nil)
        #expect(depHint?.isDepReport == true)
        #expect(depHint?.cards.isEmpty == true)
        if case .depReport(let report)? = depHint?.content {
            #expect(report.importPath == "github.com/go-chi/chi/v5")
            #expect(report.matchedDependency?.modulePath == "github.com/go-chi/chi/v5")
            #expect(report.matchedDependency?.version == "v5.1.0")
            #expect(report.isCachedButUnindexed == false)
        } else {
            Issue.record("Expected .depReport hint content")
        }
    }
}
