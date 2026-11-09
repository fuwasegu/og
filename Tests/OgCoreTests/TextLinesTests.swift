import Testing
@testable import OgCore

@Suite struct TextLinesTests {
    @Test func lspRoundTripWithMultiByte() {
        let lines = TextLines("package main\n// 日本語 😀\nfunc f() {}\n")
        #expect(lines.lineCount == 4)
        let p = LSPPosition(line: 1, character: 8)
        #expect(lines.position(forOffset: lines.offset(for: p)) == p)
    }

    @Test func lexerMarksDeclarationsAndStrings() {
        let src = "package main\n\nfunc (s *Server) Greet() string { return \"x\" }\n"
        let kinds = GoLexer.tokenize(src).map(\.kind)
        #expect(kinds.contains(.funcDecl))
        #expect(kinds.contains(.string))
        #expect(kinds.contains(.keyword))
    }
}
