import Testing
@testable import OgCore

@Suite struct RenameTransactionTests {
    @Test func appliesUnorderedEditsWithMultiByteText() {
        // "日本😀" is 4 UTF-16 units, so `foo` on line 0 starts at character 9.
        let src = "x := 日本😀foo\nfoo(foo)\n"
        let out = RenameTransaction.applyEdits([edit(1, 4, 1, 7, "bar"), edit(0, 9, 0, 12, "bar"), edit(1, 0, 1, 3, "bar")], to: src)
        #expect(out == "x := 日本😀bar\nbar(bar)\n")
    }

    @Test func insertsAtSamePositionKeepArrayOrder() {
        #expect(RenameTransaction.applyEdits([edit(0, 0, 0, 0, "a"), edit(0, 0, 0, 0, "b")], to: "z") == "abz")
    }

    @Test func overlappingEditsDoNotCorruptText() {
        #expect(RenameTransaction.applyEdits([edit(0, 0, 0, 3, "X"), edit(0, 1, 0, 2, "Y")], to: "abcd") == "aYcd")
    }

    @Test func crlfAndOutOfRange() {
        #expect(RenameTransaction.applyEdits([edit(1, 0, 1, 1, "Q")], to: "a\r\nb\r\n") == "a\r\nQ\r\n")
        #expect(RenameTransaction.applyEdits([edit(9, 0, 9, 0, "!")], to: "a") == "a!")
    }

    @Test func previewUsesEditorTextAndDiffs() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        var lines = (1...20).map { "line \($0)" }
        lines[2] = "foo()"
        lines[15] = "x := foo"
        let a = dir.file("a.go", lines.joined(separator: "\n") + "\n")
        let b = dir.file("b.go", "package b\nvar foo = 1\n")
        let unchanged = dir.file("c.go", "package c\n")
        let edits = LSPWorkspaceEdit(changes: [
            uri(a): [edit(2, 0, 2, 3, "bar"), edit(15, 5, 15, 8, "bar")],
            uri(b): [edit(1, 4, 1, 7, "bar")],
            uri(unchanged): [edit(0, 0, 0, 0, "")],
        ])
        let pv = RenameTransaction.preview(edits) { $0.lastPathComponent == "b.go" ? "package b\nvar foo = 1 // editor\n" : nil }
        try #require(pv.count == 2)
        #expect(pv[0].url == standardized(a))
        #expect(pv[1].newText == "package b\nvar bar = 1 // editor\n")
        let d = pv[0].unifiedDiff
        #expect(textContains(d, "@@ -1,6 +1,6 @@\n line 1\n line 2\n-foo()\n+bar()\n line 4\n line 5\n line 6\n"))
        #expect(textContains(d, "@@ -13,7 +13,7 @@\n line 13\n line 14\n line 15\n-x := foo\n+x := bar\n line 17\n"))
        #expect(textContains(pv[1].unifiedDiff, "@@ -1,2 +1,2 @@\n package b\n-var foo = 1 // editor\n+var bar = 1 // editor\n"))
    }

    @Test func applyAndUndo() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let a = dir.file("a.go", "package a\nvar foo = 1\n")
        let b = dir.file("b.go", "package b\nvar x = foo\n")
        let record = try RenameTransaction.apply([preview(a, "package a\nvar bar = 1\n"), preview(b, "package b\nvar x = bar\n")])
        #expect(readFile(a) == "package a\nvar bar = 1\n")
        #expect(readFile(b) == "package b\nvar x = bar\n")
        #expect(listDir(dir.url) == ["a.go", "b.go"])          // no temp files left
        #expect(record.originals[a] == "package a\nvar foo = 1\n")
        try RenameTransaction.undo(record)
        #expect(readFile(a) == "package a\nvar foo = 1\n")
        #expect(readFile(b) == "package b\nvar x = foo\n")
    }

    @Test func stagingFailureLeavesEverythingUntouched() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let a = dir.file("a.go", "A\n")
        let ro = dir.subdir("ro")
        let c = dir.file("ro/c.go", "C\n")
        setReadOnlyDirectory(ro, true)
        defer { setReadOnlyDirectory(ro, false) }
        do {
            _ = try RenameTransaction.apply([preview(a, "A2\n"), preview(c, "C2\n")])
            Issue.record("expected stageFailed")
        } catch let RenameError.stageFailed(u, _) {
            #expect(u == c)
        }
        #expect(readFile(a) == "A\n")
        #expect(readFile(c) == "C\n")
        #expect(listDir(dir.url) == ["a.go", "ro"])            // a.go's temp was deleted
        #expect(listDir(ro) == ["c.go"])
    }

    @Test func commitFailureRestoresCommittedFiles() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let a = dir.file("a.go", "A\n")
        let c = dir.file("c.go", "C\n")
        setImmutable(c, true)                                   // rename(2) over it fails with EPERM
        defer { setImmutable(c, false) }
        do {
            _ = try RenameTransaction.apply([preview(a, "A2\n"), preview(c, "C2\n")])
            Issue.record("expected commitFailed")
        } catch let RenameError.commitFailed(u, _) {
            #expect(u == c)
        }
        #expect(readFile(a) == "A\n")                           // committed first, then restored
        #expect(readFile(c) == "C\n")
        #expect(listDir(dir.url) == ["a.go", "c.go"])
    }

    @Test func injectedCommitFailureRollsBack() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let a = dir.file("a.go", "A\n")
        let b = dir.file("b.go", "B\n")
        let z = dir.file("z.go", "Z\n")
        do {
            _ = try RenameTransaction.apply([preview(a, "A2\n"), preview(b, "B2\n"), preview(z, "Z2\n")],
                                            fileSystem: failingCommitFileSystem(on: "b.go"))
            Issue.record("expected commitFailed")
        } catch let RenameError.commitFailed(u, _) {
            #expect(u == b)
        }
        #expect(readFile(a) == "A\n")
        #expect(readFile(b) == "B\n")
        #expect(readFile(z) == "Z\n")
        #expect(listDir(dir.url) == ["a.go", "b.go", "z.go"])
    }

    @Test func missingFileFailsStaging() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let a = dir.file("a.go", "A\n")
        let missing = dir.url.appendingPathComponent("missing.go")
        #expect(throws: RenameError.self) {
            _ = try RenameTransaction.apply([preview(a, "A2\n"), preview(missing, "M\n")])
        }
        #expect(readFile(a) == "A\n")
        #expect(listDir(dir.url) == ["a.go"])
    }
}
