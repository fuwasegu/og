import Testing
@testable import OgCore

@Suite("GoVersion & VersionGate")
struct GoVersionTests {
    @Test("Resolves version priority: go.mod > go.work > toolchain, walking up parents (FR-2, L-4)")
    func resolvesVersionOrder() {
        let dir = TempDir()
        defer { dir.cleanup() }

        _ = dir.file("go.work", "go 1.22.5\n\nuse .\n")
        let fromWork = GoVersionResolver.resolve(projectRoot: dir.url, toolchainVersionProvider: { GoVersion(major: 1, minor: 23) })
        #expect(fromWork?.version == GoVersion(major: 1, minor: 22, patch: 5))
        #expect(fromWork?.source == .goWork)

        _ = dir.file("go.mod", "module example.com/app\n\ngo 1.21.4 // pinned\n")
        let sub = dir.subdir("cmd/server")
        let fromParentMod = GoVersionResolver.resolve(projectRoot: sub, toolchainVersionProvider: { GoVersion(major: 1, minor: 23) })
        #expect(fromParentMod?.version == GoVersion(major: 1, minor: 21, patch: 4))
        #expect(fromParentMod?.source == .goMod)

        let tcDir = TempDir()
        defer { tcDir.cleanup() }
        _ = tcDir.file("go.mod", "module example.com/tc\n\ntoolchain go1.23.2\n")
        let fromDirectiveToolchain = GoVersionResolver.resolve(projectRoot: tcDir.url, toolchainVersionProvider: { GoVersion(major: 1, minor: 21) })
        #expect(fromDirectiveToolchain?.version == GoVersion(major: 1, minor: 23, patch: 2))

        let emptyDir = TempDir()
        defer { emptyDir.cleanup() }
        let fromToolchain = GoVersionResolver.resolve(projectRoot: emptyDir.url, toolchainVersionProvider: { GoVersion(major: 1, minor: 23, patch: 1) })
        #expect(fromToolchain?.version == GoVersion(major: 1, minor: 23, patch: 1))
        #expect(fromToolchain?.source == .toolchain)

        // S-2: explicit nil-returning provider never falls through to blocking toolchain detection
        let noToolchain = GoVersionResolver.resolve(projectRoot: emptyDir.url, toolchainVersionProvider: { nil })
        #expect(noToolchain == nil)
    }

    @Test("Async version resolution works without blocking threads (S-2)")
    func resolvesVersionAsync() async {
        let dir = TempDir()
        defer { dir.cleanup() }
        let fromProvider = await GoVersionResolver.resolveAsync(projectRoot: dir.url, toolchainVersionProvider: { GoVersion(major: 1, minor: 23) })
        #expect(fromProvider?.version == GoVersion(major: 1, minor: 23))
        #expect(fromProvider?.source == .toolchain)

        let none = await GoVersionResolver.resolveAsync(projectRoot: dir.url, toolchainVersionProvider: { nil })
        #expect(none == nil)
    }

    @Test("Strictly rejects malformed version strings like 1.x.3 (L-4)")
    func rejectsMalformedVersions() {
        #expect(GoVersion(parsing: "1.x.3") == nil)
        #expect(GoVersion(parsing: "go1.2.3.4") == nil)
        #expect(GoVersion(parsing: "abc") == nil)
        #expect(GoVersion(parsing: "go1.22") == GoVersion(major: 1, minor: 22, patch: 0))
        #expect(GoVersion(parsing: "go version go1.23.4 darwin/arm64") == GoVersion(major: 1, minor: 23, patch: 4))
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

@Suite("DocsCorpus Extraction, Build Filters & Stable IDs")
struct DocsCorpusTests {
    @Test("Extracts const/var, multiline func, interface methods, builtin, exact Example*, and respects build tags (H-1, M-12..14, L-6)")
    func extractsRichStdlibDeclarations() {
        let dir = TempDir()
        defer { dir.cleanup() }

        let src = dir.subdir("src")
        _ = dir.file("src/io/io.go", """
        // Package io provides basic interfaces to I/O primitives.
        package io

        // EOF is the error returned by Read when no more input is available.
        var EOF = errors.New("EOF")

        // Seek whence values.
        const (
        \t// SeekStart means relative to the origin of the file.
        \tSeekStart   = 0
        \tSeekCurrent = 1 // relative to current offset
        \tprivateConst = 9
        )

        // Reader is the interface that wraps the basic Read method.
        type Reader interface {
        \tRead(p []byte) (n int, err error)
        }

        // CopyBuffer copies from src to dst using the provided buffer.
        func CopyBuffer(
        \tdst Writer,
        \tsrc Reader,
        \tbuf []byte,
        ) (written int64, err error) {
        \treturn 0, nil
        }
        """)
        _ = dir.file("src/bufio/scan.go", """
        // Package bufio implements buffered I/O.
        package bufio

        // Scanner reads lines from an io.Reader.
        type Scanner struct{}

        // Scan advances the Scanner to the next token.
        func (s *Scanner) Scan() bool { return false }

        // Err returns the first non-EOF error.
        func (s *Scanner) Err() error { return nil }
        """)
        _ = dir.file("src/bufio/example_test.go", """
        package bufio_test

        func ExampleScanner() {
        \t// brace in comment } and raw string `}` and rune '}'
        \tconst raw = `hello { world }`
        \t_ = '}'
        \ts := bufio.NewScanner(r)
        \tfor s.Scan() {
        \t\tfmt.Println(s.Text())
        \t}
        }
        """)
        _ = dir.file("src/builtin/builtin.go", """
        // Package builtin provides documentation for Go's predeclared identifiers.
        package builtin

        // Len returns the length of v.
        func Len(v any) int
        """)
        _ = dir.file("src/os/proc_windows.go", """
        package os
        // WindowsOnly should be excluded on darwin.
        func WindowsOnly() {}
        """)
        _ = dir.file("src/os/gen.go", """
        //go:build ignore

        package os
        // IgnoredGen should be excluded.
        func IgnoredGen() {}
        """)
        _ = dir.file("src/internal/secret/secret.go", """
        package secret
        func Secret() {}
        """)

        let chunks = DocsCorpusExtractor.extractStdlib(fromGorootSrc: src, goVersion: "1.23")

        // H-1: const and var extracted
        let eof = chunks.first { $0.packageName == "io" && $0.symbol == "EOF" }
        #expect(eof?.kind == .variable)
        let seekStart = chunks.first { $0.packageName == "io" && $0.symbol == "SeekStart" }
        #expect(seekStart?.kind == .constant)
        let seekCur = chunks.first { $0.packageName == "io" && $0.symbol == "SeekCurrent" }
        #expect(seekCur?.kind == .constant && stringContains(seekCur?.body ?? "", "relative to current offset"))
        #expect(!chunks.contains { $0.symbol == "privateConst" })

        // M-14: multiline func signature & interface method set preserved
        let copyBuf = chunks.first { $0.packageName == "io" && $0.symbol == "CopyBuffer" }
        #expect(stringContains(copyBuf?.signature ?? "", "(written int64, err error)"))
        let reader = chunks.first { $0.packageName == "io" && $0.symbol == "Reader" }
        #expect(stringContains(reader?.signature ?? "", "Read(p []byte) (n int, err error)"))

        // M-12: raw string/rune/comment braces handled AND type Example is NOT blindly inherited by unrelated methods
        let scannerType = chunks.first { $0.packageName == "bufio" && $0.symbol == "Scanner" }
        #expect(stringContains(scannerType?.example ?? "", "bufio.NewScanner"))
        let errMethod = chunks.first { $0.packageName == "bufio" && $0.symbol == "Scanner.Err" }
        #expect(errMethod?.example == nil)

        // L-6: builtin included; M-13: windows & //go:build ignore & internal excluded
        #expect(chunks.contains { $0.packageName == "builtin" && $0.symbol == "Len" })
        #expect(!chunks.contains { $0.symbol == "WindowsOnly" })
        #expect(!chunks.contains { $0.symbol == "IgnoredGen" })
        #expect(!chunks.contains { $0.packageName.contains("internal") })
        // R-9: extracted GOROOT chunks carry officialExtracted provenance (not bundled summary)
        #expect(eof?.provenance == .officialExtracted)
        #expect(!stringContains(eof?.citationLabel ?? "", "bundled summary"))
    }

    @Test("Evaluates parenthesized //go:build expressions, GOARCH, 2-part OS_ARCH filenames, and go1.x release tags (R-2, S-4, S-7)")
    func evaluatesCompoundGoBuildExpressions() {
        let darwinArm64 = GoBuildTarget(goos: "darwin", goarch: "arm64", goVersion: GoVersion(major: 1, minor: 23))
        let darwinAmd64 = GoBuildTarget(goos: "darwin", goarch: "amd64", goVersion: GoVersion(major: 1, minor: 23))
        let darwinArm121 = GoBuildTarget(goos: "darwin", goarch: "arm64", goVersion: GoVersion(major: 1, minor: 21))

        #expect(!DocsCorpusExtractor.evaluateGoBuildExpr("(windows && arm64)", target: darwinArm64))
        #expect(DocsCorpusExtractor.evaluateGoBuildExpr("!(windows || linux)", target: darwinArm64))
        #expect(DocsCorpusExtractor.evaluateGoBuildExpr("(darwin || linux) && arm64", target: darwinArm64))
        #expect(!DocsCorpusExtractor.evaluateGoBuildExpr("(darwin || linux) && arm64", target: darwinAmd64))
        #expect(!DocsCorpusExtractor.evaluateGoBuildExpr("darwin && !cgo", target: darwinArm64))
        #expect(DocsCorpusExtractor.evaluateGoBuildExpr("unix && (arm64 || amd64)", target: darwinArm64))

        // S-7: go1.x release tag comparison against target goVersion
        #expect(!DocsCorpusExtractor.evaluateGoBuildExpr("go1.23", target: darwinArm121))
        #expect(DocsCorpusExtractor.evaluateGoBuildExpr("go1.23", target: darwinArm64))
        #expect(DocsCorpusExtractor.evaluateGoBuildExpr("!go1.22", target: darwinArm121))
        #expect(!DocsCorpusExtractor.evaluateGoBuildExpr("!go1.22", target: darwinArm64))

        // S-4: 2-part OS_ARCH filenames like `windows_arm64.go` check BOTH GOOS and GOARCH
        #expect(!DocsCorpusExtractor.matchesBuildFilename("windows_arm64.go", target: darwinArm64))
        #expect(DocsCorpusExtractor.matchesBuildFilename("darwin_arm64.go", target: darwinArm64))
        #expect(!DocsCorpusExtractor.matchesBuildFilename("darwin_arm64.go", target: darwinAmd64))
        #expect(!DocsCorpusExtractor.matchesBuildFilename("foo_windows_arm64.go", target: darwinArm64))
        #expect(DocsCorpusExtractor.matchesBuildFilename("windows_arm64.go", target: GoBuildTarget(goos: "windows", goarch: "arm64")))

        let dir = TempDir()
        defer { dir.cleanup() }
        let src = dir.subdir("src")
        _ = dir.file("src/sys/win_arm64.go", """
        //go:build (windows && arm64)

        package sys
        func WinArmOnly() {}
        """)
        _ = dir.file("src/sys/windows_arm64.go", """
        package sys
        func TwoPartWinArmOnly() {}
        """)
        _ = dir.file("src/sys/future.go", """
        //go:build go1.23

        package sys
        func Go123Only() {}
        """)
        _ = dir.file("src/sys/ok_darwin.go", """
        //go:build (darwin || linux) && arm64

        package sys
        func DarwinArmOK() {}
        """)
        let extracted121 = DocsCorpusExtractor.extractStdlib(fromGorootSrc: src, goVersion: "1.21", target: GoBuildTarget(goos: "darwin", goarch: "arm64"))
        #expect(!extracted121.contains { $0.symbol == "WinArmOnly" })
        #expect(!extracted121.contains { $0.symbol == "TwoPartWinArmOnly" })
        #expect(!extracted121.contains { $0.symbol == "Go123Only" })
        #expect(extracted121.contains { $0.symbol == "DarwinArmOK" })

        let extracted123 = DocsCorpusExtractor.extractStdlib(fromGorootSrc: src, goVersion: "1.23", target: GoBuildTarget(goos: "darwin", goarch: "arm64"))
        #expect(extracted123.contains { $0.symbol == "Go123Only" })
    }

    @Test("Extracts grouped type (...) blocks including multiline func types and generics, multi-name const/var, and long interfaces (R-4, R-7, S-5, S-7)")
    func extractsTypeGroupsMultiNameDeclsAndLongInterfaces() {
        let dir = TempDir()
        defer { dir.cleanup() }
        let src = dir.subdir("src")

        var methods: [String] = []
        for i in 1...45 {
            methods.append("\tMethod\(i)() int")
        }
        let longInterface = """
        // Package ast declares types for Go syntax trees.
        package ast

        // Node types in a grouped declaration.
        type (
        \t// Node represents any syntax node.
        \tNode interface {
        \t\tPos() int
        \t}
        \t// Ident represents an identifier.
        \tIdent struct {
        \t\tName string
        \t}
        \t// Handler is a multiline function type inside a type group (S-5).
        \tHandler func(
        \t\tx int,
        \t\ty string,
        \t)
        \t// Box is a generic type inside a type group (S-7).
        \tBox[T comparable] struct {
        \t\tValue T
        \t}
        \t// Pair has a multiline generic parameter list on a struct (T-4).
        \tPair[
        \t\tK comparable,
        \t\tV any,
        \t] struct {
        \t\tKey K
        \t\tVal V
        \t}
        \t// MultiIface has a multiline generic parameter list on an interface (T-4).
        \tMultiIface[
        \t\tT any,
        \t] interface {
        \t\tGet() T
        \t}
        \t// AliasExpr aliases Ident.
        \tAliasExpr = Ident
        \tunexportedNode struct{}
        )

        // Multi-name constants and variables.
        const (
        \tAlpha, Beta = 1, 2
        )
        const SingleA, SingleB = "a", "b"
        var FirstErr, SecondErr error

        // BigInterface has more than 40 lines.
        type BigInterface interface {
        \(methods.joined(separator: "\n"))
        }
        """
        _ = dir.file("src/go/ast/ast.go", longInterface)

        let chunks = DocsCorpusExtractor.extractStdlib(fromGorootSrc: src, goVersion: "1.23")
        // R-4, S-5, S-7: grouped type (...) including multiline func type & generic struct extracted without premature close
        let node = chunks.first { $0.packageName == "go/ast" && $0.symbol == "Node" }
        let ident = chunks.first { $0.packageName == "go/ast" && $0.symbol == "Ident" }
        let handler = chunks.first { $0.packageName == "go/ast" && $0.symbol == "Handler" }
        let box = chunks.first { $0.packageName == "go/ast" && $0.symbol == "Box" }
        let pair = chunks.first { $0.packageName == "go/ast" && $0.symbol == "Pair" }
        let multiIface = chunks.first { $0.packageName == "go/ast" && $0.symbol == "MultiIface" }
        let alias = chunks.first { $0.packageName == "go/ast" && $0.symbol == "AliasExpr" }
        #expect(node?.kind == .type && stringContains(node?.signature ?? "", "Pos() int"))
        #expect(ident?.kind == .type && ident?.signature == "type Ident struct { ... }" && stringContains(ident?.summary ?? "", "identifier"))
        #expect(handler?.kind == .type && stringContains(handler?.signature ?? "", "y string"))
        #expect(box?.kind == .type && stringContains(box?.signature ?? "", "Box[T comparable]"))
        // T-4: multiline generic struct emits concise `{ ... }` without folding body fields; interface keeps methods
        #expect(pair?.kind == .type && stringContains(pair?.signature ?? "", "struct { ... }") && !stringContains(pair?.signature ?? "", "Key K"))
        #expect(multiIface?.kind == .type && stringContains(multiIface?.signature ?? "", "Get() T"))
        #expect(alias?.kind == .type)
        #expect(!chunks.contains { $0.symbol == "unexportedNode" })

        // R-7: multi-name const/var declarations extract all exported identifiers
        #expect(chunks.contains { $0.symbol == "Alpha" && $0.kind == .constant })
        #expect(chunks.contains { $0.symbol == "Beta" && $0.kind == .constant })
        #expect(chunks.contains { $0.symbol == "SingleA" && $0.kind == .constant })
        #expect(chunks.contains { $0.symbol == "SingleB" && $0.kind == .constant })
        #expect(chunks.contains { $0.symbol == "FirstErr" && $0.kind == .variable })
        #expect(chunks.contains { $0.symbol == "SecondErr" && $0.kind == .variable })

        // R-7: long interface preserves methods beyond line 40
        let big = chunks.first { $0.symbol == "BigInterface" }
        #expect(stringContains(big?.signature ?? "", "Method45() int"))
    }

    @Test("Preserves paired shortcode prose, ignores # inside code fences, and avoids cross-doc/duplicate heading collisions (H-6, M-10, M-11)")
    func markdownExtractionPreservesProseAndUniqueIDs() {
        let doc1 = """
        ---
        title: Effective Go
        ---
        ## For {#for}
        {{< note >}}Important prose inside shortcode.{{< /note >}}
        ```bash
        # this comment is inside a fence and not a heading
        echo ok
        ```
        ##### Sub detail
        Deep section body.

        ## For
        Second section with the same heading.
        """
        let doc2 = """
        ## For
        Tutorial for loop explanation.
        """
        let c1 = DocsCorpusExtractor.extractGuideMarkdown(text: doc1, documentTitle: "Effective Go", documentID: "effective_go", goVersion: "1.23")
        let c2 = DocsCorpusExtractor.extractGuideMarkdown(text: doc2, documentTitle: "Go Tutorial", documentID: "tutorial", goVersion: "1.23")

        // M-10: inner prose of paired shortcode preserved, tags removed
        #expect(c1.count == 3) // For, Sub detail (H5), For (#For-2)
        #expect(stringContains(c1[0].body, "Important prose inside shortcode."))
        #expect(!stringContains(c1[0].body, "{{<"))
        // M-11: fenced `# comment` stays inside first section rather than creating a new chunk
        #expect(stringContains(c1[0].body, "# this comment is inside a fence"))
        #expect(c1[1].symbol == "Sub detail")
        #expect(c1[2].anchor == "#For-2")

        // H-6: Effective Go `## For` and Tutorial `## For` have distinct stable IDs
        #expect(c1[0].stableID != c2[0].stableID)
    }

    @Test("contentHash tracks summary & searchAliases (M-8) and aliases with spaces round-trip losslessly (L-1, H-7)")
    func hashIncludesEmbeddingInputsAndAliasesRoundTrip() throws {
        let a = DocsChunk(
            goVersion: "1.23", source: .guide, packageName: "", documentID: "g",
            symbol: "for", kind: .guide, title: "For", anchor: "#for",
            summary: "Original summary", body: "Body", searchAliases: ["for loop", "range over int"]
        )
        let b = DocsChunk(
            goVersion: "1.23", source: .guide, packageName: "", documentID: "g",
            symbol: "for", kind: .guide, title: "For", anchor: "#for",
            summary: "Changed summary", body: "Body", searchAliases: ["for loop", "range over int"]
        )
        let c = DocsChunk(
            goVersion: "1.23", source: .guide, packageName: "", documentID: "g",
            symbol: "for", kind: .guide, title: "For", anchor: "#for",
            summary: "Original summary", body: "Body", searchAliases: ["for loop", "new alias"]
        )
        #expect(a.contentHash != b.contentHash)
        #expect(a.contentHash != c.contentHash)

        // L-1 & H-7: SQLite round-trip preserves aliases with spaces and stored contentHash verbatim
        let dir = TempDir()
        defer { dir.cleanup() }
        let idx = try DocsIndex(databaseURL: dir.url.appendingPathComponent("idx.sqlite"))
        defer { idx.close() }
        try idx.replaceAllChunks([a])
        let restored = try idx.chunk(forStableID: a.stableID)
        #expect(restored?.searchAliases == ["for loop", "range over int"])
        #expect(restored?.contentHash == a.contentHash)
    }
}

@Suite("Ingestion Batch, Concurrency Guards, WAL, GC & Shared Vector Store")
struct DocsBatchTests {
    @Test("Atomic swap failure leaves existing active pack intact and emits .failed (FR-6, FR-22, M-16)")
    func swapFailurePreservesActivePack() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let mgr = try makeDocsPackManager(in: dir)

        let v1Chunks = Array(BundledGoCorpus.chunks(forGoVersion: "1.23").prefix(5))
        _ = try await mgr.ingest(goVersion: "1.23", chunks: v1Chunks, embedder: nil)
        #expect(await mgr.manifest(for: "1.23")?.chunkCount == 5)

        let rec = ProgressRecorder()
        let v2Chunks = Array(BundledGoCorpus.chunks(forGoVersion: "1.23").prefix(10))
        var threw = false
        do {
            _ = try await mgr.ingest(goVersion: "1.23", chunks: v2Chunks, embedder: nil, simulateSwapFailure: true) { p in
                recordProgress(rec, p)
            }
        } catch {
            threw = true
        }
        #expect(threw)
        #expect(rec.phases.last == .failed)
        #expect(await mgr.manifest(for: "1.23")?.chunkCount == 5)

        // M-16: embedder exception also emits `.failed`
        let failRec = ProgressRecorder()
        var embedFailed = false
        do {
            _ = try await mgr.ingest(goVersion: "1.23", chunks: v1Chunks, embedder: FailingFakeEmbedder()) { p in
                recordProgress(failRec, p)
            }
        } catch {
            embedFailed = true
        }
        #expect(embedFailed)
        #expect(failRec.phases.last == .failed)
    }

    @Test("Concurrent re-entrant ingest for the same version is rejected (H-8)")
    func rejectsReentrantIngest() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let mgr = try makeDocsPackManager(in: dir)
        let chunks = Array(BundledGoCorpus.chunks(forGoVersion: "1.23").prefix(4))
        let slow = SlowFakeEmbedder(delayNs: 40_000_000)

        let first = Task {
            try await mgr.ingest(goVersion: "1.23", chunks: chunks, embedder: slow)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        var rejected = false
        do {
            _ = try await mgr.ingest(goVersion: "1.23", chunks: chunks, embedder: slow)
        } catch DocsStorageError.batchAlreadyRunning(let ver) {
            rejected = (ver == "1.23")
        }
        #expect(rejected)
        let report = try await first.value
        #expect(!report.cancelled)
    }

    @Test("Batch supports cancel/resume (FR-23, FR-25), WAL-complete initial FTS snapshot (M-7), and GC preserves paused staging vectors (H-9)")
    func batchCancelResumeAndGCProtection() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let mgr = try makeDocsPackManager(in: dir)
        let chunks = Array(BundledGoCorpus.chunks(forGoVersion: "1.23").prefix(8))

        let embedder = CountingFakeEmbedder(id: "embed-test", version: "1.0")
        embedder.configureCancel(manager: mgr, goVersion: "1.23", afterCalls: 3)

        let first = try await mgr.ingest(goVersion: "1.23", chunks: chunks, embedder: embedder)
        #expect(first.cancelled)
        #expect(first.computedVectors == 3)
        // M-7 & FR-28: initial FTS-only snapshot has all 8 chunks readable immediately after WAL checkpoint.
        #expect(await mgr.manifest(for: "1.23")?.status == .indexingFTSOnly)
        let ftsIdx = try await mgr.openIndex(for: "1.23")
        #expect(try ftsIdx?.chunkCount() == 8)
        ftsIdx?.close()

        // H-9: running GC while 1.23 has paused staging checkpoint MUST keep those 3 checkpointed vectors!
        let gcDuringPaused = try await mgr.garbageCollectSharedVectors()
        #expect(gcDuringPaused == 0)
        #expect(try await mgr.sharedVectorStore.count() == 3)

        // Resume: only the remaining 5 chunks call embedder.embed(_:)
        embedder.clearCancel()
        embedder.resetCount()
        let resumed = try await mgr.ingest(goVersion: "1.23", chunks: chunks, embedder: embedder)
        #expect(!resumed.cancelled)
        #expect(resumed.status == .ready)
        #expect(resumed.reusedVectors == 3)
        #expect(resumed.computedVectors == 5)
        #expect(embedder.callCount == 5)
    }

    @Test("Incremental diff updates only changed chunks (M-9) and model switch persists across restarts (FR-27, M-15)")
    func incrementalDiffAndPersistentModelSwitch() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let mgr = try makeDocsPackManager(in: dir)
        let base = Array(BundledGoCorpus.chunks(forGoVersion: "1.23").prefix(6))
        let embedderV1 = CountingFakeEmbedder(id: "embed-m", version: "v1")

        _ = try await mgr.ingest(goVersion: "1.23", chunks: base, embedder: embedderV1)

        var updated = Array(base.dropLast())
        updated[0] = DocsChunk(
            goVersion: "1.23", source: updated[0].source, packageName: updated[0].packageName,
            documentID: updated[0].documentID, symbol: updated[0].symbol, kind: updated[0].kind,
            title: updated[0].title, anchor: updated[0].anchor, since: updated[0].since,
            summary: updated[0].summary + " (revised)", signature: updated[0].signature,
            example: updated[0].example, body: updated[0].body + "\nRevised detail."
        )

        embedderV1.resetCount()
        let diffReport = try await mgr.ingest(goVersion: "1.23", chunks: updated, embedder: embedderV1)
        #expect(diffReport.changedChunks == 1)
        #expect(diffReport.removedChunks == 1)
        #expect(diffReport.unchangedChunks == 4)
        #expect(diffReport.computedVectors == 1)
        #expect(diffReport.reusedVectors == 4)
        #expect(embedderV1.callCount == 1)

        // M-15: switching model clears pack vector refs, demotes manifest, and persists selection across restart.
        let needsRebuild = try await mgr.selectEmbeddingModel(EmbeddingModelDescriptor(id: "embed-m", version: "v2"))
        #expect(needsRebuild)
        let mAfter = await mgr.manifest(for: "1.23")
        #expect(mAfter?.status == .indexingFTSOnly)
        #expect(mAfter?.embeddingModelID == nil)

        let reopened = try reopenDocsPackManager(at: await mgr.rootDirectory)
        #expect(await reopened.currentEmbeddingModel() == EmbeddingModelDescriptor(id: "embed-m", version: "v2"))
        let reopenedIdx = try await reopened.openIndex(for: "1.23")
        #expect(try reopenedIdx?.vectorReferences().isEmpty == true)
        reopenedIdx?.close()
    }

    @Test("Cross-version real-diff corpus reuses unchanged vectors and recomputes only changed chunks (H-3, FR-30, FR-31)")
    func crossVersionRealDiffVectorReuseAndGC() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let mgr = try makeDocsPackManager(in: dir)
        let embedder = CountingFakeEmbedder(id: "shared-embed", version: "v1")

        // Build two realistic GOROOT trees where 1 package changes between Go 1.22 and Go 1.23.
        let g122 = TempDir()
        let g123 = TempDir()
        defer { g122.cleanup(); g123.cleanup() }

        let sharedBufio = """
        // Package bufio implements buffered I/O.
        package bufio
        // Scanner provides an interface for reading lines.
        type Scanner struct{}
        // NewScanner returns a new Scanner to read from r.
        func NewScanner(r any) *Scanner { return nil }
        """
        _ = g122.file("src/bufio/scan.go", sharedBufio)
        _ = g123.file("src/bufio/scan.go", sharedBufio)

        _ = g122.file("src/slices/slices.go", """
        // Package slices defines slice helpers.
        package slices
        // Compact replaces consecutive runs of equal elements.
        func Compact[S ~[]E, E comparable](s S) S { return s }
        """)
        _ = g123.file("src/slices/slices.go", """
        // Package slices defines slice helpers.
        package slices
        // Compact replaces consecutive runs of equal elements (Go 1.23 zeroing note).
        func Compact[S ~[]E, E comparable](s S) S { return s }
        """)

        let c122 = DocsCorpusExtractor.extractStdlib(fromGorootSrc: g122.url.appendingPathComponent("src"), goVersion: "1.22")
        let r122 = try await mgr.ingest(goVersion: "1.22", chunks: c122, embedder: embedder)
        #expect(r122.computedVectors == c122.count)

        embedder.resetCount()
        let c123 = DocsCorpusExtractor.extractStdlib(fromGorootSrc: g123.url.appendingPathComponent("src"), goVersion: "1.23")
        let r123 = try await mgr.ingest(goVersion: "1.23", chunks: c123, embedder: embedder)
        // Only the 1 modified slices.Compact chunk is recomputed; all unchanged chunks are reused!
        #expect(r123.computedVectors == 1)
        #expect(r123.reusedVectors == c123.count - 1)
        #expect(embedder.callCount == 1)

        // Delete 1.22 -> only the old slices.Compact vector becomes orphan and is reclaimed.
        let gc1 = try await mgr.deletePack(goVersion: "1.22")
        #expect(gc1 == 1)
        let gc2 = try await mgr.deletePack(goVersion: "1.23")
        #expect(gc2 == c123.count)
        #expect(try await mgr.sharedVectorStore.count() == 0)
    }

    @Test("Batch vector lookup returns all requested keys across >500 batch boundary and omits missing ones (R-5, S-7)")
    func batchVectorStoreLookup() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let store = try SharedVectorStore(databaseURL: dir.url.appendingPathComponent("shared.sqlite"))
        let m1 = EmbeddingModelDescriptor(id: "m", version: "1")
        let m2 = EmbeddingModelDescriptor(id: "m", version: "2")

        var keys: [SharedVectorKey] = []
        for i in 0..<620 {
            let k = SharedVectorKey(contentHash: "h\(i)", model: m1)
            try await store.store(key: k, vector: [Float(i), 1.0])
            keys.append(k)
        }
        let otherModelKey = SharedVectorKey(contentHash: "h_other", model: m2)
        try await store.store(key: otherModelKey, vector: [0, 0, 1])
        keys.append(otherModelKey)

        let missing = SharedVectorKey(contentHash: "missing", model: m1)
        let fetched = try await store.vectors(for: keys + [missing, keys[0]])
        #expect(fetched.count == 621)
        #expect(fetched[keys[0]] == [0, 1.0])
        #expect(fetched[keys[499]] == [499, 1.0])
        #expect(fetched[keys[500]] == [500, 1.0])
        #expect(fetched[keys[619]] == [619, 1.0])
        #expect(fetched[otherModelKey] == [0, 0, 1])
        #expect(fetched[missing] == nil)
    }

    @Test("Legacy v2 migrates provenance in place, v1 stays flagged for re-import, and corrupt pack errors are isolated (S-1, T-1, T-2)")
    func legacyV2PackMigratesProvenanceAccurately() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let mgr = try makeDocsPackManager(in: dir)
        let root = await mgr.rootDirectory

        let realGorootChunk = DocsChunk(
            goVersion: "1.23", source: .stdlib, provenance: .officialExtracted,
            packageName: "io", symbol: "EOF", kind: .variable,
            title: "io.EOF", anchor: "io.EOF", summary: "EOF from real GOROOT.",
            body: "EOF is the error returned by Read when no more input is available."
        )
        let bundledSpec = try #require(BundledGoCorpus.chunks(forGoVersion: "1.23").first { $0.source == .spec && $0.symbol == "for" })

        // Install 3 packs: a corrupt v2 (1.24, sorted first), a healthy v2 (1.23), and a true v1 (1.21)
        try createCorruptLegacyV2Pack(in: root, goVersion: "1.24")
        try createLegacyV2Pack(in: root, goVersion: "1.23", chunks: [realGorootChunk, bundledSpec])
        try createLegacyV1Pack(in: root, goVersion: "1.21")

        #expect(await mgr.manifest(for: "1.23")?.schemaVersion == 2)
        #expect(await mgr.manifest(for: "1.21")?.needsReimport == true)

        let report = await mgr.migrateLegacyPacksIfNeeded()
        // T-2: corrupt 1.24 fails without aborting 1.23 migration
        #expect(report.failedVersions["1.24"] != nil)
        #expect(report.migratedVersions == ["1.23"])
        // T-1: true v1 pack is NOT falsely bumped to v3; stays flagged for re-import
        #expect(report.legacyV1ReimportVersions == ["1.21"])
        #expect(await mgr.manifest(for: "1.21")?.schemaVersion == 1)
        #expect(await mgr.manifest(for: "1.21")?.needsReimport == true)

        #expect(await mgr.manifest(for: "1.23")?.schemaVersion == DocsPackManifest.currentSchemaVersion)
        let idx = try await mgr.openIndex(for: "1.23")
        defer { idx?.close() }
        let restoredReal = try idx?.chunk(forStableID: realGorootChunk.stableID)
        let restoredBundled = try idx?.chunk(forStableID: bundledSpec.stableID)
        #expect(restoredReal?.provenance == .officialExtracted)
        #expect(!stringContains(restoredReal?.citationLabel ?? "", "bundled summary"))
        #expect(restoredBundled?.provenance == .bundledCurated)
        #expect(stringContains(restoredBundled?.citationLabel ?? "", "[og bundled summary]"))
    }

    @Test("Deleting pack during in-flight ingest removes staging and reclaims vectors; ingest does not silently overwrite selectedEmbeddingModel (R-8)")
    func deleteDuringInFlightIngestCleansStagingAndNoSilentModelOverwrite() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let mgr = try makeDocsPackManager(in: dir)
        let chunks = Array(BundledGoCorpus.chunks(forGoVersion: "1.23").prefix(6))

        let embedder = CountingFakeEmbedder(id: "ephemeral-embed", version: "v1")
        embedder.configureDelete(manager: mgr, goVersion: "1.23", afterCalls: 2)

        let report = try await mgr.ingest(goVersion: "1.23", chunks: chunks, embedder: embedder)
        #expect(report.cancelled)
        // R-8: ingest must not silently overwrite selectedEmbeddingModel
        #expect(await mgr.currentEmbeddingModel() == nil)
        // R-8: staging directory and all vectors from the deleted in-flight pack must be cleaned up
        let stageDir = await mgr.stagingDirectory(for: "1.23")
        #expect(!pathExists(stageDir))
        #expect(await mgr.manifest(for: "1.23") == nil)
        #expect(try await mgr.sharedVectorStore.count() == 0)
    }
}

@Suite("Real GOROOT Integration, Semantic Search, Loopback & Golden Queries")
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

    @Test("Integration (§8.2, H-3): English-only GOROOT extraction -> ingestion -> Japanese & symbol lookup without bundled aliases")
    func realGorootEnglishOnlyIntegration() async throws {
        let goroot = TempDir()
        let packDir = TempDir()
        let proj = TempDir()
        defer { goroot.cleanup(); packDir.cleanup(); proj.cleanup() }
        _ = proj.file("go.mod", "module example.com/real\n\ngo 1.23\n")

        _ = goroot.file("src/bufio/scan.go", """
        // Package bufio implements buffered I/O.
        package bufio
        // Scanner provides a convenient interface for reading data such as a file of newline-delimited lines of text.
        type Scanner struct{}
        // NewScanner returns a new Scanner to read from r.
        func NewScanner(r any) *Scanner { return nil }
        """)
        _ = goroot.file("src/bufio/example_test.go", """
        package bufio_test
        func ExampleScanner() {
        \tscanner := bufio.NewScanner(r)
        \tfor scanner.Scan() {
        \t\tfmt.Println(scanner.Text())
        \t}
        }
        """)
        _ = goroot.file("src/encoding/json/encode.go", """
        // Package json implements encoding and decoding of JSON.
        package json
        // MarshalIndent is like Marshal but applies Indent to format the output.
        func MarshalIndent(v any, prefix, indent string) ([]byte, error) { return nil, nil }
        // An Encoder writes JSON values to an output stream. Call SetIndent to indent output.
        type Encoder struct{}
        """)
        _ = goroot.file("src/context/context.go", """
        // Package context defines the Context type, which carries deadlines and cancellation signals.
        package context
        // WithTimeout returns WithDeadline(parent, time.Now().Add(timeout)).
        func WithTimeout(parent Context, timeout any) (Context, func()) { return nil, nil }
        """)
        _ = goroot.file("src/regexp/regexp.go", """
        // Package regexp implements regular expression search.
        package regexp
        // Compile parses a regular expression and returns a Regexp object.
        func Compile(expr string) (*Regexp, error) { return nil, nil }
        """)
        _ = goroot.file("src/io/io.go", """
        // Package io provides basic interfaces to I/O primitives.
        package io
        // EOF is the error returned by Read when no more input is available.
        var EOF = errors.New("EOF")
        """)
        _ = goroot.file("src/net/http/method.go", """
        package http
        // Common HTTP methods.
        const (
        \tMethodGet  = "GET"
        \tMethodPost = "POST"
        )
        """)

        // Extract purely from English Go sources (NO BundledGoCorpus, NO Japanese aliases!)
        let extracted = DocsCorpusExtractor.extractStdlib(
            fromGorootSrc: goroot.url.appendingPathComponent("src"),
            goVersion: "1.23"
        )
        let mgr = try makeDocsPackManager(in: packDir)
        _ = try await mgr.ingest(goVersion: "1.23", chunks: extracted, embedder: nil)
        let svc = ResearchService(packManager: mgr, enabled: true)

        // Japanese intent queries work against pure English GoDoc via router expansion!
        let r1 = try await svc.search(query: "ファイルを1行ずつ読みたい", projectRoot: proj.url)
        #expect(r1.status == .found && r1.cards.first?.packageName == "bufio" && r1.cards.first?.symbol == "Scanner")

        let r2 = try await svc.search(query: "JSON を整形して出したい", projectRoot: proj.url)
        #expect(r2.status == .found && r2.cards.contains { $0.packageName == "encoding/json" && ($0.symbol == "MarshalIndent" || $0.symbol == "Encoder") })

        let r3 = try await svc.search(query: "処理にタイムアウトを付けたい", projectRoot: proj.url)
        #expect(r3.status == .found && r3.cards.first?.packageName == "context" && r3.cards.first?.symbol == "WithTimeout")

        let r4 = try await svc.search(query: "標準ライブラリに正規表現ある？", projectRoot: proj.url)
        #expect(r4.status == .found && r4.cards.first?.packageName == "regexp")

        // Extracted const/var symbols are directly searchable (H-1)
        let rEOF = try await svc.search(query: "io.EOF", projectRoot: proj.url)
        #expect(rEOF.status == .found && rEOF.cards.first?.symbol == "EOF")

        let rMethod = try await svc.search(query: "http.MethodGet", projectRoot: proj.url)
        #expect(rMethod.status == .found && rMethod.cards.first?.symbol == "MethodGet")
        // R-9: real GOROOT cards report officialExtracted provenance without bundled summary suffix
        #expect(rMethod.cards.first?.provenance == .officialExtracted)
        #expect(!stringContains(rMethod.cards.first?.citation ?? "", "bundled summary"))

        // T-3: invalid JSON in concept_rules.json surfaces a parse error instead of failing silently
        try writeRawText("{invalid json", to: await mgr.conceptRulesURL())
        let fallbackRules = await mgr.loadConceptRules()
        #expect(fallbackRules.count == BundledGoCorpus.defaultConceptRules.count)
        let parseErr = await mgr.conceptRulesLoadError()
        #expect(parseErr != nil && stringContains(parseErr ?? "", "concept_rules.json"))

        // R-1 & S-3: valid global/per-pack JSON rules clear the error and apply live on search without code changes
        try await mgr.saveCustomConceptRules([DocsConceptRule(triggers: ["ハッシュ計算"], expansions: ["MethodGet"])])
        #expect(await mgr.conceptRulesLoadError() == nil)
        let rGlobalRule = try await svc.search(query: "ハッシュ計算したい", projectRoot: proj.url)
        #expect(rGlobalRule.status == .found && rGlobalRule.cards.first?.symbol == "MethodGet")

        let packRuleURL = await mgr.packConceptRulesURL(for: "1.23")
        try writeConceptRulesJSON([DocsConceptRule(triggers: ["終端判定"], expansions: ["EOF"])], to: packRuleURL)
        let rPackRule = try await svc.search(query: "終端判定したい", projectRoot: proj.url)
        #expect(rPackRule.status == .found && rPackRule.cards.first?.symbol == "EOF")

        // Explicit API override also works
        let customRule = DocsConceptRule(triggers: ["カスタム概念"], expansions: ["MethodPost"])
        await svc.setConceptRules(BundledGoCorpus.defaultConceptRules + [customRule])
        let rCustom = try await svc.search(query: "カスタム概念したい", projectRoot: proj.url)
        #expect(rCustom.status == .found && rCustom.cards.first?.symbol == "MethodPost")
    }

    @Test("Semantic retrieval integration, model switch demotion, and anti-hallucination gating (M-1, M-2, L-12)")
    func semanticSearchAndEdgeCases() async throws {
        let dir = TempDir()
        let proj = TempDir()
        defer { dir.cleanup(); proj.cleanup() }
        _ = proj.file("go.mod", "module example.com/sem\n\ngo 1.23\n")

        let mgr = try makeDocsPackManager(in: dir)
        let embedder = SemanticTopicEmbedder(id: "topic-embed", version: "v1")
        _ = try await mgr.ingest(goVersion: "1.23", chunks: BundledGoCorpus.chunks(forGoVersion: "1.23"), embedder: embedder)

        let svc = ResearchService(packManager: mgr, enabled: true)
        await svc.setEmbedder(embedder)

        // Ready pack + matching embedder -> hybridSemantic mode
        let hybrid = try await svc.search(query: "read file line by line", projectRoot: proj.url)
        #expect(hybrid.status == .found)
        #expect(hybrid.searchMode == .hybridSemantic)
        #expect(hybrid.language == .english)
        #expect(stringContains(hybrid.conclusion, "Found for go1.23"))
        #expect(hybrid.cards.first?.symbol == "Scanner")

        // M-1: even with semantic search active, a non-existent feature existence query MUST return .notFound!
        let fakeExistence = try await svc.search(query: "標準ライブラリに量子テレポーテーション制御ある？", projectRoot: proj.url)
        #expect(fakeExistence.status == .notFound)
        #expect(fakeExistence.cards.isEmpty)

        // L-12: empty query returns gentle notFound with 0 cards
        let empty = try await svc.search(query: "   ", projectRoot: proj.url)
        #expect(empty.status == .notFound && empty.cards.isEmpty)

        // L-12: editorContext provides a weak local ranking signal without external calls
        let ctx = DocsEditorContext.parse(goSource: "package main\nimport (\n\t\"encoding/json\"\n)\n")
        #expect(ctx.packageName == "main" && ctx.importedPackages == ["encoding/json"])
        let withCtx = try await svc.search(query: "JSON を整形して出したい", projectRoot: proj.url, editorContext: ctx)
        #expect(withCtx.status == .found && withCtx.cards.first?.packageName == "encoding/json")

        // M-2 & FR-27: switching embedding model immediately drops searchMode back to .ftsOnly
        _ = try await mgr.selectEmbeddingModel(EmbeddingModelDescriptor(id: "topic-embed", version: "v2"))
        let afterSwitch = try await svc.search(query: "read file line by line", projectRoot: proj.url)
        #expect(afterSwitch.status == .found)
        #expect(afterSwitch.searchMode == .ftsOnly)
    }

    @Test("Golden queries (§8.3): UC-1, UC-2, UC-3, version gate, citations, and snippet formatting (L-11)")
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
            // R-9: bundled curated pack cards explicitly distinguish provenance from official extracted GoDoc
            #expect(card.provenance == .bundledCurated)
            #expect(stringContains(card.citation, "[og bundled summary]"))
        }

        // L-7: Go 1.21 pack does not contain Go 1.22 release notes
        let idx121 = try await mgr.openIndex(for: "1.21")
        let chunks121 = try idx121?.allChunks() ?? []
        idx121?.close()
        #expect(!chunks121.contains { $0.source == .release && $0.since == "1.22" })

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
            let prepared = await DocsCodeInserter.prepareSnippetAsync(from: top, targetVersion: GoVersion(major: 1, minor: 23))
            #expect(prepared != nil && stringContains(prepared?.code ?? "", "bufio.NewScanner"))
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

        // Opt-in disabled & missing pack guard
        await svc.setEnabled(false)
        let disabledAns = try await svc.search(query: "ファイルを1行ずつ読みたい", projectRoot: proj123.url)
        #expect(disabledAns.status == .disabled && disabledAns.cards.isEmpty)
        await svc.setEnabled(true)

        let proj120 = TempDir()
        defer { proj120.cleanup() }
        _ = proj120.file("go.mod", "module example.com/v120\n\ngo 1.20\n")
        let missing = try await svc.search(query: "for ループの書き方", projectRoot: proj120.url)
        if case .missingPack(let req, _) = missing.status {
            #expect(req.minorKey == "1.20")
        } else {
            Issue.record("Expected .missingPack for go 1.20")
        }
    }
}

@Suite("Phase 2: Semantic Search, Cross-Encoder Reranking & Real GOROOT Smoke")
struct DocsPhase2Tests {
    @Test("LoopbackRerankerClient and DocsModelServerCommand enforce loopback-only and valid MLX argv (D-9, D-10, DOC-6)")
    func rerankerClientAndServerCommandEnforceLoopback() throws {
        #expect(LoopbackRerankerClient(endpoint: url("http://127.0.0.1:9090")!, modelID: "m") != nil)
        #expect(LoopbackRerankerClient(endpoint: url("http://localhost:9090")!, modelID: "m") != nil)
        #expect(LoopbackRerankerClient(endpoint: url("http://[::1]:9090")!, modelID: "m") != nil)
        #expect(LoopbackRerankerClient(endpoint: url("https://api.example.com")!, modelID: "m") == nil)
        #expect(LoopbackRerankerClient(endpoint: url("http://10.0.0.5:9090")!, modelID: "m") == nil)

        let dir = TempDir()
        defer { dir.cleanup() }
        let locator = makeFakeToolLocator(with: "uvx", in: dir)
        let scriptURL = dir.subdir("docs-server").appendingPathComponent("og_docs_server.py")
        let cfg = DocsServerConfig()
        let argv = try DocsModelServerCommand.argv(for: cfg, port: 43210, scriptURL: scriptURL, locator: locator)

        #expect(pathExists(scriptURL))
        #expect(!argv.contains("--offline"))
        #expect(argv.contains("--host"))
        #expect(argv.contains("127.0.0.1"))
        #expect(argv.contains("--port"))
        #expect(argv.contains("43210"))
        #expect(argv.contains(DocsEmbedModelPreset.default.id))
        #expect(argv.contains("--rerank-model"))
        #expect(argv.contains(DocsRerankModelPreset.default.id))

        // W-8: cached launches pass `--offline` to uvx
        let offlineArgv = try DocsModelServerCommand.argv(for: cfg, port: 43210, offline: true, scriptURL: scriptURL, locator: locator)
        #expect(offlineArgv.contains("--offline"))
    }

    @Test("DocsServerRestartPolicy enforces sliding crash window and exponential backoff (V-5)")
    func docsServerRestartPolicyWindowAndBackoff() {
        var policy = DocsServerRestartPolicy(maxFailures: 3, windowSeconds: 120, baseBackoffSeconds: 1.0)
        // Rapid Ready->crash loop inside 120s window hits maxFailures=3 and stops
        let r1 = policy.recordFailure(at: makeTestDate(offsetSeconds: 0))
        #expect(r1.shouldRetry && r1.delaySeconds == 1.0 && r1.failureCount == 1)
        let r2 = policy.recordFailure(at: makeTestDate(offsetSeconds: 10))
        #expect(r2.shouldRetry && r2.delaySeconds == 2.0 && r2.failureCount == 2)
        let r3 = policy.recordFailure(at: makeTestDate(offsetSeconds: 20))
        #expect(!r3.shouldRetry && r3.failureCount == 3)

        // After the 120s sliding window expires, old failures are pruned and restart budget recovers
        let r4 = policy.recordFailure(at: makeTestDate(offsetSeconds: 200))
        #expect(r4.shouldRetry && r4.failureCount == 1 && r4.delaySeconds == 1.0)

        policy.reset()
        #expect(policy.failureTimestamps.isEmpty)
    }

    @Test("Batch embedder degrades to single-item embed when embedBatch fails (W-5)")
    func batchEmbeddingDegradesToSingleItemOnFailure() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let mgr = try makeDocsPackManager(in: dir)
        let chunks = Array(BundledGoCorpus.chunks(forGoVersion: "1.23").prefix(6))
        let embedder = BatchFailingThenSingleEmbedder(id: "fallback-embed", version: "v1", batchSize: 4)

        let report = try await mgr.ingest(goVersion: "1.23", chunks: chunks, embedder: embedder)
        #expect(report.status == .ready)
        #expect(report.computedVectors == 6)
        #expect(embedder.batchFailures == 2) // batches of 4 + 2 both degraded
        #expect(embedder.singleCalls == 6)
    }

    @Test("Loopback HTTP clients handle /v1/embeddings, /v1/rerank, block 3xx redirects, and fall back on 500/bad JSON/empty/timeout (V-3, V-7, W-9)")
    func loopbackClientsHTTPMockRedirectAndErrorFallbacks() async throws {
        let server = try LocalMockHTTPServer { method, path, body in
            if method == "GET" && path == "/health" {
                return LocalMockHTTPResponse(statusCode: 200, bodyString: #"{"status":"ok","rerank_ready":true}"#)
            }
            if method == "POST" && path == "/v1/embeddings" {
                if stringContains(body, "[\"") {
                    return LocalMockHTTPResponse(
                        statusCode: 200,
                        bodyString: #"{"data":[{"index":1,"embedding":[0.0,1.0]},{"index":0,"embedding":[1.0,0.0]}]}"#
                    )
                }
                return LocalMockHTTPResponse(
                    statusCode: 200,
                    bodyString: #"{"data":[{"index":0,"embedding":[1.0,0.0]}]}"#
                )
            }
            if method == "POST" && path == "/v1/rerank" {
                return LocalMockHTTPResponse(
                    statusCode: 200,
                    bodyString: #"{"results":[{"index":1,"relevance_score":0.92},{"index":0,"relevance_score":0.31}]}"#
                )
            }
            return LocalMockHTTPResponse(statusCode: 404, statusText: "Not Found", bodyString: #"{"error":"not found"}"#)
        }
        defer { server.stop() }

        let desc = EmbeddingModelDescriptor(id: "mock-bge", version: "v1")
        let embedClient = try #require(LoopbackEmbeddingClient(endpoint: server.baseURL, descriptor: desc, timeoutInterval: 2))
        let rerankClient = try #require(LoopbackRerankerClient(endpoint: server.baseURL, modelID: "mock-rr", timeoutInterval: 0.4))

        // 1. Happy path over real local HTTP
        #expect(await ModelServerCommand.healthy(server.baseURL.appendingPathComponent("health")))
        let singleVec = try await embedClient.embedQuery("json decode")
        #expect(singleVec == [1.0, 0.0])
        let batchVecs = try await embedClient.embedBatch(["first", "second"])
        #expect(batchVecs == [[1.0, 0.0], [0.0, 1.0]])
        let rrHits = try await rerankClient.rerank(query: "json", documents: ["doc0", "doc1"], topN: 2)
        #expect(rrHits.count == 2)
        #expect(rrHits[0].index == 1 && rrHits[0].score > 0.9)
        #expect(rrHits[1].index == 0 && rrHits[1].score < 0.4)

        // 2. V-3: 302 redirect to an external host MUST be blocked (never followed off-machine)
        server.setHandler { _, _, _ in
            LocalMockHTTPResponse(
                statusCode: 302,
                statusText: "Found",
                headers: ["Location": "https://example.com/exfiltrate"],
                bodyString: ""
            )
        }
        #expect(!(await ModelServerCommand.healthy(server.baseURL.appendingPathComponent("health"))))
        var embedBlockedRedirect = false
        do { _ = try await embedClient.embedQuery("secret code") } catch { embedBlockedRedirect = true }
        #expect(embedBlockedRedirect)
        var rerankBlockedRedirect = false
        do { _ = try await rerankClient.rerank(query: "secret", documents: ["doc"], topN: 1) } catch { rerankBlockedRedirect = true }
        #expect(rerankBlockedRedirect)

        // 3. W-9: ResearchService falls back cleanly on HTTP 500, malformed JSON, empty results, and timeout
        let dir = TempDir()
        let proj = TempDir()
        defer { dir.cleanup(); proj.cleanup() }
        _ = proj.file("go.mod", "module example.com/httpfb\n\ngo 1.23\n")
        let mgr = try makeDocsPackManager(in: dir)
        _ = try await mgr.ensureBundledPackInstalled(goVersion: "1.23")
        let svc = ResearchService(packManager: mgr, enabled: true)
        await svc.setReranker(rerankClient)

        // 3a. HTTP 500
        server.setHandler { _, _, _ in
            LocalMockHTTPResponse(statusCode: 500, statusText: "Internal Server Error", bodyString: #"{"error":"boom"}"#)
        }
        let fb500 = try await svc.search(query: "ファイルを1行ずつ読みたい", projectRoot: proj.url)
        #expect(fb500.status == .found && !fb500.usedReranker && fb500.cards.first?.symbol == "Scanner")

        // 3b. Malformed JSON
        server.setHandler { _, _, _ in
            LocalMockHTTPResponse(statusCode: 200, bodyString: "{not-valid-json")
        }
        let fbBadJSON = try await svc.search(query: "ファイルを1行ずつ読みたい", projectRoot: proj.url)
        #expect(fbBadJSON.status == .found && !fbBadJSON.usedReranker && fbBadJSON.cards.first?.symbol == "Scanner")

        // 3c. Empty results
        server.setHandler { _, _, _ in
            LocalMockHTTPResponse(statusCode: 200, bodyString: #"{"results":[]}"#)
        }
        let fbEmpty = try await svc.search(query: "ファイルを1行ずつ読みたい", projectRoot: proj.url)
        #expect(fbEmpty.status == .found && !fbEmpty.usedReranker && fbEmpty.cards.first?.symbol == "Scanner")

        // 3d. Timeout (handler sleeps 1.0s > client 0.4s timeout)
        server.setHandler { _, _, _ in
            LocalMockHTTPResponse(statusCode: 200, bodyString: #"{"results":[{"index":0,"relevance_score":0.9}]}"#, delaySeconds: 1.0)
        }
        let fbTimeout = try await svc.search(query: "ファイルを1行ずつ読みたい", projectRoot: proj.url)
        #expect(fbTimeout.status == .found && !fbTimeout.usedReranker && fbTimeout.cards.first?.symbol == "Scanner")

        // 4. Embedder HTTP 500 & timeout fallback: Ready pack degrades cleanly to Phase 1 FTS5 without failing search
        server.setHandler { method, path, body in
            if method == "POST" && path == "/v1/embeddings" {
                let count = stringContains(body, "[\"") ? max(1, body.split(separator: "\",").count) : 1
                let items = (0..<count).map { #"{"index":\#($0),"embedding":[1.0,0.0]}"# }.joined(separator: ",")
                return LocalMockHTTPResponse(statusCode: 200, bodyString: #"{"data":[\#(items)]}"#)
            }
            return LocalMockHTTPResponse(statusCode: 404, statusText: "Not Found", bodyString: "{}")
        }
        let shortEmbedClient = try #require(LoopbackEmbeddingClient(endpoint: server.baseURL, descriptor: desc, timeoutInterval: 0.4))
        let readySubset = Array(BundledGoCorpus.chunks(forGoVersion: "1.23").prefix(12))
        let readyRep = try await mgr.ingest(goVersion: "1.23", chunks: readySubset, embedder: shortEmbedClient)
        #expect(readyRep.status == .ready)
        await svc.setReranker(nil)
        await svc.setEmbedder(shortEmbedClient)

        // 4a. /v1/embeddings HTTP 500 -> falls back to .ftsOnly
        server.setHandler { _, _, _ in
            LocalMockHTTPResponse(statusCode: 500, statusText: "Internal Server Error", bodyString: #"{"error":"embed failed"}"#)
        }
        let embFb500 = try await svc.search(query: "ファイルを1行ずつ読みたい", projectRoot: proj.url)
        #expect(embFb500.status == .found && embFb500.searchMode == .ftsOnly && embFb500.cards.first?.symbol == "Scanner")

        // 4b. /v1/embeddings timeout (1.0s > 0.4s) -> falls back to .ftsOnly
        server.setHandler { _, _, _ in
            LocalMockHTTPResponse(statusCode: 200, bodyString: #"{"data":[{"index":0,"embedding":[1.0,0.0]}]}"#, delaySeconds: 1.0)
        }
        let embFbTimeout = try await svc.search(query: "ファイルを1行ずつ読みたい", projectRoot: proj.url)
        #expect(embFbTimeout.status == .found && embFbTimeout.searchMode == .ftsOnly && embFbTimeout.cards.first?.symbol == "Scanner")

        // 5. V-7: exportChunksJSON exports installed pack chunks for scripts/eval-docs-phase2.py
        let exportURL = dir.url.appendingPathComponent("exported-chunks.json")
        let exportedCount = try await mgr.exportChunksJSON(forGoVersion: "1.23", to: exportURL)
        #expect(exportedCount == readySubset.count)
        #expect(pathExists(exportURL))
        let exportedText = readFile(exportURL) ?? ""
        #expect(stringContains(exportedText, "stable_id") && stringContains(exportedText, "rerank_text"))
    }

    @Test("Vector store SQLite failure falls back cleanly to Phase 1 FTS instead of crashing search (V-4)")
    func vectorStoreFailureFallsBackToPhase1FTS() async throws {
        let dir = TempDir()
        let proj = TempDir()
        defer { dir.cleanup(); proj.cleanup() }
        _ = proj.file("go.mod", "module example.com/v4\n\ngo 1.23\n")

        let mgr = try makeDocsPackManager(in: dir)
        let embedder = SemanticTopicEmbedder(id: "topic-v4", version: "v1")
        _ = try await mgr.ingest(goVersion: "1.23", chunks: BundledGoCorpus.chunks(forGoVersion: "1.23"), embedder: embedder)

        // Break shared_vectors table so index.semanticSearch(...) throws a SQLite error
        try corruptSharedVectorStoreTable(at: await mgr.sharedVectorStore.databaseURL)

        let svc = ResearchService(packManager: mgr, enabled: true)
        await svc.setEmbedder(embedder)

        let ans = try await svc.search(query: "ファイルを1行ずつ読みたい", projectRoot: proj.url)
        #expect(ans.status == .found)
        #expect(ans.searchMode == .ftsOnly)
        #expect(ans.cards.first?.packageName == "bufio" && ans.cards.first?.symbol == "Scanner")
    }

    @Test("DocsCorpusExtractor skips underscore/dot non-package directories like _gen and _asm (Go tool convention)")
    func skipsUnderscoreNonPackageDirectories() {
        let dir = TempDir()
        defer { dir.cleanup() }
        let src = dir.subdir("src")
        _ = dir.file("src/simd/archsimd/_gen/gen.go", "package gen\n// Generated helper.\nfunc InvalidOut() {}\n")
        _ = dir.file("src/crypto/sha1/_asm/asm.go", "package asm\n// Asm helper.\nfunc Calc() {}\n")
        _ = dir.file("src/encoding/json/decode.go", "// Package json implements JSON.\npackage json\n// Unmarshal parses JSON.\nfunc Unmarshal(data []byte, v any) error { return nil }\n")

        let extracted = DocsCorpusExtractor.extractStdlib(fromGorootSrc: src, goVersion: "1.23")
        #expect(!extracted.contains { $0.symbol == "InvalidOut" || $0.symbol == "Calc" })
        #expect(extracted.contains { $0.packageName == "encoding/json" && $0.symbol == "Unmarshal" })
    }

    @Test("Batch embedder and reembedExistingPack upgrade an FTS-only pack in place (FR-27, FR-30)")
    func batchEmbeddingAndReembedExistingPack() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let mgr = try makeDocsPackManager(in: dir)
        let chunks = Array(BundledGoCorpus.chunks(forGoVersion: "1.23").prefix(10))

        // Start as FTS-only
        let r0 = try await mgr.ingest(goVersion: "1.23", chunks: chunks, embedder: nil)
        #expect(r0.status == .indexingFTSOnly)

        // Upgrade in place via batch embedder
        let batchEmbedder = BatchCountingFakeEmbedder(id: "batch-m3", version: "v1", batchSize: 4)
        let r1 = try await mgr.reembedExistingPack(goVersion: "1.23", embedder: batchEmbedder)
        #expect(r1?.status == .ready)
        #expect(r1?.computedVectors == 10)
        // 10 chunks with batchSize=4 -> 3 batch calls (4 + 4 + 2)
        #expect(batchEmbedder.batchCalls == 3)
        #expect(await mgr.manifest(for: "1.23")?.embeddingModelID == "batch-m3")
    }

    @Test("Two-stage pipeline: reranker ranks json.Unmarshal/Decoder above json.Encoder, preserves version gate, rejects nonexistent queries, and falls back safely (Issue #21, DOC-10)")
    func twoStageRerankingGoldenBehaviorAndFallback() async throws {
        let dir = TempDir()
        let proj123 = TempDir()
        let proj121 = TempDir()
        defer { dir.cleanup(); proj123.cleanup(); proj121.cleanup() }
        _ = proj123.file("go.mod", "module example.com/p123\n\ngo 1.23\n")
        _ = proj121.file("go.mod", "module example.com/p121\n\ngo 1.21\n")

        let mgr = try makeDocsPackManager(in: dir)
        let embedder = SemanticTopicEmbedder(id: "bge-m3-stub", version: "v1")
        _ = try await mgr.ingest(goVersion: "1.23", chunks: BundledGoCorpus.chunks(forGoVersion: "1.23"), embedder: embedder)
        _ = try await mgr.ingest(goVersion: "1.21", chunks: BundledGoCorpus.chunks(forGoVersion: "1.21"), embedder: embedder)

        let svc = ResearchService(packManager: mgr, enabled: true)
        await svc.setEmbedder(embedder)

        let reranker = StubDocsReranker { query, doc in
            let q = query.lowercased()
            let d = doc.lowercased()
            if q.contains("デコード") && q.contains("json") {
                if d.contains("unmarshal") || d.contains("decoder") { return 0.98 }
                if d.contains("encoder") { return 0.72 }
                return 0.15
            }
            if q.contains("1行ずつ") {
                if d.contains("scanner") { return 0.95 }
                return 0.05
            }
            if q.contains("for") || q.contains("ループ") {
                if d.contains("for statements") || d.contains("effective go: for") { return 0.90 }
                return 0.05
            }
            if q.contains("量子テレポーテーション") || q.contains("スマートコントラクト") {
                return 0.001
            }
            return 0.50
        }
        await svc.setReranker(reranker)

        // 1. Issue #21 primary motivation: 「json のデコード」 -> Unmarshal/Decoder ranked #1 above Encoder (V-7: non-vacuous)
        let jsonDecode = try await svc.search(query: "json のデコード", projectRoot: proj123.url)
        #expect(jsonDecode.status == .found)
        #expect(jsonDecode.usedReranker)
        #expect(jsonDecode.searchMode == .hybridReranked)
        #expect(jsonDecode.cards.first?.packageName == "encoding/json")
        #expect(jsonDecode.cards.first?.symbol == "Unmarshal" || jsonDecode.cards.first?.symbol == "Decoder")
        let encIdx = try #require(jsonDecode.cards.firstIndex(where: { $0.symbol == "Encoder" }))
        #expect(encIdx > 0)

        // 2. Regression check: 「ファイルを1行ずつ読みたい」 -> bufio.Scanner #1
        let readLine = try await svc.search(query: "ファイルを1行ずつ読みたい", projectRoot: proj123.url)
        #expect(readLine.status == .found && readLine.usedReranker)
        #expect(readLine.cards.first?.packageName == "bufio" && readLine.cards.first?.symbol == "Scanner")

        // 3. Version gate MUST hold even with reranker enabled (FB-DOC-7)
        let for121 = try await svc.search(query: "for ループの書き方", projectRoot: proj121.url)
        #expect(for121.status == .found && for121.usedReranker)
        #expect(!for121.cards.contains { $0.symbol == "for range int" || $0.symbol == "for range func" })
        #expect(for121.newerVersionNotes.contains { $0.since == GoVersion(major: 1, minor: 22) })

        // 4. Non-existent feature query MUST return honest Not Found with 0 cards
        let neg = try await svc.search(query: "標準ライブラリに量子テレポーテーション制御ある？", projectRoot: proj123.url)
        #expect(neg.status == .notFound && neg.cards.isEmpty && !neg.usedReranker)

        // 5. Reranker failure falls back cleanly to Stage 1 without throwing (DOC-10)
        await svc.setReranker(FailingDocsReranker())
        let fallback = try await svc.search(query: "ファイルを1行ずつ読みたい", projectRoot: proj123.url)
        #expect(fallback.status == .found && !fallback.usedReranker && fallback.searchMode == .hybridSemantic)
        #expect(fallback.cards.first?.symbol == "Scanner")

        // 6. Both embedder & reranker disabled -> Phase 1 FTS5 behavior
        await svc.setEmbedder(nil)
        await svc.setReranker(nil)
        let phase1 = try await svc.search(query: "ファイルを1行ずつ読みたい", projectRoot: proj123.url)
        #expect(phase1.status == .found && !phase1.usedReranker && phase1.searchMode == .ftsOnly)
        #expect(phase1.cards.first?.symbol == "Scanner")
    }

    @Test(
        "Real GOROOT smoke test: Phase 1 FTS + Phase 2 semantic/rerank on local GOROOT (Issue #21, V-8)",
        .enabled(if: realGorootSrcURL() != nil, "Requires local Go toolchain (GOROOT/src)")
    )
    func realGorootSmokeTest() async throws {
        let srcURL = try #require(realGorootSrcURL())
        let targetPkgs = ["bufio", "encoding/json", "context", "regexp", "slices"]
        var stdlib: [DocsChunk] = []
        for pkg in targetPkgs {
            let pkgDir = srcURL.appendingPathComponent(pkg, isDirectory: true)
            if pathExists(pkgDir) {
                stdlib.append(contentsOf: DocsCorpusExtractor.extractStdlibPackage(
                    directory: pkgDir,
                    importPath: pkg,
                    goVersion: "1.23"
                ))
            }
        }
        #expect(!stdlib.isEmpty)
        #expect(stdlib.contains { $0.packageName == "bufio" && $0.symbol == "Scanner" })
        #expect(stdlib.contains { $0.packageName == "encoding/json" && $0.symbol == "Unmarshal" })
        #expect(stdlib.contains { $0.packageName == "encoding/json" && $0.symbol == "Decoder" })

        let dir = TempDir()
        let proj = TempDir()
        defer { dir.cleanup(); proj.cleanup() }
        _ = proj.file("go.mod", "module example.com/smoke\n\ngo 1.23\n")

        let extractedIDs = Set(stdlib.map(\.stableID))
        let combined = stdlib + BundledGoCorpus.chunks(forGoVersion: "1.23").filter { $0.source != .stdlib || !extractedIDs.contains($0.stableID) }
        let mgr = try makeDocsPackManager(in: dir)
        let report = try await mgr.ingest(goVersion: "1.23", chunks: combined, embedder: nil)
        #expect(report.totalChunks == combined.count)

        let svc = ResearchService(packManager: mgr, enabled: true)
        let r1 = try await svc.search(query: "ファイルを1行ずつ読みたい", projectRoot: proj.url)
        #expect(r1.status == .found && r1.cards.first?.packageName == "bufio" && r1.cards.first?.symbol == "Scanner")
        #expect(r1.cards.first?.provenance == .officialExtracted)

        let r2 = try await svc.search(query: "処理にタイムアウトを付けたい", projectRoot: proj.url)
        #expect(r2.status == .found && r2.cards.first?.packageName == "context" && r2.cards.first?.symbol == "WithTimeout")

        let r3 = try await svc.search(query: "標準ライブラリに正規表現ある？", projectRoot: proj.url)
        #expect(r3.status == .found && r3.cards.first?.packageName == "regexp")

        let rNeg = try await svc.search(query: "標準ライブラリに量子テレポーテーション制御ある？", projectRoot: proj.url)
        #expect(rNeg.status == .notFound && rNeg.cards.isEmpty)

        // V-8: Exercise Phase 2 (semantic + reranker) on real extracted GOROOT chunks
        let embedder = SemanticTopicEmbedder(id: "goroot-smoke-embed", version: "v1")
        let reembedReport = try await mgr.reembedExistingPack(goVersion: "1.23", embedder: embedder)
        #expect(reembedReport?.status == .ready)
        await svc.setEmbedder(embedder)
        await svc.setReranker(StubDocsReranker { query, doc in
            let q = query.lowercased()
            let d = doc.lowercased()
            if q.contains("デコード") && q.contains("json") {
                if d.contains("unmarshal") || d.contains("decoder") { return 0.96 }
                if d.contains("encoder") { return 0.60 }
                return 0.05
            }
            if q.contains("1行ずつ") {
                return d.contains("bufio.scanner") ? 0.95 : 0.05
            }
            if q.contains("量子テレポーテーション") { return 0.001 }
            return 0.40
        })

        let p2Decode = try await svc.search(query: "json のデコード", projectRoot: proj.url)
        #expect(p2Decode.status == .found && p2Decode.searchMode == .hybridReranked && p2Decode.usedReranker)
        #expect(p2Decode.cards.first?.packageName == "encoding/json")
        #expect(p2Decode.cards.first?.symbol == "Unmarshal" || p2Decode.cards.first?.symbol == "Decoder")
        #expect(p2Decode.cards.first?.provenance == .officialExtracted)

        let p2Neg = try await svc.search(query: "標準ライブラリに量子テレポーテーション制御ある？", projectRoot: proj.url)
        #expect(p2Neg.status == .notFound && p2Neg.cards.isEmpty && !p2Neg.usedReranker)
    }
}
