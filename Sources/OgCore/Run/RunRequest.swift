import Foundation

/// What to run. Shared by the editor gutter, the Run panel, and the debugger.
public enum RunRequest: Sendable, Hashable {
    /// `go run .` in a package directory.
    case runMain(packageDir: URL)
    /// `go test` in a package directory, optionally a single test (`-run ^Name$`).
    case test(packageDir: URL, name: String?)
    /// `go test -bench ^Name$ -run ^$`.
    case bench(packageDir: URL, name: String)

    public var packageDir: URL {
        switch self {
        case .runMain(let d), .test(let d, _), .bench(let d, _): return d
        }
    }

    public var title: String {
        switch self {
        case .runMain(let d): return "go run \(d.lastPathComponent)"
        case .test(let d, let n): return n.map { "test \($0)" } ?? "test \(d.lastPathComponent)"
        case .bench(_, let n): return "bench \(n)"
        }
    }
}
