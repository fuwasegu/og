import Testing
@testable import OgCore

@Suite struct LineDiffTests {
    @Test func identicalTextHasNoChanges() {
        #expect(LineDiff.changes(old: "a\nb\nc\n", new: "a\nb\nc\n").isEmpty)
    }

    @Test func insertionIsAdded() {
        #expect(LineDiff.changes(old: "a\nb\nc\n", new: "a\nX\nb\nc\n") == [GitLineChange(startLine: 1, lineCount: 1, kind: .added)])
    }

    @Test func removalIsDeletedMarkerAtFollowingLine() {
        #expect(LineDiff.changes(old: "a\nb\nc\n", new: "a\nc\n") == [GitLineChange(startLine: 1, lineCount: 0, kind: .deleted)])
    }

    @Test func replacementIsModified() {
        #expect(LineDiff.changes(old: "a\nb\nc\n", new: "a\nB\nc\n") == [GitLineChange(startLine: 1, lineCount: 1, kind: .modified)])
        #expect(LineDiff.changes(old: "p\n\nf() {}\n", new: "p\n\nimport x\n\nf(x)\n") == [GitLineChange(startLine: 2, lineCount: 3, kind: .modified)])
    }

    @Test func newFileIsAllAdded() {
        #expect(LineDiff.changes(old: "", new: "x\ny\n") == [GitLineChange(startLine: 0, lineCount: 2, kind: .added)])
    }

    @Test func multipleHunks() {
        let c = LineDiff.changes(old: "1\n2\n3\n4\n5\n6\n7\n", new: "0\n1\n3\n4\nfive\n6\n7\n8\n")
        #expect(c == [
            GitLineChange(startLine: 0, lineCount: 1, kind: .added),
            GitLineChange(startLine: 2, lineCount: 0, kind: .deleted),
            GitLineChange(startLine: 4, lineCount: 1, kind: .modified),
            GitLineChange(startLine: 7, lineCount: 1, kind: .added),
        ])
    }

    @Test func crlfAndMultiByteLines() {
        #expect(LineDiff.changes(old: "a\r\nb\r\n", new: "a\nb\r\n") == [GitLineChange(startLine: 0, lineCount: 1, kind: .modified)])
        #expect(LineDiff.changes(old: "日本\n😀\n", new: "日本\n😀x\n") == [GitLineChange(startLine: 1, lineCount: 1, kind: .modified)])
    }

    @Test func hunksReconstructNewFromOld() {
        // Deterministic LCG fuzz: applying the hunks to `old` must yield `new`.
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ n: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(n))
        }
        for _ in 0..<300 {
            let a = (0..<next(30)).map { _ in next(5) }
            let b = (0..<next(30)).map { _ in next(5) }
            var out: [Int] = []
            var i = 0
            for h in LineDiff.hunks(old: a, new: b) {
                out += a[i..<h.oldStart]
                out += b[h.newStart..<(h.newStart + h.newCount)]
                i = h.oldStart + h.oldCount
            }
            out += a[i...]
            #expect(out == b)
        }
    }

    @Test func largeRewriteFallsBackToOneHunk() {
        let a = (0..<5000).map { "a\($0)" }
        let b = (0..<5000).map { "b\($0)" }
        #expect(LineDiff.hunks(old: a, new: b) == [LineDiff.Hunk(oldStart: 0, oldCount: 5000, newStart: 0, newCount: 5000)])
    }
}

@Suite struct GitStatusParserTests {
    static let raw = [
        "# branch.oid abc", "# branch.head main",
        "1 .M N... 100644 100644 100644 h h svc/a.go",
        "2 R. N... 100644 100644 100644 h h R100 svc/new name.go", "svc/old.go",
        "? svc/u.txt", "? other/x",
        "u UU N... 1 1 1 1 h h h svc/c.go",
        "1 A. N... 0 1 1 0 h svc/added.go",
        "1 D. N... 1 0 0 h 0 svc/d.go",
        "",
    ].joined(separator: "\u{0}")

    @Test func parsesStatesRelativeToProjectRoot() {
        let s = GitStatusParser.parse(Self.raw, prefix: "svc/")
        #expect(s.branch == "main")
        #expect(s.status.files == [
            "a.go": .modified, "new name.go": .renamed, "u.txt": .untracked,
            "c.go": .conflicted, "added.go": .added, "d.go": .deleted,
        ])
        #expect(s.entries["new name.go"]?.origin == "old.go")
    }

    @Test func repositoryRootPrefixKeepsAllPaths() {
        let s = GitStatusParser.parse(Self.raw, prefix: "")
        #expect(s.status.files["other/x"] == .untracked)
        #expect(s.status.files["svc/a.go"] == .modified)
    }

    @Test func renameOriginOutsideProjectIsRelative() {
        let raw = "2 R. N... 100644 100644 100644 h h R100 svc/x.go\u{0}lib/x.go\u{0}"
        #expect(GitStatusParser.parse(raw, prefix: "svc/").entries["x.go"]?.origin == "../lib/x.go")
    }

    @Test func detachedHead() {
        let s = GitStatusParser.parse("# branch.oid 1234567890\u{0}# branch.head (detached)\u{0}", prefix: "")
        #expect(s.branch == "HEAD detached at 1234567")
    }
}
