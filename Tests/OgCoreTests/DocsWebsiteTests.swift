import Testing
@testable import OgCore

@Suite("DocsWebsite Corpus Extraction, Pack Storage & Search (Issue #26, DOC-14)")
struct DocsWebsiteTests {
    @Test("Extracts Effective Go HTML, Tour .article + .go snippets, FAQ, Guides, and technical Blog posts while excluding non-technical/release files (DES-WEB-2)")
    func extractsCuratedWebsiteCorpusAndRecordsExclusions() {
        let dir = TempDir()
        defer { dir.cleanup() }

        // 1. Effective Go HTML
        _ = dir.file("_content/doc/effective_go.html", """
        <!--{
            "Title": "Effective Go",
            "Template": true
        }-->
        <h2 id="defer">Defer</h2>
        <p>Go's <code>defer</code> statement schedules a function call to be run immediately before the function executing the <code>defer</code> returns&mdash;ideal for unlocking mutexes or closing files.</p>
        <pre>
        f, err := os.Open(filename)
        if err != nil {
            return "", err
        }
        defer f.Close()
        </pre>
        <h3 id="errors">Errors</h3>
        <p>Library routines must often return some sort of error indication to the caller.</p>
        """)

        // 2. Tour of Go .article + .go snippet
        _ = dir.file("_content/tour/basics.article", """
        Packages, variables, and functions.
        Learn the basic components of any Go program.

        * Packages

        Every Go program is made up of packages. Programs start running in package `main`.

        .play basics/packages.go

        * Imports

        This code groups the imports into a parenthesized, "factored" import statement.

        .play basics/imports.go
        """)
        _ = dir.file("_content/tour/basics/packages.go", """
        //go:build OMIT
        package main

        import (
        \t"fmt"
        \t"math/rand"
        )

        func main() {
        \tfmt.Println("My favorite number is", rand.Intn(10))
        }
        """)
        _ = dir.file("_content/tour/basics/imports.go", """
        package main

        import (
        \t"fmt"
        \t"math"
        )

        func main() {
        \tfmt.Printf("Now you have %g problems.\\n", math.Sqrt(7))
        }
        """)

        // 3. FAQ Markdown with explicit {#Anchor}
        _ = dir.file("_content/doc/faq.md", """
        ---
        title: "Frequently Asked Questions (FAQ)"
        ---

        ## Types {#types}

        ### Why is there no type inheritance? {#inheritance}

        Object-oriented programming, at least in the best-known languages, involves too much discussion of the relationships between types.
        """)

        // 4. Technical Go Blog with {{code ...}} directive + excluded non-technical blog posts
        _ = dir.file("_content/blog/http-auth-patterns.md", """
        ---
        title: "HTTP Client Authentication Patterns"
        tags:
        - http
        - authorization
        ---

        ## Setting Authorization Headers

        Use `http.NewRequestWithContext` and `req.Header.Set` to attach a Bearer token in the Authorization header before calling `client.Do`.

        {{code "http-auth-patterns/bearer.go"}}
        """)
        _ = dir.file("_content/blog/http-auth-patterns/bearer.go", """
        package main

        import (
        \t"context"
        \t"net/http"
        )

        func sendAuth(ctx context.Context, url, token string) (*http.Response, error) {
        \treq, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
        \tif err != nil {
        \t\treturn nil, err
        \t}
        \treq.Header.Set("Authorization", "Bearer "+token)
        \treturn http.DefaultClient.Do(req)
        }
        """)
        _ = dir.file("_content/blog/survey2025.md", "---\ntitle: \"Go Developer Survey 2025\"\n---\n## Results\nSurvey results.\n")
        _ = dir.file("_content/blog/go1.23.md", "---\ntitle: \"Go 1.23 is released\"\n---\n## Highlights\nRelease announcement.\n")
        _ = dir.file("_content/blog/10years.md", "---\ntitle: \"Ten Years of Go\"\n---\n## Birthday\nCelebration.\n")

        // 5. Excluded release notes & redirect/install docs + included guide & wiki
        _ = dir.file("_content/doc/go1.23.md", "---\ntitle: \"Go 1.23 Release Notes\"\n---\n## Language\nRelease notes.\n")
        _ = dir.file("_content/doc/go_faq.md", "---\ntitle: \"FAQ Redirect\"\n---\nRedirect.\n")
        _ = dir.file("_content/doc/install.html", "<!--{\"Title\":\"Download and install\"}--><h2>Install</h2><p>Install Go.</p>")
        _ = dir.file("_content/doc/database/querying.md", "---\ntitle: \"Querying for data\"\n---\n## Querying for a single row\nUse `db.QueryRow` for single rows.\n")
        _ = dir.file("_content/wiki/Comments.md", "---\ntitle: \"Go Code Review Comments\"\n---\n## Handle Errors\nDo not discard errors using `_` variables.\n")

        let result = DocsWebsiteCorpusExtractor.extractWebsite(
            fromWebsiteRoot: dir.url,
            options: DocsWebsiteExtractionOptions(snapshotDate: "2026-11-28", snapshotCommit: "abc1234")
        )

        #expect(result.snapshotDate == "2026-11-28")
        #expect(result.snapshotCommit == "abc1234")
        #expect(result.categoryCounts["effective_go"] == 2)
        #expect(result.categoryCounts["tour"] == 2)
        #expect(result.categoryCounts["faq"] == 1)
        #expect(result.categoryCounts["blog"] == 1)
        #expect(result.categoryCounts["guides"] == 1)
        #expect(result.categoryCounts["wiki"] == 1)

        // Effective Go HTML chunk
        let effDefer = result.chunks.first { $0.documentID == "website/doc/effective_go" && $0.symbol == "Defer" }
        #expect(effDefer != nil)
        #expect(effDefer?.provenance == .officialWebsiteSnapshot)
        #expect(effDefer?.since == nil)
        #expect(effDefer?.sourceURL == "https://go.dev/doc/effective_go#defer")
        #expect(effDefer?.snapshotDate == "2026-11-28")
        #expect(stringContains(effDefer?.example ?? "", "defer f.Close()"))
        #expect(stringContains(effDefer?.body ?? "", "—"))
        #expect(stringContains(effDefer?.citationLabel ?? "", "https://go.dev/doc/effective_go#defer"))
        #expect(stringContains(effDefer?.citationLabel ?? "", "2026-11-28"))

        // Tour of Go slide chunk with resolved .go snippet and OMIT stripped
        let tourPkg = result.chunks.first { $0.documentID == "website/tour/basics" && $0.symbol == "Packages" }
        #expect(tourPkg?.sourceURL == "https://go.dev/tour/basics/1")
        #expect(stringContains(tourPkg?.example ?? "", "rand.Intn(10)"))
        #expect(!stringContains(tourPkg?.example ?? "", "OMIT"))

        // FAQ preserves explicit {#inheritance} anchor
        let faqChunk = result.chunks.first { $0.documentID == "website/doc/faq" && $0.symbol == "Why is there no type inheritance?" }
        #expect(faqChunk?.sourceURL == "https://go.dev/doc/faq#inheritance")

        // Blog resolves {{code ...}} into snippet and preserves tags
        let blogChunk = result.chunks.first { $0.documentID == "website/blog/http-auth-patterns" }
        #expect(blogChunk?.sourceURL == "https://go.dev/blog/http-auth-patterns#Setting_Authorization_Headers")
        #expect(stringContains(blogChunk?.example ?? "", "req.Header.Set(\"Authorization\""))
        #expect(blogChunk?.searchAliases.contains("authorization") == true)

        // Excluded files recorded with reasons and absent from chunks
        let excludedPaths = Set(result.excludedFiles.map(\.relativePath))
        #expect(excludedPaths.contains("blog/survey2025.md"))
        #expect(excludedPaths.contains("blog/go1.23.md"))
        #expect(excludedPaths.contains("blog/10years.md"))
        #expect(excludedPaths.contains("doc/go1.23.md"))
        #expect(excludedPaths.contains("doc/go_faq.md"))
        #expect(excludedPaths.contains("doc/install.html"))
        #expect(!result.chunks.contains { $0.documentID.contains("survey2025") || $0.documentID.contains("go1.23") })

        // FR-31 non-collision with BundledGoCorpus stable IDs
        let bundledIDs = Set(BundledGoCorpus.chunks(forGoVersion: "1.23").map(\.stableID))
        let websiteIDs = Set(result.chunks.map(\.stableID))
        #expect(bundledIDs.isDisjoint(with: websiteIDs))
    }

    @Test("Website snapshot pack supports staged ingestion, vector reuse, model-switch demotion, and clean deletion (DOC-14c/d)")
    func websitePackLifecycleAndVectorReuse() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let pm = try makeDocsPackManager(in: dir)
        let embedV1 = CountingFakeEmbedder(id: "embed-a", version: "v1")
        let embedV2 = CountingFakeEmbedder(id: "embed-b", version: "v2")

        let chunks = [
            DocsChunk(
                goVersion: "website",
                source: .guide,
                provenance: .officialWebsiteSnapshot,
                packageName: "",
                documentID: "website/doc/effective_go",
                symbol: "Defer",
                kind: .section,
                title: "Effective Go: Defer",
                anchor: "#defer",
                since: nil,
                summary: "Schedule cleanup calls with defer.",
                example: "defer f.Close()",
                body: "Go's defer statement schedules a function call.",
                sourceURL: "https://go.dev/doc/effective_go#defer",
                snapshotDate: "2026-11-28"
            ),
            DocsChunk(
                goVersion: "website",
                source: .guide,
                provenance: .officialWebsiteSnapshot,
                packageName: "",
                documentID: "website/blog/context",
                symbol: "Introduction",
                kind: .section,
                title: "Go Concurrency Patterns: Context: Introduction",
                anchor: "#Introduction",
                since: nil,
                summary: "Pass request-scoped deadlines and cancellation via context.",
                example: "ctx, cancel := context.WithTimeout(parent, time.Second)\ndefer cancel()",
                body: "In Go servers, each incoming request is handled in its own goroutine.",
                sourceURL: "https://go.dev/blog/context#Introduction",
                snapshotDate: "2026-11-28"
            )
        ]

        _ = try await pm.selectEmbeddingModel(embedV1.descriptor)
        let r1 = try await pm.ingestWebsite(
            chunks: chunks,
            snapshotDate: "2026-11-28",
            snapshotCommit: "deadbee",
            includedCategories: ["blog", "effective_go"],
            embedder: embedV1
        )
        #expect(r1.status == .ready)
        #expect(r1.computedVectors == 2)
        #expect(r1.reusedVectors == 0)

        let m1 = await pm.websiteManifest()
        #expect(m1?.status == .ready)
        #expect(m1?.snapshotDate == "2026-11-28")
        #expect(m1?.snapshotCommit == "deadbee")
        #expect(m1?.chunkCount == 2)
        #expect(stringContains(m1?.license ?? "", "BSD-3-Clause"))

        // Re-ingesting the same chunks with a new snapshot date reuses cached vectors (DOC-14c)
        let r2 = try await pm.ingestWebsite(
            chunks: chunks,
            snapshotDate: "2026-11-29",
            embedder: embedV1
        )
        #expect(r2.status == .ready)
        #expect(r2.reusedVectors == 2)
        #expect(r2.computedVectors == 0)

        // Switching embedding model demotes Ready website pack to FTS-only (ReadyWebsitePackMatchesModel)
        let demoted = try await pm.selectEmbeddingModel(embedV2.descriptor)
        #expect(demoted)
        let mAfterSwitch = await pm.websiteManifest()
        #expect(mAfterSwitch?.status == .indexingFTSOnly)
        #expect(mAfterSwitch?.embeddingModelID == nil)

        // SQLite round-trip preserves sourceURL and snapshotDate
        let idx = try await pm.openWebsiteIndex()
        #expect(idx != nil)
        let stored = try idx?.allChunks() ?? []
        idx?.close()
        #expect(stored.count == 2)
        #expect(stored.first { $0.symbol == "Defer" }?.sourceURL == "https://go.dev/doc/effective_go#defer")
        #expect(stored.first { $0.symbol == "Defer" }?.snapshotDate == "2026-11-28")

        // Deleting website pack removes it and reclaims unreferenced vectors
        let reclaimed = try await pm.deleteWebsitePack()
        #expect(reclaimed >= 2)
        #expect(await pm.websiteManifest() == nil)
    }

    @Test("ResearchService surfaces website snapshot cards with provenance across Go versions, enforces Go pack presence, and preserves stdlib golden ranking (DOC-14a/b)")
    func websiteSearchProvenanceAndNoRegression() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let pm = try makeDocsPackManager(in: dir)
        let service = ResearchService(packManager: pm, enabled: true)

        // Install website snapshot pack BEFORE any Go version pack
        let webChunks = [
            DocsChunk(
                goVersion: "website",
                source: .guide,
                provenance: .officialWebsiteSnapshot,
                packageName: "",
                documentID: "website/blog/http-auth-patterns",
                symbol: "Setting Authorization Headers",
                kind: .section,
                title: "HTTP Client Authentication Patterns: Setting Authorization Headers",
                anchor: "#Setting_Authorization_Headers",
                since: nil,
                summary: "Attach Bearer tokens to HTTP requests using http.NewRequestWithContext and req.Header.Set(\"Authorization\", ...).",
                example: "req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)\nreq.Header.Set(\"Authorization\", \"Bearer \"+token)",
                body: "Use http.NewRequestWithContext and req.Header.Set to send an Authorization Bearer header with net/http.Client.Do.",
                searchAliases: ["Authorization", "Bearer", "header", "net/http"],
                sourceURL: "https://go.dev/blog/http-auth-patterns#Setting_Authorization_Headers",
                snapshotDate: "2026-11-28"
            )
        ]
        _ = try await pm.ingestWebsite(chunks: webChunks, snapshotDate: "2026-11-28", includedCategories: ["blog"])

        // DOC-14b / FB-WEB-1: Never answer from website pack alone when project_ver Go pack is missing!
        let missing = try await service.search(
            query: "Authorization Bearer header",
            explicitVersionOverride: GoVersion(major: 1, minor: 21)
        )
        if case .missingPack = missing.status {
            #expect(missing.cards.isEmpty)
        } else {
            Issue.record("Expected .missingPack when go1.21 pack is not installed, got \(missing.status)")
        }

        // Install go1.21 AND go1.23 packs; the single website snapshot pack works across BOTH versions (DOC-14a)
        _ = try await pm.ingest(goVersion: "1.21", chunks: BundledGoCorpus.chunks(forGoVersion: "1.21"))
        _ = try await pm.ingest(goVersion: "1.23", chunks: BundledGoCorpus.chunks(forGoVersion: "1.23"))

        for ver in [GoVersion(major: 1, minor: 21), GoVersion(major: 1, minor: 23)] {
            let ans = try await service.search(
                query: "Authorization ヘッダをつけてリクエストを送りたい",
                explicitVersionOverride: ver
            )
            #expect(ans.status == .found)
            #expect(stringContains(ans.searchedScope, "Go Website (1 chunks, snapshot 2026-11-28)"))
            let webCard = ans.cards.first { $0.provenance == .officialWebsiteSnapshot }
            #expect(webCard != nil)
            #expect(webCard?.sourceURL == "https://go.dev/blog/http-auth-patterns#Setting_Authorization_Headers")
            #expect(webCard?.snapshotDate == "2026-11-28")
            #expect(stringContains(webCard?.citation ?? "", "https://go.dev/blog/http-auth-patterns#Setting_Authorization_Headers"))
            #expect(stringContains(webCard?.citation ?? "", "snapshot 2026-11-28"))
            #expect(webCard?.since == nil)
            #expect(webCard?.canInsert == true)
        }

        // Existing golden queries still return stdlib top-1 without regression
        let lineAns = try await service.search(
            query: "ファイルを1行ずつ読みたい",
            explicitVersionOverride: GoVersion(major: 1, minor: 23)
        )
        #expect(lineAns.status == .found)
        #expect(lineAns.cards.first?.packageName == "bufio" && lineAns.cards.first?.symbol == "Scanner")

        let jsonAns = try await service.search(
            query: "JSON を整形して出したい",
            explicitVersionOverride: GoVersion(major: 1, minor: 23)
        )
        #expect(jsonAns.status == .found)
        #expect(jsonAns.cards.first?.packageName == "encoding/json")
    }
}
