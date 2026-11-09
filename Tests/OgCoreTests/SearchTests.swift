import Testing
@testable import OgCore

@Suite struct FuzzyMatcherTests {
    private func rank(_ query: String, _ paths: [String]) -> [String] {
        var m = FuzzyMatcher()
        let q = FuzzyQuery(query)
        return paths.compactMap { p in m.score(q, FuzzyCandidate(p)).map { (p, $0) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.utf16.count < $1.0.utf16.count }
            .map(\.0)
    }

    @Test func prefersFileNameMatches() {
        #expect(rank("index", ["index/server/handler.go", "internal/pkg/index.go"]).first == "internal/pkg/index.go")
        #expect(rank("pi", ["Sources/OgApp/Shell/ProjectContext.swift", "Sources/OgCore/Search/ProjectIndex.swift"]).first
                == "Sources/OgCore/Search/ProjectIndex.swift")
    }

    @Test func boundariesAndConsecutiveRunsWin() {
        let paths = ["src/GotoFilePalette.swift", "src/go_to_file.go", "src/gxoxtxo.go"]
        #expect(rank("gfp", paths).first == "src/GotoFilePalette.swift")
        #expect(rank("goto", paths).last == "src/gxoxtxo.go")
    }

    @Test func shorterPathWinsTies() {
        #expect(rank("main", ["a/b/c/main.go", "cmd/main.go"]) == ["cmd/main.go", "a/b/c/main.go"])
    }

    @Test func smartCase() {
        var m = FuzzyMatcher()
        #expect(m.score(FuzzyQuery("index"), FuzzyCandidate("a/Index.go")) != nil)
        #expect(m.score(FuzzyQuery("Index"), FuzzyCandidate("a/index.go")) == nil)
        #expect(m.score(FuzzyQuery("xyz"), FuzzyCandidate("a/b.go")) == nil)
    }

    @Test func offsetsAreUTF16() {
        #expect(FuzzyMatcher.match("pidx", in: "Search/ProjectIndex.swift")?.offsets == [7, 14, 16, 18])
        #expect(FuzzyMatcher.match("日本", in: "docs/日本語.md")?.offsets == [5, 6])
        #expect(FuzzyMatcher.match("😀x", in: "a/😀x.go")?.offsets == [2, 3, 4])
    }

    @Test func traceAgreesWithScore() {
        var m = FuzzyMatcher()
        let samples = [("ab", "a_b/ab.go"), ("abc", "AbC/aXbYc"), ("ccc", "c/c.c/cc"), ("ba", "b/a/ba")]
        for (q, t) in samples {
            #expect(m.score(FuzzyQuery(q), FuzzyCandidate(t)) == m.match(FuzzyQuery(q), FuzzyCandidate(t))?.score)
        }
    }
}

@Suite struct TextSearchTests {
    private let text = "foo Foo fooBar\nbar foo_x\n日本語 foo\n"

    private func positions(_ query: String, _ options: SearchOptions) throws -> [String] {
        let q = try TextSearch.compile(query, options: options)
        return TextSearch.hits(in: text, url: SearchFixtures.url, query: q).map { "\($0.line):\($0.column):\($0.length)" }
    }

    @Test func literalCaseInsensitiveByDefault() throws {
        #expect(try positions("foo", SearchOptions()).count == 5)
    }

    @Test func caseSensitiveAndWholeWord() throws {
        var o = SearchOptions()
        o.caseSensitive = true
        #expect(try positions("foo", o).count == 4)
        o.wholeWord = true
        #expect(try positions("foo", o) == ["0:0:3", "2:4:3"])  // UTF-16 column after 日本語
    }

    @Test func regexWithAnchors() throws {
        var o = SearchOptions()
        o.regex = true
        #expect(try positions("^bar\\s+\\w+", o) == ["1:0:9"])
        #expect(TextSearch.validate("(", options: o) != nil)
        #expect(TextSearch.validate("(a)", options: o) == nil)
    }

    @Test func literalQueriesEscapeRegexSyntax() throws {
        #expect(try positions(".", SearchOptions()).isEmpty)
    }

    @Test func replaceRegexTemplateAndLiteral() throws {
        var o = SearchOptions()
        o.regex = true
        let r = TextSearch.replace(in: "a1 b2", query: try TextSearch.compile("([a-z])(\\d)", options: o), replacement: "$2$1", regexTemplate: true)
        #expect(r.text == "1a 2b" && r.count == 2)
        let l = TextSearch.replace(in: "x.y x.y", query: try TextSearch.compile("x.y", options: SearchOptions()), replacement: "$1", regexTemplate: false)
        #expect(l.text == "$1 $1" && l.count == 2)
    }

    @Test func longLinesAreClippedAroundTheMatch() throws {
        let long = String(repeating: "x", count: 5000) + "needle"
        let hits = TextSearch.hits(in: long, url: SearchFixtures.url, query: try TextSearch.compile("needle", options: SearchOptions()))
        #expect(hits.count == 1)
        #expect(hits.first?.column == 5000)
        #expect(hits.first?.lineTextOffset == 4880)
        #expect(hits.first?.lineText.hasSuffix("needle") == true)
    }

    @Test func prefilterHasNoFalseNegatives() throws {
        let q = try TextSearch.compile("HeLLo", options: SearchOptions())
        #expect(TextSearch.mayContain(SearchFixtures.data("hhhhHELLO"), q))
        #expect(TextSearch.mayContain(SearchFixtures.data("say hello"), q))
        #expect(!TextSearch.mayContain(SearchFixtures.data("help"), q))
        var cs = SearchOptions()
        cs.caseSensitive = true
        #expect(!TextSearch.mayContain(SearchFixtures.data("hello"), try TextSearch.compile("HeLLo", options: cs)))
    }

    @Test func fileMasks() {
        let m = FileMask("*.go, !*_test.go")
        #expect(m.matches("a/b.go"))
        #expect(!m.matches("a/b_test.go"))
        #expect(!m.matches("a/README.md"))
        #expect(FileMask("cmd/*.go").matches("cmd/x.go"))
        #expect(!FileMask("cmd/*.go").matches("pkg/x.go"))
        #expect(FileMask(nil).isEmpty && FileMask(" , ").isEmpty)
    }
}

@Suite struct ProjectIndexTests {
    @Test func walkSearchAndReplacePlan() async throws {
        let root = try SearchFixtures.makeProject([
            "a.go": "package a\nfunc Foo() {}\n// Foo foo\n",
            "pkg/b.go": "package pkg\nvar x = Foo\n",
            "vendor/x/v.go": "Foo",
            "node_modules/m/i.js": "Foo",
            ".hidden/h.go": "Foo",
        ])
        defer { SearchFixtures.remove(root) }
        let index = ProjectIndex(root: root)
        #expect(await index.allFiles() == ["a.go", "pkg/b.go"])
        #expect(await index.fuzzy("pb").first?.relativePath == "pkg/b.go")

        var o = SearchOptions()
        o.caseSensitive = true
        o.wholeWord = true
        let hits = await index.search("Foo", options: o)
        #expect(hits.map { "\($0.url.lastPathComponent):\($0.line):\($0.column)" } == ["a.go:1:5", "a.go:2:3", "b.go:1:8"])
        #expect(await index.search("Foo", options: o, limit: 1).count == 1)

        let plans = await index.planReplace("Foo", options: o, replacement: "Bar")
        #expect(plans.map(\.count) == [2, 1])
        #expect(plans.first?.replaced == "package a\nfunc Bar() {}\n// Bar foo\n")
    }
}
