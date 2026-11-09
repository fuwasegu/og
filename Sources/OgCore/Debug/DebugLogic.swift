import Foundation

// Pure, testable pieces of the debugger (spec/design/run_debug.fsl).

// MARK: - Session state (DES-4)

public enum DebugPhase: Sendable, Equatable {
    case idle
    /// `dlv dap` is starting / building / launching.
    case launching
    case running
    /// Confirmed stop: stack and variables may be requested.
    case paused
    /// A next / stepIn / stepOut was sent; waiting for delve's next stop.
    case stepping
    case terminated
}

/// DES-4: stepping state; inspection only in a confirmed stop.
public struct DebugStateMachine: Sendable, Equatable {
    public private(set) var phase: DebugPhase = .idle
    /// Bumped on every confirmed stop. Inspection results tagged with an older value are stale.
    public private(set) var stopEpoch = 0

    public init() {}

    public var isLive: Bool {
        switch phase {
        case .launching, .running, .paused, .stepping: return true
        case .idle, .terminated: return false
        }
    }

    public var canInspect: Bool { phase == .paused }

    @discardableResult
    public mutating func launch() -> Bool {
        guard !isLive else { return false }
        phase = .launching
        return true
    }

    @discardableResult
    public mutating func launched() -> Bool {
        guard phase == .launching else { return false }
        phase = .running
        return true
    }

    /// delve reported a stop that the session decided to show.
    @discardableResult
    public mutating func stopped() -> Bool {
        switch phase {
        case .launching, .running, .stepping, .paused:
            phase = .paused
            stopEpoch += 1
            return true
        case .idle, .terminated:
            return false
        }
    }

    @discardableResult
    public mutating func resume() -> Bool {
        guard phase == .paused else { return false }
        phase = .running
        return true
    }

    @discardableResult
    public mutating func step() -> Bool {
        guard phase == .paused else { return false }
        phase = .stepping
        return true
    }

    /// The program exited / the debugger went away (also during a step: "as if stopped").
    public mutating func terminated() {
        phase = .terminated
    }
}

// MARK: - Breakpoints (DES-3)

/// One `setBreakpoints` request: a file and its 1-based lines (empty clears the file).
public struct BreakpointRequest: Sendable, Equatable, Hashable {
    public let path: String
    public let lines: [Int]

    public init(path: String, lines: [Int]) {
        self.path = path
        self.lines = lines
    }
}

/// A breakpoint as delve answered it.
public struct BreakpointAck: Sendable, Equatable {
    public let id: Int?
    /// Actual (possibly moved) 1-based line.
    public let line: Int?
    public let verified: Bool

    public init(id: Int?, line: Int?, verified: Bool) {
        self.id = id
        self.line = line
        self.verified = verified
    }
}

/// Mirrors the user's breakpoints (0-based, `BreakpointStore`) to delve (1-based, DAP),
/// and decides whether a breakpoint stop is for a breakpoint the user already removed.
public struct BreakpointLedger: Sendable {
    /// path -> 0-based lines the user currently has (bp_user).
    public private(set) var desired: [String: Set<Int>] = [:]
    /// path -> 0-based lines last sent to delve.
    public private(set) var sent: [String: Set<Int>] = [:]
    /// delve breakpoint id -> (path, requested 0-based line). Kept for the whole session.
    private var byID: [Int: Located] = [:]
    /// path -> actual 1-based line -> requested 0-based lines. Kept for the whole session.
    private var byActualLine: [String: [Int: Set<Int>]] = [:]

    private struct Located: Sendable { let path: String; let line0: Int }

    public init() {}

    /// Records the user's breakpoints and returns the files whose delve state must change.
    /// Files that lost all breakpoints get an empty request. Results are sorted by path.
    public mutating func update(desired all: [String: Set<Int>]) -> [BreakpointRequest] {
        let cleaned = all.filter { !$0.value.isEmpty }
        desired = cleaned
        var requests: [BreakpointRequest] = []
        for path in Set(sent.keys).union(cleaned.keys).sorted() {
            let want = cleaned[path] ?? []
            if sent[path] ?? [] == want { continue }
            sent[path] = want.isEmpty ? nil : want
            requests.append(BreakpointRequest(path: path, lines: want.sorted().map { $0 + 1 }))
        }
        return requests
    }

    /// Records delve's answer to a `setBreakpoints` request (acks in request order).
    public mutating func record(_ request: BreakpointRequest, acks: [BreakpointAck]) {
        for (i, requested1) in request.lines.enumerated() {
            let ack = i < acks.count ? acks[i] : nil
            let line0 = requested1 - 1
            if let id = ack?.id { byID[id] = Located(path: request.path, line0: line0) }
            let actual = ack?.line ?? requested1
            byActualLine[request.path, default: [:]][actual, default: []].insert(line0)
            byActualLine[request.path, default: [:]][requested1, default: []].insert(line0)
        }
    }

    /// DES-3: true when delve stopped at a breakpoint the user has removed meanwhile,
    /// so the session should continue silently instead of pausing.
    /// When in doubt (unknown breakpoint, other stop reasons) it returns false.
    public func shouldAutoContinue(reason: String, hitBreakpointIDs: [Int], path: String?, line: Int) -> Bool {
        guard reason == "breakpoint" else { return false }
        let known = hitBreakpointIDs.compactMap { byID[$0] }
        if !hitBreakpointIDs.isEmpty, known.count == hitBreakpointIDs.count {
            return !known.contains { desired[$0.path]?.contains($0.line0) ?? false }
        }
        guard let path else { return false }
        if desired[path]?.contains(line - 1) ?? false { return false }
        guard let requested = byActualLine[path]?[line], !requested.isEmpty else { return false }
        return !requested.contains { desired[path]?.contains($0) ?? false }
    }
}

// MARK: - Launch

public enum DAPLaunch {
    /// What delve should build and run.
    public enum Target: Sendable, Equatable {
        case main
        case test(name: String?)
        case bench(name: String)
    }

    /// `launch` request arguments for a run request (delve DAP).
    public static func arguments(for request: RunRequest) -> JSONValue {
        let target: Target
        switch request {
        case .runMain: target = .main
        case .test(_, let name): target = .test(name: name)
        case .bench(_, let name): target = .bench(name: name)
        }
        return arguments(target: target, directory: request.packageDir.standardizedFileURL.path, title: request.title)
    }

    public static func arguments(target: Target, directory dir: String, title: String) -> JSONValue {
        var args: [String: JSONValue] = [
            "name": .string(title),
            "type": "go",
            "request": "launch",
            "program": .string(dir),
            "cwd": .string(dir),
            "stopOnEntry": false,
            // Program stdout/stderr arrive as DAP `output` events.
            "outputMode": "remote",
        ]
        switch target {
        case .main:
            args["mode"] = "debug"
        case .test(let name):
            args["mode"] = "test"
            if let name, !name.isEmpty {
                args["args"] = ["-test.run", .string("^\(name)$")]
            }
        case .bench(let name):
            args["mode"] = "test"
            args["args"] = ["-test.run", "^$", "-test.bench", .string("^\(name)$")]
        }
        return .object(args)
    }

    public static let initializeArguments: JSONValue = [
        "clientID": "og",
        "clientName": "og",
        "adapterID": "go",
        "locale": "en-US",
        "linesStartAt1": true,
        "columnsStartAt1": true,
        "pathFormat": "path",
        "supportsVariableType": true,
        "supportsVariablePaging": false,
        "supportsRunInTerminalRequest": false,
        "supportsProgressReporting": false,
    ]
}

/// Parses delve's "DAP server listening at: 127.0.0.1:54321".
public enum DelveListenAddress {
    public static func parse(_ text: String) -> (host: String, port: UInt16)? {
        guard let marker = text.range(of: "listening at:") else { return nil }
        let rest = text[marker.upperBound...]
        let token = rest.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" }).first
        guard let token, let colon = token.lastIndex(of: ":") else { return nil }
        var host = String(token[token.startIndex..<colon])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard !host.isEmpty, let port = UInt16(token[token.index(after: colon)...]), port > 0 else { return nil }
        return (host, port)
    }
}
