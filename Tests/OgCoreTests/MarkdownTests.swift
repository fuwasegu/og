import Testing
@testable import OgCore

@Suite struct MarkdownTests {
    @Test func headingsAndParagraphs() {
        let b = Markdown.parse("# Title #\n\ntext *em* and **bold**\nnext\n\nSetext\n---\n")
        #expect(b.count == 3)
        #expect(b[0] == .heading(level: 1, text: [.text("Title")], line: 0))
        #expect(b[1] == .paragraph([.text("text "), .emphasis([.text("em")]), .text(" and "), .strong([.text("bold")]), .text(" next")], line: 2))
        #expect(b[2] == .heading(level: 2, text: [.text("Setext")], line: 5))
    }

    @Test func fencedCodeKeepsLanguageAndBody() {
        let b = Markdown.parse("```mermaid\nflowchart LR\n  A --> B\n```\n\n    indented\n")
        #expect(b == [
            .code(language: "mermaid", text: "flowchart LR\n  A --> B", line: 0),
            .code(language: "", text: "indented", line: 5),
        ])
    }

    @Test func unclosedFenceRunsToTheEnd() {
        #expect(Markdown.parse("```go\nfunc f() {}\n") == [.code(language: "go", text: "func f() {}\n", line: 0)])
    }

    @Test func listsWithTasksAndNesting() {
        let b = Markdown.parse("- [ ] todo\n- [x] done\n  more\n- item\n  1. one\n  2. two\n")
        guard case .list(let ordered, _, let items, _) = b.first else { Issue.record("not a list"); return }
        #expect(!ordered)
        let checks = items.map { $0.checked }
        #expect(checks == [false, true, nil])
        #expect(items[1].blocks == [.paragraph([.text("done more")], line: 1)])
        guard case .list(true, 1, let sub, _) = items[2].blocks.last else { Issue.record("no nested list"); return }
        #expect(sub.count == 2)
    }

    @Test func tableWithAlignmentAndEscapedPipe() {
        let b = Markdown.parse("| a | b |\n|:--|--:|\n| 1 | x \\| y |\n")
        #expect(b == [.table(header: [[.text("a")], [.text("b")]], alignments: [.left, .right],
                             rows: [[[.text("1")], [.text("x | y")]]], line: 0)])
    }

    @Test func quoteWithLazyContinuation() {
        #expect(Markdown.parse("> one\ntwo\n") == [.quote([.paragraph([.text("one two")], line: 0)], line: 0)])
    }

    @Test func inlineLinksCodeAndAutolinks() {
        let i = Markdown.parseInline("see [go](https://go.dev \"t\"), `a*b` and https://x.dev/p.")
        #expect(i == [.text("see "), .link(text: [.text("go")], url: "https://go.dev"), .text(", "), .code("a*b"),
                      .text(" and "), .link(text: [.text("https://x.dev/p")], url: "https://x.dev/p"), .text(".")])
    }

    @Test func snakeCaseIsNotEmphasis() {
        #expect(Markdown.parseInline("a snake_case_name here") == [.text("a snake_case_name here")])
    }

    @Test func strikeAndImage() {
        #expect(Markdown.parseInline("~~old~~ ![logo](img/a.png)") == [.strike([.text("old")]), .text(" "), .image(alt: "logo", url: "img/a.png")])
    }

    @Test func contentIgnoresSourceLines() {
        let a = Markdown.parse("para\n")[0]
        let b = Markdown.parse("\n\n\npara\n")[0]
        #expect(a != b)
        #expect(a.content == b.content)
    }
}
