import Foundation

/// What a new project starts with.
public enum ProjectTemplate: String, CaseIterable, Sendable {
    /// `package main` with a hello-world `main.go`.
    case app
    /// A library package named after the module.
    case library
    /// `go.mod` only.
    case empty

    public var title: String {
        switch self {
        case .app: return "Command (package main)"
        case .library: return "Library package"
        case .empty: return "Empty (go.mod only)"
        }
    }
}

/// Creates a new Go module on disk: folder, `go.mod`, starter files, optional git repository.
/// Never writes into a folder that already has files in it (no silent data loss).
public struct ProjectScaffold: Sendable {
    public var name: String
    public var module: String
    public var template: ProjectTemplate
    public var gitInit: Bool

    public init(name: String, module: String, template: ProjectTemplate, gitInit: Bool) {
        self.name = name
        self.module = module
        self.template = template
        self.gitInit = gitInit
    }

    // MARK: - Naming

    /// Why `name` cannot be a project folder name, or nil when it can.
    public static func nameProblem(_ name: String) -> String? {
        if name.isEmpty { return "Enter a project name" }
        if name.hasPrefix(".") { return "The name cannot start with a dot" }
        if name.contains("/") || name.contains(":") { return "The name cannot contain / or :" }
        if name.trimmingCharacters(in: .whitespaces) != name { return "The name cannot start or end with a space" }
        return nil
    }

    /// Why `module` is not a valid module path, or nil when it is (the rules of `go mod init`, simplified).
    public static func moduleProblem(_ module: String) -> String? {
        if module.isEmpty { return "Enter a module path" }
        if module.hasPrefix("/") || module.hasSuffix("/") || module.contains("//") { return "The module path has an empty element" }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/")
        if let bad = module.first(where: { !allowed.contains($0) }) { return "The module path cannot contain \"\(bad)\"" }
        for element in module.split(separator: "/") {
            if element == "." || element == ".." || element.hasPrefix(".") || element.hasSuffix(".") {
                return "Module path elements cannot start or end with a dot"
            }
        }
        return nil
    }

    /// A module path for `name` under `parentPath`: `github.com/me/name` when the folder sits under a
    /// host-named folder (`~/src/github.com/me`), else just `name`.
    public static func suggestedModule(parentPath: String, name: String) -> String {
        let leaf = moduleElement(name)
        let parts = parentPath.split(separator: "/").map(String.init)
        // The last host-looking element: lowercase labels joined by dots, like github.com or example.org.
        guard let i = parts.lastIndex(where: isHostLike) else { return leaf }
        return (parts[i...] + [leaf]).joined(separator: "/")
    }

    private static func isHostLike(_ s: String) -> Bool {
        let labels = s.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let tld = labels.last, tld.count >= 2, tld.allSatisfy(\.isLetter) else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
        }
    }

    /// `name` as a module path element (spaces become dashes, other invalid characters dropped).
    static func moduleElement(_ name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let s = String(name.replacingOccurrences(of: " ", with: "-").filter { allowed.contains($0) })
        return s.isEmpty ? "app" : s
    }

    /// The package name Go convention gives a module: its last element, lowercased, without a
    /// `go-` prefix or `-go` suffix, letters and digits only (`github.com/me/go-Foo.bar` → `foobar`).
    public static func packageName(forModule module: String) -> String {
        var last = String(module.split(separator: "/").last ?? "").lowercased()
        if last.hasPrefix("go-") { last.removeFirst(3) }
        if last.hasSuffix("-go") { last.removeLast(3) }
        var pkg = last.filter { ($0.isLetter || $0.isNumber) && $0.isASCII }
        if let f = pkg.first, f.isNumber { pkg = "p" + pkg }
        return pkg.isEmpty ? "lib" : pkg
    }

    // MARK: - Content

    /// Starter files relative to the project folder (everything but `go.mod`).
    public var files: [(path: String, content: String)] {
        var out: [(String, String)] = []
        switch template {
        case .app:
            out.append(("main.go", """
            package main

            import "fmt"

            func main() {
            \tfmt.Println("Hello, \(name)!")
            }

            """))
        case .library:
            let pkg = Self.packageName(forModule: module)
            out.append(("\(pkg).go", """
            // Package \(pkg) …
            package \(pkg)

            """))
        case .empty:
            break
        }
        if gitInit {
            // The binary `go build` writes for a command, and macOS clutter.
            var ignore = ".DS_Store\n"
            if template == .app { ignore = "/\(Self.moduleElement(name))\n" + ignore }
            out.append((".gitignore", ignore))
        }
        return out
    }

    /// The file to show first after creating the project.
    public var primaryFile: String? { files.first { $0.path.hasSuffix(".go") }?.path ?? "go.mod" }

    // MARK: - Creating

    public struct Failure: Error, LocalizedError, Sendable {
        public var message: String
        public var errorDescription: String? { message }
    }

    /// Creates the project as `parent/name` and returns its folder. Runs `go mod init` (so `go.mod`
    /// names the installed toolchain) and `git init`; blocking, call off the main thread.
    public func create(in parent: URL) throws -> URL {
        if let p = Self.nameProblem(name) { throw Failure(message: p) }
        if let p = Self.moduleProblem(module) { throw Failure(message: p) }
        let fm = FileManager.default
        let dir = parent.appendingPathComponent(name, isDirectory: true).standardizedFileURL
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dir.path, isDirectory: &isDir) {
            guard isDir.boolValue else { throw Failure(message: "\(name) already exists and is a file") }
            let entries = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            guard entries.allSatisfy({ $0 == ".DS_Store" }) else { throw Failure(message: "\(dir.path) already exists and is not empty") }
        }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw Failure(message: "Could not create \(dir.path): \(error.localizedDescription)")
        }
        if let go = ToolLocator.shared.find("go") {
            let r = Self.run(go, ["mod", "init", module], in: dir)
            guard r.status == 0 else { throw Failure(message: "go mod init failed: \(r.output)") }
        } else {
            try write("module \(module)\n", to: dir.appendingPathComponent("go.mod"))
        }
        for f in files {
            try write(f.content, to: dir.appendingPathComponent(f.path))
        }
        if gitInit {
            guard let git = ToolLocator.shared.find("git") else { throw Failure(message: "git was not found; the project was created without a repository") }
            let r = Self.run(git, ["init", "--quiet"], in: dir)
            guard r.status == 0 else { throw Failure(message: "git init failed: \(r.output)") }
        }
        return dir
    }

    private func write(_ text: String, to url: URL) throws {
        do {
            try Data(text.utf8).write(to: url, options: .withoutOverwriting)
        } catch {
            throw Failure(message: "Could not write \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private static func run(_ tool: String, _ args: [String], in dir: URL) -> (status: Int32, output: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tool)
        proc.arguments = args
        proc.currentDirectoryURL = dir
        proc.environment = ToolLocator.shared.environment
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        proc.standardInput = FileHandle.nullDevice
        do { try proc.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (proc.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
