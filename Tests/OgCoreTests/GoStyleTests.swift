import Testing
@testable import OgCore

@Suite struct GoStyleCheckTests {
    @Test func getterWithoutGet() {
        let src = "package p\n\ntype T struct{ name string }\n\nfunc (t *T) GetName() string { return t.name }\n"
        #expect(styleFindings(src).contains("og/getter@5"))
        #expect(styleRename(src, rule: "og/getter") == "Name")
        // Params, no result, or a conflicting exported field: no rename.
        #expect(!styleFindings("package p\n\nfunc (t *T) GetName(id int) string { return \"\" }\n").contains("og/getter@3"))
        #expect(!styleFindings("package p\n\nfunc (t *T) Getaway() int { return 0 }\n").contains("og/getter@3"))
        let clash = "package p\n\ntype T struct{ Name string }\n\nfunc (t *T) GetName() string { return t.Name }\n"
        #expect(styleFindings(clash).contains("og/getter@5"))
        #expect(styleRename(clash, rule: "og/getter") == nil)
    }

    @Test func packageStutter() {
        let src = "package http\n\n// HTTPServer x.\ntype HTTPServer struct{}\n\n// HTTPGet x.\nfunc HTTPGet() {}\n"
        #expect(styleFindings(src) == ["og/stutter@4", "og/stutter@7"])
        #expect(styleRename(src, rule: "og/stutter") == "Server")
        #expect(styleFindings("package http\n\n// Httpd x.\ntype Httpd struct{}\n").isEmpty)
        #expect(styleFindings("package main\n\ntype MainThing struct{}\n").isEmpty)
    }

    @Test func errorNaming() {
        let src = "package p\n\nimport \"errors\"\n\nvar notFound = errors.New(\"not found\")\n\n// ErrGone is gone.\nvar ErrGone = errors.New(\"gone\")\n"
        #expect(styleFindings(src) == ["og/error-var-name@5"])
        #expect(styleRename(src, rule: "og/error-var-name") == "errNotFound")
        #expect(GoStyle.errorVariableName(for: "TimeoutError") == "ErrTimeout")
        let typ = "package p\n\ntype notFound struct{}\n\nfunc (notFound) Error() string { return \"\" }\n"
        #expect(styleFindings(typ) == ["og/error-type-name@3"])
        #expect(styleRename(typ, rule: "og/error-type-name") == "notFoundError")
    }

    @Test func oneMethodInterface() {
        let src = "package p\n\ntype store interface {\n\tLoad(key string) ([]byte, error)\n}\n"
        #expect(styleFindings(src) == ["og/interface-name@3"])
        #expect(styleRename(src, rule: "og/interface-name") == "loader")
        #expect(styleFindings("package p\n\ntype loader interface {\n\tLoad() error\n}\n").isEmpty)
        #expect(styleFindings("package p\n\ntype two interface {\n\tA()\n\tB()\n}\n").isEmpty)
        #expect(styleFindings("package p\n\ntype number interface {\n\t~int | ~float64\n}\n").isEmpty)
    }

    @Test func contextFirst() {
        let src = "package p\n\nimport \"context\"\n\nfunc run(name string, ctx context.Context) {}\n"
        #expect(styleFindings(src) == ["og/context-first@5"])
        #expect(styleFindings("package p\n\nfunc run(ctx context.Context, name string) {}\n").isEmpty)
        #expect(styleFindings("package p\n\nfunc helper(t *testing.T, ctx context.Context) {}\n", file: "x_test.go").isEmpty)
    }

    @Test func elseAfterReturn() {
        let src = "package p\n\nfunc f(x int) int {\n\tif x > 0 {\n\t\treturn 1\n\t} else {\n\t\ty := 2\n\t\treturn y\n\t}\n}\n"
        #expect(styleFindings(src) == ["og/else-after-return@6"])
        #expect(styleApplyFix(src, rule: "og/else-after-return") ==
                "package p\n\nfunc f(x int) int {\n\tif x > 0 {\n\t\treturn 1\n\t}\n\ty := 2\n\treturn y\n}\n")
        // No return at the end, an else-if chain, or an init statement that declares: no finding.
        #expect(styleFindings("package p\n\nfunc f(x int) {\n\tif x > 0 {\n\t\tg()\n\t} else {\n\t\th()\n\t}\n}\n").isEmpty)
        #expect(styleFindings("package p\n\nfunc f(x int) int {\n\tif x > 0 {\n\t\treturn 1\n\t} else if x < 0 {\n\t\treturn 2\n\t} else {\n\t\treturn 3\n\t}\n}\n") == [])
        #expect(styleFindings("package p\n\nfunc f() int {\n\tif v, ok := m[k]; ok {\n\t\treturn v\n\t} else {\n\t\treturn 0\n\t}\n}\n").isEmpty)
    }

    @Test func docComments() {
        let src = "package p\n\nfunc Run() {}\n\n// Stop stops.\nfunc Stop() {}\n\nconst (\n\tA = 1\n\tB = 2\n)\n"
        #expect(styleFindings(src) == ["og/doc-comment@3", "og/doc-comment@9"])
        #expect(styleApplyFix(src, rule: "og/doc-comment")?.hasPrefix("package p\n\n// Run \nfunc Run() {}") == true)
        #expect(styleFindings("package p\n\nfunc run() {}\n").isEmpty)
        #expect(styleFindings("package p\n\nfunc Run() {}\n", file: "x_test.go").isEmpty)
        #expect(styleFindings("package main\n\nfunc Run() {}\n").isEmpty)
    }

    @Test func receiverNames() {
        let src = "package p\n\n// T x.\ntype T struct{}\n\n// A x.\nfunc (this *T) A() {}\n"
        #expect(styleFindings(src) == ["og/receiver-name@7"])
        #expect(styleRename(src, rule: "og/receiver-name") == "t")
        let consistent = src + "\n// B x.\nfunc (tt *T) B() {}\n"
        #expect(styleRename(consistent, rule: "og/receiver-name") == "tt")
    }

    @Test func generatedFilesAreSkipped() {
        #expect(styleFindings("// Code generated by protoc-gen-go. DO NOT EDIT.\n\npackage p\n\nfunc (this *T) GetName() string { return \"\" }\n").isEmpty)
    }
}

@Suite struct GoStyleCompletionTests {
    @Test func errorWrap() {
        let src = "package p\n\nfunc load(p string) ([]byte, error) {\n\tdata, err := os.ReadFile(p)\n\ti|\n}\n"
        #expect(styleComplete(src, label: "fmt.Errorf", file: "x.go") ==
                "package p\n\nfunc load(p string) ([]byte, error) {\n\tdata, err := os.ReadFile(p)\n\tif err != nil {\n\t\treturn nil, fmt.Errorf(\"read file‸: %w\", err)\n\t}\n}\n")
        #expect(GoStyleCompletions.words("ParseURL") == "parse URL")
        // No error result: no wrap item.
        #expect(styleLabels("package p\n\nfunc f() {\n\terr := g()\n\tif|\n}\n", file: "x.go").isEmpty)
    }

    @Test func errorsIs() {
        let src = "package p\n\nfunc f() {\n\tif err == Er|\n}\n"
        #expect(styleComplete(src, candidates: [("ErrNotFound", "error"), ("Errorf", "func")]) ==
                "package p\n\nfunc f() {\n\tif errors.Is(err, ErrNotFound)‸\n}\n")
        #expect(styleLabels("package p\n\nfunc f() {\n\tif err != io.E|\n}\n", candidates: [("EOF", "error")]) == ["!errors.Is(err, io.EOF)"])
        #expect(styleLabels("package p\n\nfunc f() {\n\tif x == Er|\n}\n", candidates: [("ErrNotFound", "error")]).isEmpty)
    }

    @Test func docComment() {
        let src = "package p\n\n//|\nfunc (s *Server) Start() {}\n"
        #expect(styleComplete(src) == "package p\n\n// Start ‸\nfunc (s *Server) Start() {}\n")
        #expect(styleComplete("//|\npackage store\n") == "// Package store ‸\npackage store\n")
        #expect(styleComplete("package p\n\nconst (\n\t// |\n\tMaxSize = 10\n)\n") == "package p\n\nconst (\n\t// MaxSize ‸\n\tMaxSize = 10\n)\n")
        #expect(styleLabels("package p\n\n//|\nfunc start() {}\n").isEmpty)
        #expect(styleTriggers("package p\n\n//|\n"))
        #expect(styleTriggers("func (|)\n"))
    }

    @Test func receiver() {
        let pkg = "package p\n\ntype Server struct{}\n\nfunc (srv *Server) Stop() {}\n"
        let src = "package p\n\ntype Config struct{}\n\nfunc (|)\n"
        #expect(styleLabels(src, file: "x.go", package: [pkg]) == ["c *Config", "srv *Server"])
        #expect(styleComplete("package p\n\ntype Celsius float64\n\nfunc (|\n", file: "x.go") ==
                "package p\n\ntype Celsius float64\n\nfunc (c Celsius) ‸\n")
        #expect(styleLabels("package p\n\ntype Set[T comparable] struct{}\n\nfunc (|)\n", file: "x.go") == ["s *Set[T]"])
    }

    @Test func constructor() {
        let src = "package p\n\ntype Server struct{}\n\nfunc New|\n"
        #expect(styleComplete(src, file: "x.go") ==
                "package p\n\ntype Server struct{}\n\nfunc NewServer(‸) *Server {\n\treturn &Server{}\n}\n")
        #expect(styleLabels("package p\n\ntype Server struct{}\n\nfunc NewServer() *Server { return nil }\n\nfunc New|\n", file: "x.go").isEmpty)
    }

    @Test func testTemplates() {
        let src = "package p\n\nfunc TestParseURL(t *testing.T) {\n\tt.Err|\n}\n"
        #expect(styleComplete(src, label: "Errorf") ==
                "package p\n\nfunc TestParseURL(t *testing.T) {\n\tt.Errorf(\"ParseURL(%v) = %v, want %v\", in, got, want)‸\n}\n")
        let diff = "package p\n\nfunc TestServer_Start(t *testing.T) {\n\tcmp|\n}\n"
        #expect(styleComplete(diff, label: "cmp.Diff") ==
                "package p\n\nfunc TestServer_Start(t *testing.T) {\n\tif diff := cmp.Diff(want, got); diff != \"\" {\n\t\tt.Errorf(\"Server.Start() mismatch (-want +got):\\n%s\", diff)‸\n\t}\n}\n")
        #expect(styleLabels("package p\n\nfunc helper() {\n\tt.Err|\n}\n").isEmpty)
    }
}
