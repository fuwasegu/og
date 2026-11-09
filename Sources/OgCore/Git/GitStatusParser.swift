import Foundation

/// One changed path from `git status`.
struct GitStatusEntry: Sendable, Hashable {
    var state: GitFileState
    /// Original path (relative to the project root) of a rename/copy; nil otherwise.
    var origin: String?
    /// Whether the change is staged in the index (X column) — informational.
    var indexStatus: Character
    var worktreeStatus: Character
}

struct GitStatusSnapshot: Sendable {
    var branch: String?
    var headOID: String?
    /// Path relative to the project root -> entry.
    var entries: [String: GitStatusEntry] = [:]
    var hasStash = false

    var status: GitStatus {
        GitStatus(branch: branch, files: entries.mapValues(\.state), hasStash: hasStash)
    }
}

/// Parser for `git status --porcelain=v2 --branch -z`.
enum GitStatusParser {
    /// - Parameters:
    ///   - data: raw NUL-separated output.
    ///   - prefix: project root relative to the repository root (`git rev-parse --show-prefix`),
    ///     e.g. "" or "svc/api/". Paths outside the prefix are dropped; the rest become relative to it.
    static func parse(_ data: Data, prefix: String) -> GitStatusSnapshot {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        return parse(fields: fields, prefix: prefix)
    }

    static func parse(_ text: String, prefix: String) -> GitStatusSnapshot {
        parse(fields: text.components(separatedBy: "\u{0}"), prefix: prefix)
    }

    static func parse(fields: [String], prefix: String) -> GitStatusSnapshot {
        var snap = GitStatusSnapshot()
        var detached = false
        var i = 0
        func relative(_ repoPath: String) -> String? {
            if prefix.isEmpty { return repoPath }
            return repoPath.hasPrefix(prefix) ? String(repoPath.dropFirst(prefix.count)) : nil
        }
        // A rename origin outside the project is expressed relative to the project root ("../x.go").
        let up = String(repeating: "../", count: prefix.split(separator: "/").count)
        func originPath(_ repoPath: String) -> String { relative(repoPath) ?? up + repoPath }
        while i < fields.count {
            let line = fields[i]
            i += 1
            guard let kind = line.first else { continue }
            switch kind {
            case "#":
                let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
                guard parts.count == 3 else { continue }
                switch parts[1] {
                case "branch.head":
                    if parts[2] == "(detached)" { detached = true } else { snap.branch = parts[2] }
                case "branch.oid":
                    snap.headOID = parts[2] == "(initial)" ? nil : parts[2]
                case "stash":
                    snap.hasStash = (Int(parts[2]) ?? 0) > 0
                default: break
                }
            case "1", "2", "u":
                // 1 XY sub mH mI mW hH hI path
                // 2 XY sub mH mI mW hH hI Xscore path \0 origPath
                // u XY sub m1 m2 m3 mW h1 h2 h3 path
                let count = kind == "1" ? 9 : (kind == "2" ? 10 : 11)
                let parts = line.split(separator: " ", maxSplits: count - 1, omittingEmptySubsequences: false).map(String.init)
                var origin: String?
                if kind == "2", i < fields.count {
                    origin = fields[i]
                    i += 1
                }
                guard parts.count == count, parts[1].count == 2 else { continue }
                let xy = Array(parts[1])
                let x = xy[0], y = xy[1]
                guard let path = relative(parts[count - 1]) else { continue }
                let state: GitFileState
                if kind == "u" {
                    state = .conflicted
                } else if kind == "2" {
                    state = .renamed
                } else if x == "D" || y == "D" {
                    state = x == "A" ? .added : .deleted
                } else if x == "A" {
                    state = .added
                } else {
                    state = .modified
                }
                snap.entries[path] = GitStatusEntry(state: state, origin: origin.map(originPath),
                                                    indexStatus: x, worktreeStatus: y)
            case "?", "!":
                let path = String(line.dropFirst(2))
                guard !path.isEmpty, let rel = relative(path) else { continue }
                snap.entries[rel] = GitStatusEntry(state: kind == "?" ? .untracked : .ignored, origin: nil,
                                                   indexStatus: kind, worktreeStatus: kind)
            default:
                continue
            }
        }
        if detached {
            snap.branch = "HEAD detached at " + String((snap.headOID ?? "unknown").prefix(7))
        }
        return snap
    }
}
