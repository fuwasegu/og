import Testing
@testable import OgCore

@Suite struct ProjectScaffoldTests {
    @Test func suggestsModuleUnderHostFolder() {
        #expect(ProjectScaffold.suggestedModule(parentPath: "/Users/me/Repositories/github.com/me", name: "tool")
            == "github.com/me/tool")
        #expect(ProjectScaffold.suggestedModule(parentPath: "/Users/me/go/src/example.org/team/sub", name: "x")
            == "example.org/team/sub/x")
    }

    @Test func suggestsBareNameElsewhere() {
        #expect(ProjectScaffold.suggestedModule(parentPath: "/Users/me/work", name: "my tool") == "my-tool")
        // Dotted folders that are not hosts (versions, hidden folders, capitals) are ignored.
        #expect(ProjectScaffold.suggestedModule(parentPath: "/Users/me/v1.2/.config/My.App", name: "a") == "a")
    }

    @Test func packageNameFollowsGoConvention() {
        #expect(ProjectScaffold.packageName(forModule: "github.com/me/go-Utils") == "utils")
        #expect(ProjectScaffold.packageName(forModule: "example.org/yaml-go") == "yaml")
        #expect(ProjectScaffold.packageName(forModule: "example.org/foo.bar") == "foobar")
        #expect(ProjectScaffold.packageName(forModule: "example.org/2d") == "p2d")
    }

    @Test func validatesNamesAndModules() {
        #expect(ProjectScaffold.nameProblem("ok-name") == nil)
        #expect(ProjectScaffold.nameProblem("") != nil)
        #expect(ProjectScaffold.nameProblem(".hidden") != nil)
        #expect(ProjectScaffold.nameProblem("a/b") != nil)
        #expect(ProjectScaffold.moduleProblem("github.com/me/tool") == nil)
        #expect(ProjectScaffold.moduleProblem("my tool") != nil)
        #expect(ProjectScaffold.moduleProblem("a//b") != nil)
        #expect(ProjectScaffold.moduleProblem("a/../b") != nil)
    }

    @Test func appTemplateFiles() {
        let s = ProjectScaffold(name: "hello", module: "example.org/hello", template: .app, gitInit: true)
        let paths = s.files.map { $0.path }
        #expect(paths == ["main.go", ".gitignore"])
        let main = s.files.first { $0.path == "main.go" }?.content ?? ""
        #expect(main.hasPrefix("package main\n"))
        #expect(main.contains("\tfmt.Println(\"Hello, hello!\")"))
        let ignore = s.files.first { $0.path == ".gitignore" }?.content ?? ""
        #expect(ignore.contains("/hello\n"))
        #expect(s.primaryFile == "main.go")
    }

    @Test func libraryAndEmptyTemplates() {
        let lib = ProjectScaffold(name: "go-utils", module: "example.org/go-utils", template: .library, gitInit: false)
        #expect(lib.files.map { $0.path } == ["utils.go"])
        #expect(lib.files.first?.content.contains("package utils\n") == true)
        let empty = ProjectScaffold(name: "e", module: "e", template: .empty, gitInit: false)
        #expect(empty.files.isEmpty)
        #expect(empty.primaryFile == "go.mod")
    }
}
