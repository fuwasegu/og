import Testing
@testable import OgCore

@Suite struct GoErrCheckTests {
    private func suggest(_ src: String) -> GoErrCheckSuggestion? { errCheckAtEnd(src) }

    @Test func afterErrorAssignment() {
        let s = suggest("package p\n\nfunc f() (int, error) {\n\tv, err := g()\n\tif")
        #expect(s?.text == "if err != nil {\n\t\treturn 0, err\n\t}")
        #expect(s?.variable == "err")
    }

    @Test func prefixAndMultilineCall() {
        let s = suggest("func f() error {\n\terr := do(\n\t\tx,\n\t)\n\ti")
        #expect(s?.text == "if err != nil {\n\t\treturn err\n\t}")
    }

    @Test func namedErrorVariable() {
        #expect(suggest("func f() {\n\tres, readErr := r()\n\tif")?.variable == "readErr")
    }

    @Test func noSuggestionWithoutError() {
        #expect(suggest("func f() {\n\tv := 1\n\tif") == nil)
        #expect(suggest("func f() {\n\tif err == nil {\n\t}\n\tif") == nil)
        #expect(suggest("func f() {\n\tv, err := g()\n\tfor") == nil)
    }
}
