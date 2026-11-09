import Foundation

public enum GoTestStatus: String, Sendable {
    case running, passed, failed, skipped
    /// Still running when the process ended (stopped, crashed, timed out without a report).
    case interrupted
}

/// Identifies a package (`test == ""`) or a test (`Test`, `Test/Sub`, ...) in a package.
public struct GoTestNodeID: Hashable, Sendable, CustomStringConvertible {
    public let package: String
    public let test: String

    public init(package: String, test: String = "") {
        self.package = package
        self.test = test
    }

    public var isPackage: Bool { test.isEmpty }
    /// The top-level test function name (`TestA` for `TestA/sub/deep`).
    public var topLevelTest: String { String(test.split(separator: "/", maxSplits: 1).first ?? "") }
    public var parent: GoTestNodeID? {
        if isPackage { return nil }
        guard let slash = test.lastIndex(of: "/") else { return GoTestNodeID(package: package) }
        return GoTestNodeID(package: package, test: String(test[..<slash]))
    }
    public var description: String { isPackage ? package : "\(package).\(test)" }
}

public struct GoTestNode: Sendable, Equatable {
    public let id: GoTestNodeID
    /// Display name: the package import path, or the last subtest component.
    public let name: String
    public var status: GoTestStatus
    /// Seconds, from the pass/fail/skip event.
    public var elapsed: Double?
    /// Output of this node and all of its descendants, in arrival order.
    public var output: String
    public var children: [GoTestNodeID]

    public var isPackage: Bool { id.isPackage }

    /// GoLand-style duration: `12 ms`, `1.25 s`.
    public static func formatElapsed(_ seconds: Double) -> String {
        if seconds < 1 { return "\(Int((seconds * 1000).rounded())) ms" }
        if seconds < 60 { return String(format: "%.2f s", seconds) }
        let total = Int(seconds.rounded())
        return "\(total / 60) m \(total % 60) s"
    }
}

/// The package → test → subtest tree of one `go test -json` run.
public struct GoTestReport: Sendable, Equatable {
    public private(set) var packages: [GoTestNodeID] = []
    public private(set) var nodes: [GoTestNodeID: GoTestNode] = [:]

    public init() {}

    public subscript(id: GoTestNodeID) -> GoTestNode? { nodes[id] }

    /// Children of a node; `nil` means the top level (packages).
    public func children(of id: GoTestNodeID?) -> [GoTestNodeID] {
        guard let id else { return packages }
        return nodes[id]?.children ?? []
    }

    public struct Summary: Sendable, Equatable {
        public var passed = 0, failed = 0, skipped = 0, running = 0, interrupted = 0
        public var total: Int { passed + failed + skipped + running + interrupted }
        /// Package-level failures without failing tests (e.g. build failures).
        public var failedPackages = 0
    }

    /// Counts over tests and subtests (packages excluded).
    public var summary: Summary {
        var s = Summary()
        for node in nodes.values {
            if node.isPackage {
                if node.status == .failed && !node.children.contains(where: { nodes[$0]?.status == .failed }) {
                    s.failedPackages += 1
                }
                continue
            }
            switch node.status {
            case .passed: s.passed += 1
            case .failed: s.failed += 1
            case .skipped: s.skipped += 1
            case .running: s.running += 1
            case .interrupted: s.interrupted += 1
            }
        }
        return s
    }

    /// Creates the node (and missing ancestors) if needed.
    @discardableResult
    mutating func ensure(_ id: GoTestNodeID) -> GoTestNodeID {
        if nodes[id] != nil { return id }
        if let parent = id.parent {
            ensure(parent)
            nodes[parent]?.children.append(id)
        } else {
            packages.append(id)
        }
        let name = id.isPackage ? id.package : String(id.test.split(separator: "/").last ?? Substring(id.test))
        nodes[id] = GoTestNode(id: id, name: name, status: .running, elapsed: nil, output: "", children: [])
        return id
    }

    mutating func setStatus(_ id: GoTestNodeID, _ status: GoTestStatus, elapsed: Double?) {
        ensure(id)
        nodes[id]?.status = status
        if let elapsed { nodes[id]?.elapsed = elapsed }
    }

    mutating func appendOutput(_ id: GoTestNodeID, _ text: String) {
        ensure(id)
        var cur: GoTestNodeID? = id
        while let c = cur {
            nodes[c]?.output += text
            cur = c.parent
        }
    }

    /// Marks every node that never reported a result.
    mutating func interruptRunning() {
        for (id, node) in nodes where node.status == .running {
            nodes[id]?.status = .interrupted
        }
    }
}

/// Incremental parser for `go test -json` (test2json) output.
public struct GoTestEventParser: Sendable {
    /// Text to show in the console, attributed to a package when known.
    public struct Output: Sendable, Equatable {
        public let text: String
        public let package: String?
        /// True for lines that were not test2json events (raw tool output).
        public let raw: Bool
        public init(text: String, package: String?, raw: Bool) {
            self.text = text
            self.package = package
            self.raw = raw
        }
    }

    struct Event: Decodable {
        let Action: String
        let Package: String?
        let Test: String?
        let Elapsed: Double?
        let Output: String?
        let ImportPath: String?
    }

    public private(set) var report = GoTestReport()
    private var buffer = ""

    public init() {}

    /// Feeds a chunk of stdout; returns console output for every complete line.
    public mutating func consume(_ chunk: String) -> [Output] {
        buffer += chunk
        var out: [Output] = []
        while let nl = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<nl])
            buffer.removeSubrange(...nl)
            if let o = consume(line: line) { out.append(o) }
        }
        return out
    }

    /// Flushes a trailing partial line and closes still-running nodes.
    public mutating func finish() -> [Output] {
        var out: [Output] = []
        if !buffer.isEmpty {
            let line = buffer
            buffer = ""
            if let o = consume(line: line) { out.append(o) }
        }
        report.interruptRunning()
        return out
    }

    /// Parses one line (without the trailing newline).
    public mutating func consume(line: String) -> Output? {
        let trimmed = line.hasSuffix("\r") ? String(line.dropLast()) : line
        guard trimmed.hasPrefix("{"),
              let event = try? JSONDecoder().decode(Event.self, from: Data(trimmed.utf8)) else {
            return trimmed.isEmpty && line.isEmpty ? Output(text: "\n", package: nil, raw: true)
                : Output(text: trimmed + "\n", package: nil, raw: true)
        }
        return apply(event)
    }

    private mutating func apply(_ e: Event) -> Output? {
        switch e.Action {
        case "build-output":
            let pkg = e.ImportPath.map(GoTestEventParser.packageFromImportPath)
            guard let text = e.Output else { return nil }
            if let pkg { report.appendOutput(report.ensure(GoTestNodeID(package: pkg)), text) }
            return Output(text: text, package: pkg, raw: false)
        case "build-fail":
            if let pkg = e.ImportPath.map(GoTestEventParser.packageFromImportPath) {
                report.setStatus(GoTestNodeID(package: pkg), .failed, elapsed: nil)
            }
            return nil
        default:
            break
        }
        guard let pkg = e.Package else {
            return e.Output.map { Output(text: $0, package: nil, raw: false) }
        }
        let id = GoTestNodeID(package: pkg, test: e.Test ?? "")
        switch e.Action {
        case "start", "run", "cont":
            report.setStatus(id, .running, elapsed: nil)
        case "pause":
            report.ensure(id)
        case "pass":
            report.setStatus(id, .passed, elapsed: e.Elapsed)
        case "fail":
            report.setStatus(id, .failed, elapsed: e.Elapsed)
        case "skip":
            report.setStatus(id, .skipped, elapsed: e.Elapsed)
        case "output", "bench":
            guard let text = e.Output else { return nil }
            report.appendOutput(id, text)
            return Output(text: text, package: pkg, raw: false)
        default:
            break
        }
        return nil
    }

    /// `example.com/x [example.com/x.test]` → `example.com/x`.
    static func packageFromImportPath(_ path: String) -> String {
        if let space = path.firstIndex(of: " ") { return String(path[..<space]) }
        return path
    }
}
