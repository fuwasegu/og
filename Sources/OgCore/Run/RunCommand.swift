import Foundation

/// The concrete `go` invocation for a `RunRequest`.
public struct RunCommand: Sendable, Hashable {
    /// Arguments after `go` (e.g. `["test", "-json", "-v", "."]`).
    public let arguments: [String]
    public let directory: URL
    /// True when stdout is a `go test -json` event stream.
    public let isTestJSON: Bool

    public init(arguments: [String], directory: URL, isTestJSON: Bool) {
        self.arguments = arguments
        self.directory = directory
        self.isTestJSON = isTestJSON
    }

    /// `name == "./..."` runs every package below `packageDir`.
    public init(_ request: RunRequest) {
        switch request {
        case .runMain(let dir):
            self.init(arguments: ["run", "."], directory: dir, isTestJSON: false)
        case .test(let dir, let name):
            var args = ["test", "-json"]
            if name == "./..." {
                args.append("./...")
            } else {
                args.append("-v")
                if let name, !name.isEmpty { args += ["-run", "^\(RunCommand.anchoredPattern(name))$"] }
                args.append(".")
            }
            self.init(arguments: args, directory: dir, isTestJSON: true)
        case .bench(let dir, let name):
            self.init(arguments: ["test", "-run", "^$", "-bench", "^\(RunCommand.anchoredPattern(name))$", "-benchmem", "."],
                      directory: dir, isTestJSON: false)
        }
    }

    /// `go test -run` splits the pattern on unbracketed `/` and anchors each level,
    /// so `TestA/sub` becomes `^TestA$/^sub$`.
    static func anchoredPattern(_ name: String) -> String {
        name.split(separator: "/", omittingEmptySubsequences: false)
            .map { escapeRegex(String($0)) }
            .joined(separator: "$/^")
    }

    static func escapeRegex(_ s: String) -> String {
        let special: Set<Character> = ["\\", ".", "+", "*", "?", "(", ")", "|", "[", "]", "{", "}", "^", "$"]
        var out = ""
        for c in s {
            if special.contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }

    /// Shell-like rendering for the console header.
    public var displayString: String {
        (["go"] + arguments).map { arg in
            arg.contains(where: { " \"'$^*?".contains($0) }) ? "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'" : arg
        }.joined(separator: " ")
    }
}

/// DES-2: every launch gets a new generation; stop/rerun closes the current one
/// immediately, and events carrying an older generation are dropped.
public struct RunGeneration: Sendable, Equatable {
    public private(set) var current: Int = 0
    public private(set) var isOpen = false

    public init() {}

    /// Opens a new generation for a launch and returns it.
    public mutating func begin() -> Int {
        current += 1
        isOpen = true
        return current
    }

    /// Closes the current generation (stop / exit). Later events for it are dropped.
    public mutating func close() { isOpen = false }

    /// True if an event from `generation` may still be shown.
    public func accepts(_ generation: Int) -> Bool { isOpen && generation == current }
}
