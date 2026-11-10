import Foundation

/// Tracks what the user has typed on the shell's command line, from the bytes sent to the pty.
///
/// The shell owns the line, so this is a best guess: anything og cannot follow (history keys,
/// shell tab completion, cursor movement) marks the line unknown until the next Return.
public struct TerminalLineTracker: Sendable {
    /// The typed command line, or nil when it cannot be known.
    public private(set) var line: String? = ""

    public init() {}

    /// Feeds bytes going to the shell. Returns a command that was just submitted with Return.
    public mutating func feed(_ bytes: some Sequence<UInt8>) -> String? {
        var submitted: String?
        var escape = false
        for b in bytes {
            if escape {
                // CSI / SS3 sequences end with a letter or `~`; any of them moves the shell's cursor or line.
                if (b >= 0x40 && b <= 0x7e) && b != 0x5b && b != 0x4f { escape = false }
                continue
            }
            switch b {
            case 0x0d, 0x0a:  // Return
                let cmd = line?.trimmingCharacters(in: .whitespaces) ?? ""
                if !cmd.isEmpty, line != nil { submitted = cmd }
                line = ""
            case 0x03, 0x15, 0x04:  // ^C, ^U, ^D
                line = ""
            case 0x7f, 0x08:  // Backspace
                if var l = line, !l.isEmpty { l.removeLast(); line = l } else if line != nil { line = "" }
            case 0x1b:
                escape = true
                line = nil
            case 0x20...0x7e:
                line?.append(Character(UnicodeScalar(b)))
            case 0x80...0xff:
                line = nil  // non-ASCII: byte-level tracking would be wrong
            default:
                line = nil  // Tab (shell completion), ^A, ^E, ^R, ...
            }
        }
        return submitted
    }

    public mutating func reset() { line = "" }
}

/// Command suggestions for the terminal: the project's own history first, then common Go commands.
public enum TerminalSuggestions {
    public static let common: [String] = [
        "go run .",
        "go mod tidy",
        "go test ./...",
        "go build ./...",
        "go vet ./...",
        "go generate ./...",
        "go mod download",
        "go get -u ./...",
        "go test -race ./...",
        "go test -bench . ./...",
        "go fmt ./...",
        "go work sync",
        "golangci-lint run",
        "git status",
        "git diff",
        "git log --oneline",
        "git pull",
        "git push",
    ]

    /// The rest of the best command for `typed`, or nil. `history` is most recent first.
    public static func completion(for typed: String, history: [String]) -> String? {
        guard !typed.isEmpty, !typed.allSatisfy({ $0 == " " }) else { return nil }
        for cmd in history + common where cmd.count > typed.count && cmd.hasPrefix(typed) {
            return String(cmd.dropFirst(typed.count))
        }
        return nil
    }

    /// Adds a submitted command to a most-recent-first history (deduplicated, bounded).
    public static func remember(_ command: String, in history: [String], limit: Int = 200) -> [String] {
        let cmd = command.trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty else { return history }
        return Array(([cmd] + history.filter { $0 != cmd }).prefix(limit))
    }
}
