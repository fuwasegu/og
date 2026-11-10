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

    @Test func zeroValueFromHover() {
        #expect(GoErrCheck.zeroValue(fromHover: "```go\ntype Tool interface { Name() string }\n```", type: "tool.Tool") == "nil")
        #expect(GoErrCheck.zeroValue(fromHover: "```go\ntype Buffer struct {\n```", type: "bytes.Buffer") == "bytes.Buffer{}")
        #expect(GoErrCheck.zeroValue(fromHover: "```go\ntype Duration int64 // size=8\n```", type: "time.Duration") == "0")
        #expect(GoErrCheck.zeroValue(fromHover: "```go\ntype Kind string\n```", type: "x.Kind") == "\"\"")
    }

    @Test func externalZerosReplaceNew() {
        let src = "func f() (tool.Tool, error) {\n\tv, err := g()\n\tif"
        #expect(errCheckAtEnd(src)?.text.contains("*new(tool.Tool)") == true)
        #expect(errCheckAtEnd(src, zeros: ["tool.Tool": "nil"])?.text == "if err != nil {\n\t\treturn nil, err\n\t}")
    }

    @Test func wrapMessageFromCallee() {
        #expect(GoStyleCompletions.calleePhrase("schema, err := jsonschema.For[getNowInput](nil)") == "jsonschema for")
        #expect(GoStyleCompletions.calleePhrase("x, err := parse[int](s)") == "parse")
        #expect(GoStyleCompletions.calleePhrase("resp, err := http.Get(u)") == "http get")
        #expect(GoStyleCompletions.calleePhrase("v, err := strconv.Atoi(s)") == "atoi")
    }
}
