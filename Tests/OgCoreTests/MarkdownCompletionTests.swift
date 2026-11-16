import Testing
@testable import OgCore

@Suite struct MarkdownCompletionTests {
    func ctx(_ s: String, explicit: Bool = false) -> MarkdownCompletionContext? { mdContext(s, explicit: explicit) }

    @Test func fenceLanguageNeedsATypedLetterUnlessExplicit() {
        #expect(ctx("text\n```g|") == .fenceLanguage(replace: nsRange(8, 1)))
        #expect(ctx("```|") == nil)
        #expect(ctx("```|", explicit: true) == .fenceLanguage(replace: nsRange(3, 0)))
        // A closing fence is not an info string.
        #expect(ctx("```go\nx\n```g|") == nil)
    }

    @Test func nothingInsideCode() {
        #expect(ctx("```go\n[a](|") == nil)
        #expect(ctx("`[a](|") == nil)
    }

    @Test func linkAndImagePaths() {
        #expect(ctx("see [a](docs/my%20fi|") == .path(directory: "docs/", image: false, replace: nsRange(13, 7)))
        #expect(ctx("![logo](|") == .path(directory: "", image: true, replace: nsRange(8, 0)))
        #expect(ctx("[a](https://ex|") == nil)
        #expect(ctx("[a](b.md) more|") == nil)
    }

    @Test func anchorsInThisAndOtherFiles() {
        #expect(ctx("[a](#ins|") == .anchor(file: "", replace: nsRange(5, 3)))
        #expect(ctx("[a](other.md#|") == .anchor(file: "other.md", replace: nsRange(13, 0)))
        let text = "# Getting Started\n## Install og!\n## Install og!\n[x](#"
        let items = MarkdownCompletions.items(for: .anchor(file: "", replace: nsRange(52, 0)), in: text, caret: 52)
        #expect(items.map(\.text) == ["getting-started", "install-og", "install-og-1"])
    }

    @Test func referenceLabels() {
        let text = "[a][|\n\n[Docs]: https://x\n[^1]: note\n[docs]: dup\n"
        #expect(ctx(text) == .reference(replace: nsRange(4, 0)))
        #expect(MarkdownCompletions.referenceLabels(in: text) == ["Docs"])
    }

    @Test func pathItemsSortDirectoriesFirstAndEncode() {
        let entries = [MarkdownPathEntry(name: "b c.png", isDirectory: false), MarkdownPathEntry(name: "img", isDirectory: true),
                       MarkdownPathEntry(name: "a.go", isDirectory: false)]
        let items = MarkdownCompletions.items(for: .path(directory: "", image: true, replace: nsRange(0, 0)), in: "", entries: entries, caret: 0)
            .sorted { $0.sortText < $1.sortText }
        #expect(items.map(\.text) == ["img/", "b%20c.png", "a.go"])
    }

    @Test func wordsOnlyWhenExplicit() {
        #expect(ctx("hello wor|") == nil)
        let c = ctx("compile complete com|", explicit: true)
        #expect(c == .word(replace: nsRange(17, 3)))
        let items = MarkdownCompletions.items(for: c ?? .word(replace: nsRange(0, 0)), in: "compile complete com", caret: 20)
        #expect(Set(items.map(\.text)) == ["compile", "complete"])
    }
}
