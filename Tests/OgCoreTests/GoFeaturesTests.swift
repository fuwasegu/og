import Testing
@testable import OgCore

private let fn = "package main\n\nfunc load(p string) (*Config, int, error) {\n\t"

@Suite struct GoPostfixTests {
    @Test func templatesListed() {
        for t in ["err", "nn", "nil", "not", "if", "var", "for", "forr", "range", "return", "print", "len", "par", "go", "defer", "switch"] {
            #expect(GoPostfix.templates.contains(t))
        }
    }

    @Test func errReturnsZeroValues() {
        #expect(expandPostfix(fn + "err.err|") == fn + "if err != nil {\n\t\treturn nil, 0, err‸\n\t}")
    }

    @Test func errOnCallUsesInitStatement() {
        #expect(expandPostfix(fn + "os.Remove(p).err|") == fn + "if err := os.Remove(p); err != nil {\n\t\treturn nil, 0, err‸\n\t}")
    }

    @Test func errInTestUsesFatal() {
        let src = "package p\n\nimport \"testing\"\n\nfunc TestX(t *testing.T) {\n\t"
        #expect(expandPostfix(src + "err.err|") == src + "if err != nil {\n\t\tt.Fatal(err)‸\n\t}")
    }

    @Test func errWithoutResults() {
        let src = "package main\n\nfunc main() {\n\t"
        #expect(expandPostfix(src + "err.err|") == src + "if err != nil {\n\t\treturn‸\n\t}")
    }

    @Test func errUnknownContext() {
        #expect(expandPostfix("err.err|") == "if err != nil {\n\treturn err‸\n}")
    }

    @Test func errZeroValuesForStructsAndTypeParams() {
        let src = "package main\n\ntype S struct{}\n\nfunc f[T any]() (S, T, []int, bool, string, error) {\n\t"
        #expect(expandPostfix(src + "err.err|") == src + "if err != nil {\n\t\treturn S{}, *new(T), nil, false, \"\", err‸\n\t}")
    }

    @Test func errInsideFuncLiteral() {
        let src = "package main\n\nfunc f() (string, error) {\n\tgo func() {\n\t\t"
        #expect(expandPostfix(src + "err.err|") == src + "if err != nil {\n\t\t\treturn‸\n\t\t}")
    }

    @Test func nilChecks() {
        #expect(expandPostfix(fn + "x.nn|") == fn + "if x != nil {\n\t\t‸\n\t}")
        #expect(expandPostfix(fn + "x.nil|") == fn + "if x == nil {\n\t\t‸\n\t}")
    }

    @Test func expressionTemplates() {
        #expect(expandPostfix(fn + "ok.not|") == fn + "!ok‸")
        #expect(expandPostfix(fn + "a := b.not|") == fn + "a := !b‸")
        #expect(expandPostfix(fn + "foo(a, s.items.len|") == fn + "foo(a, len(s.items)‸")
        #expect(expandPostfix(fn + "a + b.par|") == fn + "a + (b)‸")
        #expect(expandPostfix(fn + "[]byte(s).len|") == fn + "len([]byte(s))‸")
    }

    @Test func ifWithUnary() {
        #expect(expandPostfix(fn + "!ok.if|") == fn + "if !ok {\n\t\t‸\n\t}")
    }

    @Test(arguments: [
        ("NewServer().var|", "server := NewServer()‸"),
        ("pkg.GetUser(id).var|", "user := pkg.GetUser(id)‸"),
        ("s.items.var|", "items := s.items‸"),
        ("s.items[i].var|", "item := s.items[i]‸"),
        ("HTTPClient.var|", "httpClient := HTTPClient‸"),
        ("v.(*Server).var|", "server := v.(*Server)‸"),
        ("42.var|", "v := 42‸"),
        ("x.var|", "v := x‸"),
        ("len(xs).var|", "n := len(xs)‸"),
    ])
    func varNames(_ input: String, _ expected: String) {
        #expect(expandPostfix(fn + input) == fn + expected)
    }

    @Test func loops() {
        #expect(expandPostfix(fn + "users.for|") == fn + "for _, v := range users {\n\t\t‸\n\t}")
        #expect(expandPostfix(fn + "10.for|") == fn + "for i := range 10 {\n\t\t‸\n\t}")
        #expect(expandPostfix(fn + "n.forr|") == fn + "for i := range n {\n\t\t‸\n\t}")
        #expect(expandPostfix(fn + "m.range|") == fn + "for k, v := range m {\n\t\t‸\n\t}")
        #expect(expandPostfix(fn + "[]int{1, 2}.for|") == fn + "for _, v := range []int{1, 2} {\n\t\t‸\n\t}")
    }

    @Test func compositeLiteralInHeaderIsParenthesized() {
        #expect(expandPostfix(fn + "Config{Name: \"a\"}.Valid().if|") == fn + "if (Config{Name: \"a\"}.Valid()) {\n\t\t‸\n\t}")
    }

    @Test func statements() {
        #expect(expandPostfix(fn + "x.return|") == fn + "return x‸")
        #expect(expandPostfix(fn + "x.print|") == fn + "fmt.Println(x)‸")
        #expect(expandPostfix(fn + "worker.go|") == fn + "go worker(‸)")
        #expect(expandPostfix(fn + "f.Close().defer|") == fn + "defer f.Close()‸")
        #expect(expandPostfix(fn + "x.switch|") == fn + "switch x {\n\tcase ‸:\n\t}")
    }

    @Test func expressionShapes() {
        #expect(expandPostfix(fn + "m[\"k\"].nn|") == fn + "if m[\"k\"] != nil {\n\t\t‸\n\t}")
        #expect(expandPostfix(fn + "a.b(c[1], d).e.nn|") == fn + "if a.b(c[1], d).e != nil {\n\t\t‸\n\t}")
        #expect(expandPostfix(fn + "Map[int, string](xs).return|") == fn + "return Map[int, string](xs)‸")
    }

    @Test func multiByteBeforeCaret() {
        let src = "package main\n\n// 日本語 😀\nfunc f() {\n\t"
        #expect(expandPostfix(src + "名前.nn|") == src + "if 名前 != nil {\n\t\t‸\n\t}")
    }

    @Test(arguments: [
        "\"abc.err|", "// x.err|", "/* x.err|", "`raw x.err|", "a := x.err|", "x.unknown|", "x .err|", ".err|",
        "a + .err|", "return.err|",
    ])
    func rejected(_ input: String) {
        #expect(expandPostfix(fn + input) == nil)
    }

    @Test func rejectsPackageSelector() {
        #expect(expandPostfix("package main\n\nimport \"fmt\"\n\nfunc f() {\n\tfmt.err|") == nil)
    }

    @Test func statementNeedsEndOfLine() {
        #expect(expandPostfix(fn + "x.nn|)") == nil)
        #expect(postfixTemplateName(fn + "x.nn| // note") == "nn")
    }
}

@Suite struct GoStructTagsTests {
    @Test func tagsAndAlignment() throws {
        let src = """
        package p

        type User struct {
        \tID int
        \tUserID, HTTPServer string
        \tname string
        \tCreatedAt time.Time `db:"created_at"` // created
        \tSkip string `json:"-"`
        \tBase
        }
        """
        let out = try #require(GoStructTags.apply(to: src, line: lineIndex(of: "UserID", in: src)))
        let expected = """
        package p

        type User struct {
        \tID         int    `json:"id"`
        \tUserID     string `json:"user_id"`
        \tHTTPServer string `json:"http_server"`
        \tname       string
        \tCreatedAt  time.Time `db:"created_at" json:"created_at"` // created
        \tSkip       string    `json:"-"`
        \tBase
        }
        """
        #expect(out == expected)
        // Idempotent.
        #expect(GoStructTags.apply(to: out, line: 3) == out)
    }

    @Test func camelAndMultipleKeys() throws {
        let src = "package p\n\ntype T struct {\n\tUserID int\n\tURLs []string\n}\n"
        let out = try #require(GoStructTags.apply(to: src, line: 3, keys: ["json", "yaml"], style: .camel))
        #expect(out == "package p\n\ntype T struct {\n\tUserID int      `json:\"userId\" yaml:\"userId\"`\n\tURLs   []string `json:\"urls\" yaml:\"urls\"`\n}\n")
    }

    @Test func nestedStructAndBraceTypes() throws {
        let src = """
        type T struct {
        \tTags map[string]struct{}
        \tAddress struct {
        \t\tStreet string
        \t\tZIPCode string `xml:"zip"`
        \t}
        \tLast int
        }
        """
        let out = try #require(GoStructTags.apply(to: src, line: 0))
        let expected = """
        type T struct {
        \tTags    map[string]struct{} `json:"tags"`
        \tAddress struct {
        \t\tStreet  string `json:"street"`
        \t\tZIPCode string `xml:"zip" json:"zip_code"`
        \t} `json:"address"`
        \tLast int `json:"last"`
        }
        """
        #expect(out == expected)
    }

    @Test func commentsAndBlankLinesBreakAlignment() throws {
        let src = "type T struct { // head\n\tA int\n\t// doc for B\n\tLongName int\n\n\tC int\n}\n"
        let out = try #require(GoStructTags.apply(to: src, line: 2))
        #expect(out == "type T struct { // head\n\tA int `json:\"a\"`\n\t// doc for B\n\tLongName int `json:\"long_name\"`\n\n\tC int `json:\"c\"`\n}\n")
    }

    @Test func oneLineStructIsExpanded() throws {
        let src = "type Small struct{ A int; BB string }\n"
        let out = try #require(GoStructTags.apply(to: src, line: 0))
        #expect(out == "type Small struct {\n\tA  int    `json:\"a\"`\n\tBB string `json:\"bb\"`\n}\n")
    }

    @Test func ignoresStructLiteralsInStrings() throws {
        let src = "var s = \"struct { X int }\"\n\ntype T struct {\n\tX int\n}\n"
        let out = try #require(GoStructTags.apply(to: src, line: 3))
        #expect(textContains(out, "X int `json:\"x\"`"))
        #expect(textContains(out, "\"struct { X int }\""))
    }

    @Test func noStruct() {
        #expect(GoStructTags.apply(to: "package p\n\nfunc f() {}\n", line: 2) == nil)
        #expect(GoStructTags.apply(to: "package p\n\ntype T struct {\n\tA int\n}\n", line: 0) == nil)
    }

    @Test func snakeNames() {
        #expect(GoStructTagsEngine.tagName("HTTPServer", style: .snake) == "http_server")
        #expect(GoStructTagsEngine.tagName("UserIDs", style: .snake) == "user_ids")
        #expect(GoStructTagsEngine.tagName("Base64Encoded", style: .snake) == "base64_encoded")
        #expect(GoStructTagsEngine.tagName("ID", style: .snake) == "id")
        #expect(GoStructTagsEngine.tagName("HTTPServer", style: .camel) == "httpServer")
    }
}

@Suite struct GoTableTestTests {
    static let source = """
    package lib

    import (
    \t"context"
    \tyaml "gopkg.in/yaml.v3"
    )

    type Server struct{ addr string }
    type Celsius float64
    type List[T any] struct{ items []T }

    func Add(a, b int) int { return a + b }

    func (s *Server) Handle(ctx context.Context,
    \tname string,
    ) (code int, body []byte, err error) {
    \treturn 0, nil, nil
    }

    func (c Celsius) String() string { return "" }

    func (l *List[T]) Push(v T, more ...T) { l.items = append(l.items, v) }

    func Map[T, U any](xs []T, f func(T) U) []U { return nil }

    func parse(_ string) error { return nil }

    func node(n *yaml.Node) {}
    """

    func gen(_ needle: String) throws -> GeneratedTest {
        try #require(GoTableTest.generate(source: Self.source, fileName: "lib.go", line: lineIndex(of: needle, in: Self.source)))
    }

    @Test func simpleFunction() throws {
        let g = try gen("func Add")
        #expect(g.testFileName == "lib_test.go")
        #expect(g.functionName == "TestAdd")
        let expected = """
        package lib

        import "testing"

        func TestAdd(t *testing.T) {
        \ttype args struct {
        \t\ta int
        \t\tb int
        \t}
        \ttests := []struct {
        \t\tname string
        \t\targs args
        \t\twant int
        \t}{
        \t\t// TODO: Add test cases.
        \t}
        \tfor _, tt := range tests {
        \t\tt.Run(tt.name, func(t *testing.T) {
        \t\t\tgot := Add(tt.args.a, tt.args.b)
        \t\t\tif got != tt.want {
        \t\t\t\tt.Errorf("Add() = %v, want %v", got, tt.want)
        \t\t\t}
        \t\t})
        \t}
        }

        """
        #expect(g.newFileContent == expected)
        #expect(g.appendContent.hasPrefix("\nfunc TestAdd(t *testing.T) {"))
        #expect(!g.appendContent.contains("package"))
    }

    @Test func methodWithMultiLineParamsAndError() throws {
        let g = try gen("ctx context.Context")   // caret on a continuation line of the signature
        #expect(g.functionName == "TestServer_Handle")
        let c = g.newFileContent
        #expect(textContains(c, "import (\n\t\"context\"\n\t\"reflect\"\n\t\"testing\"\n)"))
        #expect(textContains(c, "\t\tctx  context.Context\n\t\tname string\n"))
        #expect(textContains(c, "\t\twant    int\n\t\twant1   []byte\n\t\twantErr bool\n"))
        #expect(textContains(c, "got, got1, err := (&Server{}).Handle(tt.args.ctx, tt.args.name)"))
        #expect(textContains(c, "if (err != nil) != tt.wantErr {"))
        #expect(textContains(c, "if got != tt.want {"))
        #expect(textContains(c, "if !reflect.DeepEqual(got1, tt.want1) {"))
    }

    @Test func valueReceiverOfBasicType() throws {
        let g = try gen("func (c Celsius)")
        #expect(g.functionName == "TestCelsius_String")
        #expect(textContains(g.newFileContent, "var recv Celsius\n\t\t\tgot := recv.String()"))
    }

    @Test func genericReceiverAndVariadic() throws {
        let g = try gen("Push(")
        #expect(g.functionName == "TestList_Push")
        #expect(textContains(g.newFileContent, "\t\tv    int\n\t\tmore []int\n"))
        #expect(textContains(g.newFileContent, "(&List[int]{}).Push(tt.args.v, tt.args.more...)"))
    }

    @Test func genericFunction() throws {
        let g = try gen("func Map")
        #expect(textContains(g.newFileContent, "got := Map[int, int](tt.args.xs, tt.args.f)"))
        #expect(textContains(g.newFileContent, "\t\tf  func(int) int\n"))
    }

    @Test func unexportedErrorOnly() throws {
        let g = try gen("func parse")
        #expect(g.functionName == "Test_parse")
        #expect(textContains(g.newFileContent, "if err := parse(tt.args.arg0); (err != nil) != tt.wantErr {"))
        #expect(!textContains(g.newFileContent, "reflect"))
    }

    @Test func importsAliasedPackages() throws {
        let g = try gen("func node")
        #expect(textContains(g.newFileContent, "import (\n\t\"testing\"\n\n\tyaml \"gopkg.in/yaml.v3\"\n)"))
        #expect(textContains(g.newFileContent, "\t\t\tnode(tt.args.n)\n"))
    }

    @Test func notOnAFunction() {
        #expect(GoTableTest.generate(source: Self.source, fileName: "lib.go", line: lineIndex(of: "type Server", in: Self.source)) == nil)
        #expect(GoTableTest.generate(source: "func f() {}", fileName: "x.go", line: 0) == nil)   // no package clause
    }
}
