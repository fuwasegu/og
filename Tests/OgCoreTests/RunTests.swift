import Testing
@testable import OgCore

@Suite struct RunTests {
    // Recorded from `go test -json ./...` (go 1.27) on a module with a failing table test.
    static let recorded = """
    {"Action":"start","Package":"example.com/demo"}
    {"Action":"start","Package":"example.com/demo/empty"}
    {"Action":"output","Package":"example.com/demo/empty","Output":"?   \\texample.com/demo/empty\\t[no test files]\\n"}
    {"Action":"skip","Package":"example.com/demo/empty","Elapsed":0}
    {"Action":"run","Package":"example.com/demo","Test":"TestAdd"}
    {"Action":"output","Package":"example.com/demo","Test":"TestAdd","Output":"=== RUN   TestAdd\\n","OutputType":"frame"}
    {"Action":"pass","Package":"example.com/demo","Test":"TestAdd","Elapsed":0}
    {"Action":"run","Package":"example.com/demo","Test":"TestTable"}
    {"Action":"run","Package":"example.com/demo","Test":"TestTable/one_plus_one"}
    {"Action":"output","Package":"example.com/demo","Test":"TestTable/one_plus_one","Output":"    main_test.go:17: checking one plus one\\n"}
    {"Action":"pass","Package":"example.com/demo","Test":"TestTable/one_plus_one","Elapsed":0}
    {"Action":"run","Package":"example.com/demo","Test":"TestTable/bad_case"}
    {"Action":"output","Package":"example.com/demo","Test":"TestTable/bad_case","Output":"    main_test.go:19: got 2 want 5\\n","OutputType":"error"}
    {"Action":"fail","Package":"example.com/demo","Test":"TestTable/bad_case","Elapsed":0.01}
    {"Action":"fail","Package":"example.com/demo","Test":"TestTable","Elapsed":0.02}
    {"Action":"run","Package":"example.com/demo","Test":"TestSkip"}
    {"Action":"skip","Package":"example.com/demo","Test":"TestSkip","Elapsed":0}
    {"Action":"output","Package":"example.com/demo","Output":"FAIL\\texample.com/demo\\t0.335s\\n","OutputType":"frame"}
    {"Action":"fail","Package":"example.com/demo","Elapsed":0.335}
    {"Action":"run","Package":"example.com/demo/sub","Test":"TestMul/nested/deep"}
    {"Action":"pass","Package":"example.com/demo/sub","Test":"TestMul/nested/deep","Elapsed":0}

    """

    static func parse(_ text: String, chunk: Int = 29) -> (GoTestEventParser, String) {
        var p = GoTestEventParser()
        var console = ""
        var rest = Substring(text)
        while !rest.isEmpty {
            let piece = rest.prefix(chunk)
            rest = rest.dropFirst(chunk)
            console += p.consume(String(piece)).map(\.text).joined()
        }
        console += p.finish().map(\.text).joined()
        return (p, console)
    }

    @Test func buildsPackageTestSubtestTree() {
        let (p, console) = Self.parse(Self.recorded)
        let r = p.report
        #expect(r.packages.map(\.package) == ["example.com/demo", "example.com/demo/empty", "example.com/demo/sub"])
        let table = GoTestNodeID(package: "example.com/demo", test: "TestTable")
        #expect(r.children(of: table).map(\.test) == ["TestTable/one_plus_one", "TestTable/bad_case"])
        #expect(r[table]?.status == .failed)
        #expect(r[table]?.elapsed == 0.02)
        #expect(r[GoTestNodeID(package: "example.com/demo", test: "TestTable/bad_case")]?.name == "bad_case")
        #expect(r[GoTestNodeID(package: "example.com/demo/empty")]?.status == .skipped)
        #expect(r[GoTestNodeID(package: "example.com/demo", test: "TestSkip")]?.status == .skipped)
        // Missing ancestors are created for deep subtests.
        #expect(r.children(of: GoTestNodeID(package: "example.com/demo/sub", test: "TestMul")).map(\.test) == ["TestMul/nested"])
        #expect(console.contains("FAIL\texample.com/demo"))
    }

    @Test func outputIsAttributedToTestAndAncestors() {
        let r = Self.parse(Self.recorded).0.report
        let bad = GoTestNodeID(package: "example.com/demo", test: "TestTable/bad_case")
        #expect(r[bad]?.output == "    main_test.go:19: got 2 want 5\n")
        #expect(r[GoTestNodeID(package: "example.com/demo", test: "TestTable")]?.output.contains("got 2 want 5") == true)
        #expect(r[GoTestNodeID(package: "example.com/demo")]?.output.contains("got 2 want 5") == true)
        #expect(r[GoTestNodeID(package: "example.com/demo", test: "TestAdd")]?.output.contains("got 2") == false)
    }

    @Test func summaryCountsTests() {
        let s = Self.parse(Self.recorded).0.report.summary
        // TestAdd, one_plus_one, deep. TestMul and TestMul/nested never reported (cut-off stream).
        #expect(s.passed == 3)
        #expect(s.failed == 2)
        #expect(s.skipped == 1)
        #expect(s.interrupted == 2)
        #expect(s.failedPackages == 0)
    }

    @Test func unfinishedTestsAreInterrupted() {
        var p = GoTestEventParser()
        _ = p.consume("{\"Action\":\"run\",\"Package\":\"p\",\"Test\":\"TestHang\"}")
        _ = p.finish() // trailing line without newline is still parsed
        #expect(p.report[GoTestNodeID(package: "p", test: "TestHang")]?.status == .interrupted)
    }

    @Test func buildFailureMarksPackage() {
        var p = GoTestEventParser()
        let out = p.consume("""
        {"ImportPath":"example.com/broken [example.com/broken.test]","Action":"build-output","Output":"./x_test.go:5:28: undefined: undefinedThing\\n"}
        {"ImportPath":"example.com/broken [example.com/broken.test]","Action":"build-fail"}
        {"Action":"fail","Package":"example.com/broken","Elapsed":0}
        not json

        """)
        #expect(out.first?.package == "example.com/broken")
        #expect(out.contains { $0.raw && $0.text == "not json\n" })
        #expect(p.report[GoTestNodeID(package: "example.com/broken")]?.status == .failed)
        #expect(p.report.summary.failedPackages == 1)
    }

    @Test func generationDropsStaleEvents() {
        var g = RunGeneration()
        let first = g.begin()
        let second = g.begin() // rerun
        #expect(!g.accepts(first))
        #expect(g.accepts(second))
        g.close() // stop
        #expect(!g.accepts(second))
    }

    @Test func anchoredRunPattern() {
        #expect(RunCommand.anchoredPattern("TestA") == "TestA")
        #expect(RunCommand.anchoredPattern("TestA/sub.case") == "TestA$/^sub\\.case")
    }

    @Test func utf8DecoderHandlesSplitCharacters() {
        var d = UTF8StreamDecoder()
        var text = ""
        for b in Array("a日😀".utf8) { text += d.decode([b]) }
        text += d.flush()
        #expect(text == "a日😀")
    }

    @Test func ansiParserKeepsColorsAndDropsOtherEscapes() {
        var p = ANSIParser()
        let segs = p.parse("\u{1B}[32mhel") + p.parse("lo\u{1B}[") + p.parse("0m x\u{1B}]0;title\u{07}\u{1B}[2K!\r\n")
        #expect(segs.map(\.text).joined() == "hello x!\n")
        #expect(segs.first?.style.foreground == .indexed(2))
        #expect(segs.last?.style.foreground == nil)
        var q = ANSIParser()
        let s = q.parse("\u{1B}[1;38;5;196mA\u{1B}[38;2;1;2;3mB\u{1B}[91mC")
        #expect(s.map(\.style.foreground) == [.indexed(196), .rgb(1, 2, 3), .indexed(9)])
        #expect(s.allSatisfy(\.style.bold))
        #expect(ANSIParser.strip("\u{1B}[31mred\u{1B}[0m") == "red")
    }

    @Test func fileLinksUseUTF16Ranges() {
        let text = "日本 sub/a.go:3:1 x\n    main_test.go:19: got\n\t/abs/p_test.go:7 +0x2c http://h:80 a.gopher:1"
        let links = ConsoleFileLink.scan(text)
        #expect(links.map(\.path) == ["sub/a.go", "main_test.go", "/abs/p_test.go"])
        #expect(links[0].line == 3 && links[0].column == 1)
        #expect(links[0].utf16Range == 3..<15)
        #expect(links[1].column == nil)
        let resolved = links[1].resolve(in: [], fileExists: { _ in true })
        #expect(resolved == nil) // relative path needs a directory
    }

    @Test func locatesTestFunctionsAndSubtests() {
        let src = """
        package main

        func helper() {}

        func TestTable(t *testing.T) {
        \tcases := []struct{ name string }{
        \t\t{"one plus one"},
        \t}
        \tt.Run("nested", func(t *testing.T) {})
        }

        func (s *Suite) TestMethod() {}
        """
        #expect(GoTestLocator.functionLine(named: "TestTable", in: src) == 4)
        #expect(GoTestLocator.functionLine(named: "TestMethod", in: src) == 11)
        #expect(GoTestLocator.functionLine(named: "TestNope", in: src) == nil)
        #expect(GoTestLocator.subtestLine(named: "one_plus_one", in: src, from: 4) == 6)
        #expect(GoTestLocator.subtestLine(named: "nested", in: src, from: 4) == 8)
        #expect(GoTestLocator.subtestLine(named: "missing", in: src, from: 4) == nil)
        #expect(GoTestLocator.modulePath(fromGoMod: "// c\nmodule example.com/m // x\n\ngo 1.22\n") == "example.com/m")
    }

    @Test func formatsDurations() {
        #expect(GoTestNode.formatElapsed(0.335) == "335 ms")
        #expect(GoTestNode.formatElapsed(1.5) == "1.50 s")
        #expect(GoTestNode.formatElapsed(125) == "2 m 5 s")
    }

    @Test func exitCodeFromWaitStatus() {
        #expect(RunProcess.exitCode(fromWaitStatus: 1 << 8) == 1)
        #expect(RunProcess.exitCode(fromWaitStatus: 15) == 143) // SIGTERM
    }
}
