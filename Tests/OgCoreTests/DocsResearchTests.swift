import Testing
@testable import OgCore

@Suite("GoVersion & VersionGate")
struct GoVersionTests {
    @Test("Resolves version priority: go.mod > go.work > toolchain (FR-2)")
    func resolvesVersionOrder() {
        let dir = TempDir()
        defer { dir.cleanup() }

        _ = dir.file("go.work", "go 1.22.5\n\nuse .\n")
        let fromWork = GoVersionResolver.resolve(projectRoot: dir.url, toolchainVersionProvider: { GoVersion(major: 1, minor: 23) })
        #expect(fromWork?.version == GoVersion(major: 1, minor: 22, patch: 5))
        #expect(fromWork?.source == .goWork)

        _ = dir.file("go.mod", "module example.com/app\n\ngo 1.21.4 // pinned\n")
        let fromMod = GoVersionResolver.resolve(projectRoot: dir.url, toolchainVersionProvider: { GoVersion(major: 1, minor: 23) })
        #expect(fromMod?.version == GoVersion(major: 1, minor: 21, patch: 4))
        #expect(fromMod?.source == .goMod)

        let emptyDir = TempDir()
        defer { emptyDir.cleanup() }
        let fromToolchain = GoVersionResolver.resolve(projectRoot: emptyDir.url, toolchainVersionProvider: { GoVersion(major: 1, minor: 23, patch: 1) })
        #expect(fromToolchain?.version == GoVersion(major: 1, minor: 23, patch: 1))
        #expect(fromToolchain?.source == .toolchain)
    }

    @Test("Version gate blocks newer features and never guesses unknown since (FR-8, FR-10)")
    func versionGateEnforcesSince() {
        let go121 = GoVersion(major: 1, minor: 21)
        let go122 = GoVersion(major: 1, minor: 22)
        let go123 = GoVersion(major: 1, minor: 23)

        #expect(GoVersionGate.evaluate(since: "1.0", target: go121) == .allowed)
        #expect(GoVersionGate.evaluate(since: "1.22", target: go121) == .requiresNewer(since: GoVersion(major: 1, minor: 22)))
        #expect(GoVersionGate.evaluate(since: "1.22", target: go122) == .allowed)
        #expect(GoVersionGate.evaluate(since: "1.23", target: go122) == .requiresNewer(since: GoVersion(major: 1, minor: 23)))
        #expect(GoVersionGate.evaluate(since: "1.23", target: go123) == .allowed)
        #expect(GoVersionGate.evaluate(since: nil, target: go121) == .allowed)
    }
}

@Suite("DocsCorpus Extraction & Diffing")
struct DocsCorpusTests {
    @Test("Extracts stdlib GoDoc, attaches Example* to parent symbol, and skips internal/ (FR-4-1, FR-7)")
    func extractsStdlibAndExamples() {
        let dir = TempDir()
        defer { dir.cleanup() }

        let src = dir.subdir("src")
        _ = dir.file("src/bufio/scan.go", """
        // Package bufio implements buffered I/O.
        package bufio

        // Scanner provides a convenient interface for reading lines.
        type Scanner struct{}

        // NewScanner returns a new Scanner to read from r.
        func NewScanner(r any) *Scanner { return nil }

        // Scan advances the Scanner to the next token.
        func (s *Scanner) Scan() bool { return false }

        func helperUnexported() {}
        """)
        _ = dir.file("src/bufio/example_test.go", """
        package bufio_test

        func ExampleScanner() {
        \ts := bufio.NewScanner(r)
        \tfor s.Scan() {
        \t\tfmt.Println(s.Text())
        \t}
        }
        """)
        _ = dir.file("src/internal/secret/secret.go", """
        package secret
        // Secret should never be extracted.
        func Secret() {}
        """)

        let chunks = DocsCorpusExtractor.extractStdlib(fromGorootSrc: src, goVersion: "1.23")
        #expect(chunks.contains { $0.packageName == "bufio" && $0.kind == .package })
        #expect(chunks.contains { $0.packageName == "bufio" && $0.symbol == "NewScanner" && $0.kind == .function })
        #expect(chunks.contains { $0.packageName == "bufio" && $0.symbol == "Scanner.Scan" && $0.kind == .method })
        #expect(!chunks.contains { $0.symbol == "helperUnexported" })
        #expect(!chunks.contains { $0.packageName.contains("internal") })

        let scannerType = chunks.first { $0.packageName == "bufio" && $0.symbol == "Scanner" }
        #expect(scannerType?.example != nil)
        #expect(stringContains(scannerType?.example ?? "", "bufio.NewScanner"))
    }

    @Test("Strips Hugo front matter and shortcodes from official guides (FR-4-3)")
    func stripsHugoMarkup() {
        let raw = """
        ---
        title: Effective Go
        ---
        {{< note >}}ignored shortcode{{< /note >}}
        ## For {#for}
        The Go for loop unifies for and while.
        ```go
        for i := 0; i < 3; i++ {
        \tfmt.Println(i)
        }
        ```
        """
        let chunks = DocsCorpusExtractor.extractGuideMarkdown(text: raw, documentTitle: "Effective Go", goVersion: "1.23")
        #expect(chunks.count == 1)
        #expect(chunks[0].anchor == "#For")
        #expect(!stringContains(chunks[0].body, "title: Effective Go"))
        #expect(!stringContains(chunks[0].body, "{{<"))
        #expect(stringContains(chunks[0].example ?? "", "for i := 0"))
    }

    @Test("Stable ID and content hash are Go-version independent; diff classifies changes (FR-31)")
    func stableIDAndDiff() {
        let v22 = BundledGoCorpus.chunks(forGoVersion: "1.22")
        let v23 = BundledGoCorpus.chunks(forGoVersion: "1.23")
        #expect(v22.count == v23.count)
        for (a, b) in zip(v22, v23) {
            #expect(a.stableID == b.stableID)
            #expect(a.contentHash == b.contentHash)
        }

        let prevMap = [
            "a": "h1",
            "b": "h2",
            "c": "h3"
        ]
        let c1 = DocsChunk(goVersion: "1.23", source: .stdlib, packageName: "p", symbol: "A", kind: .function, title: "A", anchor: "p.A", summary: "s", body: "b")
        let diff = DocsChunkDiff.compute(previous: prevMap, next: [c1])
        #expect(diff.added.count == 1)
        #expect(diff.removed == ["a", "b", "c"])
    }
}

@Suite("Ingestion Batch, Resumability, Incremental Diff & Shared Vector Store")
struct DocsBatchTests {
    @Test("Atomic swap failure leaves existing active pack intact (FR-6, FR-22)")
    func swapFailurePreservesActivePack() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let mgr = try makeDocsPackManager(in: dir)

        let v1Chunks = Array(BundledGoCorpus.chunks(forGoVersion: "1.23").prefix(5))
        let r1 = try await mgr.ingest(goVersion: "1.23", chunks: v1Chunks, embedder: nil)
        #expect(!r1.cancelled)
        #expect(await mgr.manifest(for: "1.23")?.chunkCount == 5)

        let v2Chunks = Array(BundledGoCorpus.chunks(forGoVersion: "1.23").prefix(10))
        var threw = false
        do {
            _ = try await mgr.ingest(goVersion: "1.23", chunks: v2Chunks, embedder: nil, simulateSwapFailure: true)
        } catch {
            threw = true
        }
        #expect(threw)
        // Old active pack of 5 chunks remains intact and readable.
        #expect(await mgr.manifest(for: "1.23")?.chunkCount == 5)
        let idx = try await mgr.openIndex(for: "1.23")
        #expect(try idx?.chunkCount() == 5)
        idx?.close()
    }

    @Test("Batch supports progress, cancellation, and resume computing only remaining chunks (FR-23, FR-25)")
    func batchCancelAndResume() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let mgr = try makeDocsPackManager(in: dir)
        let chunks = Array(BundledGoCorpus.chunks(forGoVersion: "1.23").prefix(8))

        let embedder = CountingFakeEmbedder(id: "embed-test", version: "1.0")
        embedder.configureCancel(manager: mgr, goVersion: "1.23", afterCalls: 3)

        let first = try await mgr.ingest(goVersion: "1.23", chunks: chunks, embedder: embedder)
        #expect(first.cancelled)
        #expect(first.computedVectors == 3)
        // FR-28: initial FTS-only snapshot is already searchable while embeddings were interrupted.
        #expect(await mgr.manifest(for: "1.23")?.status == .indexingFTSOnly)

        // Resume: only the remaining 5 chunks should invoke embedder.embed(_:).
        embedder.clearCancel()
        embedder.resetCount()
        let resumed = try await mgr.ingest(goVersion: "1.23", chunks: chunks, embedder: embedder)
        #expect(!resumed.cancelled)
        #expect(resumed.status == .ready)
        #expect(resumed.reusedVectors == 3)
        #expect(resumed.computedVectors == 5)
        #expect(embedder.callCount == 5)
    }

    @Test("Incremental update re-embeds only changed chunks; model switch invalidates semantic readiness (FR-26, FR-27)")
    func incrementalUpdateAndModelSwitch() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let mgr = try makeDocsPackManager(in: dir)
        let base = Array(BundledGoCorpus.chunks(forGoVersion: "1.23").prefix(6))
        let embedderV1 = CountingFakeEmbedder(id: "embed-m", version: "v1")

        let initReport = try await mgr.ingest(goVersion: "1.23", chunks: base, embedder: embedderV1)
        #expect(initReport.computedVectors == 6)

        // Modify 1 chunk and delete 1 chunk.
        var updated = Array(base.dropLast())
        updated[0] = DocsChunk(
            goVersion: "1.23",
            source: updated[0].source,
            packageName: updated[0].packageName,
            symbol: updated[0].symbol,
            kind: updated[0].kind,
            title: updated[0].title,
            anchor: updated[0].anchor,
            since: updated[0].since,
            summary: updated[0].summary + " (revised)",
            signature: updated[0].signature,
            example: updated[0].example,
            body: updated[0].body + "\nRevised detail."
        )

        embedderV1.resetCount()
        let diffReport = try await mgr.ingest(goVersion: "1.23", chunks: updated, embedder: embedderV1)
        #expect(diffReport.changedChunks == 1)
        #expect(diffReport.removedChunks == 1)
        #expect(diffReport.unchangedChunks == 4)
        #expect(diffReport.computedVectors == 1)
        #expect(diffReport.reusedVectors == 4)
        #expect(embedderV1.callCount == 1)

        // FR-27: switching embedding model demotes Ready pack to FTS-only until rebuilt.
        let needsRebuild = try await mgr.selectEmbeddingModel(EmbeddingModelDescriptor(id: "embed-m", version: "v2"))
        #expect(needsRebuild)
        #expect(await mgr.manifest(for: "1.23")?.status == .indexingFTSOnly)
    }

    @Test("New Go version pack reuses unchanged chunk vectors from SharedVectorStore and GC reclaims orphans (FR-30, FR-31)")
    func crossVersionSharedVectorReuseAndGC() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let mgr = try makeDocsPackManager(in: dir)
        let embedder = CountingFakeEmbedder(id: "shared-embed", version: "v1")

        let chunks122 = BundledGoCorpus.chunks(forGoVersion: "1.22")
        let r122 = try await mgr.ingest(goVersion: "1.22", chunks: chunks122, embedder: embedder)
        #expect(r122.computedVectors == chunks122.count)
        #expect(r122.reusedVectors == 0)

        // Now ingest Go 1.23 with identical chunk contents -> 100% vector reuse, 0 recomputations!
        embedder.resetCount()
        let chunks123 = BundledGoCorpus.chunks(forGoVersion: "1.23")
        let r123 = try await mgr.ingest(goVersion: "1.23", chunks: chunks123, embedder: embedder)
        #expect(r123.computedVectors == 0)
        #expect(r123.reusedVectors == chunks123.count)
        #expect(embedder.callCount == 0)

        let storedBefore = try await mgr.sharedVectorStore.count()
        #expect(storedBefore == chunks122.count)

        // Deleting 1.22 keeps vectors referenced by 1.23.
        let gcAfterFirstDelete = try await mgr.deletePack(goVersion: "1.22")
        #expect(gcAfterFirstDelete == 0)
        #expect(try await mgr.sharedVectorStore.count() == chunks123.count)

        // Deleting 1.23 too makes all vectors unreferenced -> reclaimed by GC.
        let gcAfterSecondDelete = try await mgr.deletePack(goVersion: "1.23")
        #expect(gcAfterSecondDelete == chunks123.count)
        #expect(try await mgr.sharedVectorStore.count() == 0)
    }
}

@Suite("Loopback Privacy & Golden Queries (Issue #18 §8.3)")
struct DocsGoldenQueryTests {
    @Test("NeverLeavesMachine: refuses non-loopback endpoints (FR-16, DOC-6)")
    func enforcesLoopbackOnly() async throws {
        let desc = EmbeddingModelDescriptor(id: "m", version: "1")
        #expect(LoopbackEmbeddingClient(endpoint: url("http://127.0.0.1:8080")!, descriptor: desc) != nil)
        #expect(LoopbackEmbeddingClient(endpoint: url("http://localhost:8080")!, descriptor: desc) != nil)
        #expect(LoopbackEmbeddingClient(endpoint: url("http://[::1]:8080")!, descriptor: desc) != nil)
        #expect(LoopbackEmbeddingClient(endpoint: url("https://api.openai.com")!, descriptor: desc) == nil)
        #expect(LoopbackEmbeddingClient(endpoint: url("http://192.168.1.10:8080")!, descriptor: desc) == nil)

        let dir = TempDir()
        defer { dir.cleanup() }
        let mgr = try makeDocsPackManager(in: dir)
        let svc = ResearchService(packManager: mgr, enabled: true)

        var rejectedRemote = false
        do {
            try await svc.setLocalEndpoint(url("https://example.com"))
        } catch {
            rejectedRemote = true
        }
        #expect(rejectedRemote)
        #expect(await svc.currentEndpoint() == nil)
    }

    @Test("Opt-in disabled state and missing pack never silently answer from another Go version (DOC-1, DOC-2, §7.4)")
    func optInAndMissingPackGuard() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let mgr = try makeDocsPackManager(in: dir)
        _ = try await mgr.ensureBundledPackInstalled(goVersion: "1.23")

        // Disabled by default (opt-in)
        let svc = ResearchService(packManager: mgr, enabled: false)
        let disabledAnswer = try await svc.search(query: "ファイルを1行ずつ読みたい")
        #expect(disabledAnswer.status == .disabled)
        #expect(disabledAnswer.cards.isEmpty)

        // Enable, but project pins go 1.21 while only go 1.23 pack is installed -> MissingPack (no silent fallback!)
        await svc.setEnabled(true)
        let proj = TempDir()
        defer { proj.cleanup() }
        _ = proj.file("go.mod", "module example.com/legacy\n\ngo 1.21\n")

        let missing = try await svc.search(query: "for ループの書き方", projectRoot: proj.url)
        if case .missingPack(let req, let installed) = missing.status {
            #expect(req.minorKey == "1.21")
            #expect(installed == ["1.23"])
        } else {
            Issue.record("Expected .missingPack for go 1.21 when only 1.23 pack is installed")
        }
        #expect(missing.cards.isEmpty)
    }

    @Test("Golden queries (§8.3): UC-1, UC-2, UC-3, version gate, citations, and anti-hallucination offline without LLM")
    func goldenQueries() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let mgr = try makeDocsPackManager(in: dir)
        _ = try await mgr.ensureBundledPackInstalled(goVersion: "1.21")
        _ = try await mgr.ensureBundledPackInstalled(goVersion: "1.23")
        let svc = ResearchService(packManager: mgr, enabled: true)

        let proj121 = TempDir()
        defer { proj121.cleanup() }
        _ = proj121.file("go.mod", "module example.com/v121\n\ngo 1.21\n")

        let proj123 = TempDir()
        defer { proj123.cleanup() }
        _ = proj123.file("go.mod", "module example.com/v123\n\ngo 1.23\n")

        // 1. 「for ループの書き方」 on Go 1.21: spec + Effective Go top, NO integer range / func range in usable cards!
        let for121 = try await svc.search(query: "for ループの書き方", projectRoot: proj121.url)
        #expect(for121.status == .found)
        #expect(!for121.usedLLM)
        #expect(for121.cards.count <= 3 && !for121.cards.isEmpty)
        #expect(for121.cards.contains { $0.sourceKind == .spec && $0.symbol == "for" })
        #expect(for121.cards.contains { $0.sourceKind == .guide && $0.symbol == "for range" })
        #expect(!for121.cards.contains { $0.symbol == "for range int" || $0.symbol == "for range func" })
        #expect(for121.newerVersionNotes.contains { $0.since == GoVersion(major: 1, minor: 22) })
        for card in for121.cards {
            #expect(!card.citation.isEmpty)
            #expect(card.goVersion == "1.21")
        }

        // Same query on Go 1.23: integer range (1.22+) is allowed.
        let for123 = try await svc.search(query: "for ループの書き方", projectRoot: proj123.url)
        #expect(for123.status == .found)
        #expect(for123.newerVersionNotes.isEmpty)

        // 2. 「ファイルを1行ずつ読みたい」 -> bufio.Scanner rank #1
        let readLine = try await svc.search(query: "ファイルを1行ずつ読みたい", projectRoot: proj123.url)
        #expect(readLine.status == .found)
        #expect(readLine.cards.first?.packageName == "bufio")
        #expect(readLine.cards.first?.symbol == "Scanner")
        #expect(readLine.cards.first?.canInsert == true)
        if let top = readLine.cards.first {
            let snippet = DocsCodeInserter.prepareSnippet(from: top, targetVersion: GoVersion(major: 1, minor: 23))
            #expect(snippet != nil && stringContains(snippet ?? "", "bufio.NewScanner"))
        }

        // 3. 「JSON を整形して出したい」 -> json.MarshalIndent / json.Encoder (SetIndent)
        let jsonPretty = try await svc.search(query: "JSON を整形して出したい", projectRoot: proj123.url)
        #expect(jsonPretty.status == .found)
        let jsonSymbols = Set(jsonPretty.cards.map(\.symbol))
        #expect(jsonSymbols.contains("MarshalIndent") || jsonSymbols.contains("Encoder"))

        // 4. 「重複を取り除きたい」 -> slices.Compact or map pattern
        let dedup = try await svc.search(query: "重複を取り除きたい", projectRoot: proj123.url)
        #expect(dedup.status == .found)
        #expect(dedup.cards.contains { $0.packageName == "slices" || stringContains($0.title, "map") })

        // 5. 「処理にタイムアウトを付けたい」 -> context.WithTimeout
        let timeout = try await svc.search(query: "処理にタイムアウトを付けたい", projectRoot: proj123.url)
        #expect(timeout.status == .found)
        #expect(timeout.cards.first?.packageName == "context")
        #expect(timeout.cards.first?.symbol == "WithTimeout")

        // 6. 「標準ライブラリに正規表現ある？」 -> regexp ("あります")
        let regex = try await svc.search(query: "標準ライブラリに正規表現ある？", projectRoot: proj123.url)
        #expect(regex.status == .found)
        #expect(stringContains(regex.conclusion, "あります"))
        #expect(regex.cards.first?.packageName == "regexp")

        // 7. UC-3: 「`json.Encoder` どう使うの」 -> deterministic match for encoding/json.Encoder
        let encoderUsage = try await svc.search(query: "`json.Encoder` どう使うの", projectRoot: proj123.url)
        #expect(encoderUsage.status == .found)
        #expect(encoderUsage.cards.first?.packageName == "encoding/json")
        #expect(encoderUsage.cards.first?.symbol == "Encoder")
        #expect(encoderUsage.cards.first?.matchedBy == .deterministicExact)

        // 8. Non-existent stdlib feature -> honest Not Found, zero cards, no hallucinated symbol!
        let nonexistent = try await svc.search(query: "標準ライブラリに量子テレポーテーション制御ある？", projectRoot: proj123.url)
        #expect(nonexistent.status == .notFound)
        #expect(nonexistent.cards.isEmpty)
        #expect(stringContains(nonexistent.conclusion, "見つかりませんでした"))
        #expect(stringContains(nonexistent.searchedScope, "Go 1.23"))
    }
}
