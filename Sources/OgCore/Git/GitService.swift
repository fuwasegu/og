import Foundation

// CONTRACT (owned by the Git agent; keep these signatures).

public enum GitFileState: String, Sendable, Hashable {
    case modified, added, deleted, renamed, untracked, conflicted, ignored
}

public struct GitStatus: Sendable, Hashable {
    public var branch: String?
    /// Path relative to the project root (`GitService.root`) -> state.
    /// (Equal to repository-relative paths when the project root is the repository root.)
    public var files: [String: GitFileState]
    public var hasStash: Bool
    public init(branch: String? = nil, files: [String: GitFileState] = [:], hasStash: Bool = false) {
        self.branch = branch; self.files = files; self.hasStash = hasStash
    }
}

public enum GitLineChangeKind: Sendable, Hashable { case added, modified, deleted }

/// A changed line range in the working copy relative to HEAD (0-based lines).
/// For `.deleted`, `lineCount` is 0 and the lines were removed just before `startLine`.
public struct GitLineChange: Sendable, Hashable {
    public var startLine: Int
    public var lineCount: Int
    public var kind: GitLineChangeKind
    public init(startLine: Int, lineCount: Int, kind: GitLineChangeKind) {
        self.startLine = startLine; self.lineCount = lineCount; self.kind = kind
    }
}

/// Serializes every git invocation through one queue (spec/design/vcs.fsl DES-1).
///
/// Each public method runs as ONE closure on `GitRunner.queue` (a serial DispatchQueue), so
/// multi-step operations (re-check, then act) are atomic with respect to every other og git
/// call, and actor reentrancy across `await` can never start two git processes at once.
/// Operations re-check the real working tree when they run (DES-2) and throw `GitError`
/// carrying git's message (or og's refusal reason).
public actor GitService {
    public let root: URL
    private let runner: GitRunner

    public init(root: URL) {
        self.root = root
        self.runner = GitRunner(root: root)
    }

    public func isRepository() async -> Bool {
        await runner.serial { $0.isRepository() }
    }

    public func status() async -> GitStatus {
        await runner.serial { $0.readStatus()?.status ?? GitStatus() }
    }

    /// Changes of `currentText` relative to the file's HEAD version (untracked/new file: all added).
    public func lineChanges(relativePath: String, currentText: String) async -> [GitLineChange] {
        let head: String? = await runner.serial { r -> String? in
            guard r.prefix() != nil else { return nil }
            let show = r.run(["show", "HEAD:./" + relativePath], literalPathspecs: false)
            if show.ok {
                if show.stdout.contains(0) { return nil }  // binary
                return String(decoding: show.stdout, as: UTF8.self)
            }
            // Not in HEAD: new or untracked file, unless git ignores it.
            if r.run(["check-ignore", "-q", "--", relativePath]).ok { return nil }
            return ""
        }
        guard let head else { return [] }
        return LineDiff.changes(old: head, new: currentText)
    }

    /// Unified diff of the working-tree file against HEAD (new/untracked files: against /dev/null).
    public func diff(relativePath: String) async -> String {
        await runner.serial { r -> String in
            guard let snap = r.readStatus() else { return "" }
            let entry = snap.entries[relativePath]
            let base = ["diff", "--no-color", "--no-ext-diff"]
            if entry?.state == .untracked || (entry?.state == .added && !r.hasHead()) {
                // `--no-index` exits with 1 when the files differ.
                return r.run(base + ["--no-index", "--", "/dev/null", relativePath]).text
            }
            guard r.hasHead() else { return "" }
            var paths = [relativePath]
            if let origin = entry?.origin { paths.insert(origin, at: 0) }
            let d = r.run(base + ["-M", "HEAD", "--"] + paths)
            return d.ok ? d.text : d.message
        }
    }

    /// Local branch names.
    public func branches() async -> [String] {
        await runner.serial { r -> [String] in
            let res = r.run(["for-each-ref", "--sort=refname", "--format=%(refname:short)", "refs/heads"])
            guard res.ok else { return [] }
            return res.text.split(separator: "\n").map(String.init)
        }
    }

    /// Commits exactly `paths` (relative to the project root): untracked ones are added first,
    /// other staged changes are left out of the commit.
    public func commit(paths: [String], message: String) async throws {
        let msg = message.trimmingCharacters(in: .whitespacesAndNewlines)
        try await runner.serial { r in
            guard !msg.isEmpty else { throw GitError("Commit message is empty.") }
            guard let snap = r.readStatus() else { throw GitError("Not a git repository") }
            // DES-2: decide against the real working tree, not the cached status.
            let selected = paths.filter { p in snap.entries[p].map { $0.state != .ignored } ?? false }
            guard !selected.isEmpty else { throw GitError("Nothing to commit: none of the selected files has changes.") }
            if let conflicted = selected.first(where: { snap.entries[$0]?.state == .conflicted }) {
                throw GitError("Cannot commit: \(conflicted) has unresolved conflicts.")
            }
            let untracked = selected.filter { snap.entries[$0]?.state == .untracked }
            if !untracked.isEmpty { try r.check(["add", "--"] + untracked) }
            var pathspec: [String] = []
            for p in selected {
                if let origin = snap.entries[p]?.origin { pathspec.append(origin) }
                pathspec.append(p)
            }
            let res = r.run(["commit", "--quiet", "-m", msg, "--only", "--"] + pathspec)
            if !res.ok {
                // Do not leave freshly added files staged when the commit fails.
                if !untracked.isEmpty { _ = r.run(["reset", "--quiet", "--"] + untracked) }
                throw GitError(res.message)
            }
        }
    }

    /// Switches to a local branch; refused if the working tree has uncommitted changes (ASSUME-3).
    public func checkout(branch: String) async throws {
        try await runner.serial { r in
            guard let snap = r.readStatus() else { throw GitError("Not a git repository") }
            if snap.branch == branch { throw GitError("Already on '\(branch)'.") }
            let exists = r.run(["show-ref", "--verify", "--quiet", "refs/heads/" + branch]).ok
            guard exists else { throw GitError("Branch '\(branch)' does not exist.") }
            try r.requireClean("switch to '\(branch)'")
            try r.check(["switch", "--quiet", branch])
        }
    }

    /// Creates a branch at HEAD and switches to it (uncommitted changes are carried along).
    public func createBranch(_ name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try await runner.serial { r in
            guard r.prefix() != nil else { throw GitError("Not a git repository") }
            guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else { throw GitError("'\(trimmed)' is not a valid branch name.") }
            let fmt = r.run(["check-ref-format", "--branch", trimmed])
            guard fmt.ok else { throw GitError("'\(trimmed)' is not a valid branch name.") }
            try r.check(["switch", "--quiet", "-c", trimmed])
        }
    }

    /// Stashes every change including untracked files. og keeps at most one stash entry.
    public func stash() async throws {
        try await runner.serial { r in
            guard let snap = r.readStatus() else { throw GitError("Not a git repository") }
            if snap.hasStash { throw GitError("A stash already exists. Unstash it before stashing again.") }
            guard snap.entries.values.contains(where: { $0.state != .ignored }) else {
                throw GitError("No local changes to stash.")
            }
            guard r.hasHead() else { throw GitError("Cannot stash before the first commit.") }
            // Scoped to the project root ("."); `git stash` uses pathspec magic internally,
            // so it must not run with --literal-pathspecs.
            try r.check(["stash", "push", "--quiet", "--include-untracked", "-m", "og stash", "--", "."],
                        literalPathspecs: false)
        }
    }

    /// Restores the stash onto a clean working tree.
    public func stashPop() async throws {
        try await runner.serial { r in
            guard r.prefix() != nil else { throw GitError("Not a git repository") }
            guard r.hasStash() else { throw GitError("There is no stash to restore.") }
            try r.requireClean("unstash")
            try r.check(["stash", "pop", "--quiet"], literalPathspecs: false)
        }
    }

    /// Restores a tracked file (index and working tree) to HEAD. Refused for untracked files.
    /// A file added since HEAD is unstaged (it becomes untracked; its content is kept).
    public func rollback(relativePath: String) async throws {
        try await runner.serial { r in
            guard let snap = r.readStatus() else { throw GitError("Not a git repository") }
            guard let entry = snap.entries[relativePath], entry.state != .ignored else {
                throw GitError("\(relativePath) has no changes to roll back.")
            }
            switch entry.state {
            case .untracked:
                throw GitError("\(relativePath) is not tracked by git; there is no committed version to roll back to.")
            case .added where entry.origin == nil:
                try r.check(["restore", "--staged", "--", relativePath])
            default:
                guard r.hasHead() else { throw GitError("Nothing has been committed yet.") }
                var paths = [relativePath]
                if let origin = entry.origin { paths.append(origin) }
                try r.check(["restore", "--source=HEAD", "--staged", "--worktree", "--"] + paths)
            }
        }
    }

    /// Whether a stash entry exists.
    public func hasStash() async -> Bool {
        await runner.serial { $0.hasStash() }
    }
}
