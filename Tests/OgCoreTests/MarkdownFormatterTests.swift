import Testing
@testable import OgCore

@Suite struct MarkdownFormatterTests {
    func fmt(_ s: String) -> String { MarkdownFormatter.format(s) }

    @Test func tablesLineUp() {
        let src = "|a|bb|c|\n|:-|:-:|-:|\n|xxxx|y|z|\n|日本|x|\n"
        #expect(fmt(src) == """
        | a    | bb  |   c |
        | :--- | :-: | --: |
        | xxxx |  y  |   z |
        | 日本 |  x  |     |

        """)
    }

    @Test func pipesInCodeAndEscapesDoNotSplit() {
        let src = "| a | b |\n|---|---|\n| `x|y` | \\| |\n"
        #expect(fmt(src) == "| a     | b   |\n| ----- | --- |\n| `x|y` | \\|  |\n")
    }

    @Test func headingsGetSpacingAndBlankLines() {
        #expect(fmt("##   Title  \ntext\n#tag\n") == "## Title\n\ntext\n#tag\n")
        #expect(fmt("a\n# H\nb") == "a\n\n# H\n\nb\n")
    }

    @Test func whitespaceAndBlankRuns() {
        #expect(fmt("\n\na  \nb \n\n\n\nc\t\n\n\n") == "a  \nb\n\nc\n")
    }

    @Test func codeAndFrontMatterAreVerbatim() {
        let src = "---\ntitle:  x  \n---\n```go\n# not heading  \n\n\n|a|b|\n|-|-|\n```\n"
        #expect(fmt(src) == "---\ntitle:  x  \n---\n```go\n# not heading  \n\n\n|a|b|\n|-|-|\n```\n")
    }

    @Test func indentedCodeKeepsItsBlankLines() {
        #expect(fmt("text\n\n    a  \n\n\n    b\n\n\n\nend\n") == "text\n\n    a\n\n\n    b\n\nend\n")
    }

    @Test func formattedTextIsStable() {
        let once = fmt("# A\n|a|b|\n|-|-|\n|1|2|\ntext  \nmore\n")
        #expect(fmt(once) == once)
    }

    @Test func caretStaysOnItsLine() {
        let old = "##  Title\ntext   \n\n\n\nmore\n"
        let new = fmt(old)
        // "te|xt" -> still after "te"; "mo|re" moves up with the removed blank lines.
        #expect(MarkdownFormatter.mapCaret(12, from: old, to: new) == 12)
        #expect(MarkdownFormatter.mapCaret(23, from: old, to: new) == 18)
    }

    @Test func editsRebuildTheFormattedText() {
        let old = "# A\ntext \n\n\n|a|b|\n|-|-|\nend"
        let new = fmt(old)
        #expect(applyEdits(old, MarkdownFormatter.edits(from: old, to: new)) == new)
    }
}
