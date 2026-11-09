import Foundation

/// A thread as reported by DAP `threads`.
public struct DAPThread: Sendable, Equatable, Hashable {
    public let id: Int
    public let name: String

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }

    init?(json: JSONValue) {
        guard let id = json["id"]?.intValue else { return nil }
        self.init(id: id, name: json["name"]?.stringValue ?? "thread \(id)")
    }
}

/// One stack frame. `line` / `column` are 1-based (DAP, `linesStartAt1`).
public struct DAPStackFrame: Sendable, Equatable, Hashable {
    public let id: Int
    public let name: String
    /// Absolute source path, or nil for frames without source (runtime / assembly).
    public let path: String?
    public let line: Int
    public let column: Int

    public init(id: Int, name: String, path: String?, line: Int, column: Int) {
        self.id = id
        self.name = name
        self.path = path
        self.line = line
        self.column = column
    }

    init?(json: JSONValue) {
        guard let id = json["id"]?.intValue else { return nil }
        let path = json["source"]?["path"]?.stringValue
        self.init(
            id: id,
            name: json["name"]?.stringValue ?? "?",
            path: (path?.isEmpty ?? true) ? nil : path,
            line: json["line"]?.intValue ?? 0,
            column: json["column"]?.intValue ?? 0
        )
    }

    /// 0-based line for the editor (`BreakpointStore`, `ProjectContext.debugStop`).
    public var line0: Int { max(0, line - 1) }
}

public struct DAPScope: Sendable, Equatable, Hashable {
    public let name: String
    public let variablesReference: Int
    public let expensive: Bool

    public init(name: String, variablesReference: Int, expensive: Bool) {
        self.name = name
        self.variablesReference = variablesReference
        self.expensive = expensive
    }

    init?(json: JSONValue) {
        guard let name = json["name"]?.stringValue else { return nil }
        self.init(name: name,
                  variablesReference: json["variablesReference"]?.intValue ?? 0,
                  expensive: json["expensive"]?.boolValue ?? false)
    }
}

/// A variable; `variablesReference > 0` means it has lazily fetched children.
public struct DAPVariable: Sendable, Equatable, Hashable {
    public let name: String
    public let value: String
    public let type: String
    public let variablesReference: Int

    public init(name: String, value: String, type: String, variablesReference: Int) {
        self.name = name
        self.value = value
        self.type = type
        self.variablesReference = variablesReference
    }

    init?(json: JSONValue) {
        guard let name = json["name"]?.stringValue else { return nil }
        self.init(name: name,
                  value: json["value"]?.stringValue ?? "",
                  type: json["type"]?.stringValue ?? "",
                  variablesReference: json["variablesReference"]?.intValue ?? 0)
    }
}

public struct DAPEvaluateResult: Sendable, Equatable {
    public let result: String
    public let type: String
    public let variablesReference: Int

    public init(result: String, type: String, variablesReference: Int) {
        self.result = result
        self.type = type
        self.variablesReference = variablesReference
    }
}

/// A confirmed pause (DES-3: never emitted for a stop at an already removed breakpoint).
public struct DAPStop: Sendable, Equatable {
    public let reason: String
    public let description: String?
    public let threadID: Int
    /// Stack of the stopped thread, innermost first.
    public let frames: [DAPStackFrame]

    public init(reason: String, description: String?, threadID: Int, frames: [DAPStackFrame]) {
        self.reason = reason
        self.description = description
        self.threadID = threadID
        self.frames = frames
    }

    /// The frame to show: the innermost one that has source.
    public var topFrameWithSource: DAPStackFrame? { frames.first { $0.path != nil } }
}

/// Events surfaced by `DAPSession`, delivered in order through its `onEvent` callback.
public enum DAPEvent: Sendable, Equatable {
    /// Program or debugger output. `category` is DAP's (`stdout`, `stderr`, `console`, ...).
    case output(category: String, text: String)
    /// Launch finished; the program is running.
    case started
    /// The session paused (confirmed stop).
    case stopped(DAPStop)
    /// The program runs again (after continue / step started).
    case continued
    /// The session stopped at a breakpoint the user already removed and continued silently (DES-3).
    case autoContinued(path: String, line: Int)
    case exited(code: Int)
    /// The session is over (program ended, debugger disconnected or died).
    case terminated
}

public enum DAPError: Error, LocalizedError, Sendable {
    case delveNotFound
    case delveDidNotListen(String)
    case connectFailed(String)
    case notPaused
    case notRunning

    public var errorDescription: String? {
        switch self {
        case .delveNotFound: return "dlv not found (go install github.com/go-delve/delve/cmd/dlv@latest)"
        case .delveDidNotListen(let out): return "dlv did not start a DAP server: \(out)"
        case .connectFailed(let why): return "could not connect to dlv: \(why)"
        case .notPaused: return "the debugger is not paused"
        case .notRunning: return "no debug session"
        }
    }
}
