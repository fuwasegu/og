import Foundation

// CONTRACT (owned by the Refactor agent; keep these signatures).

public struct FileDiffPreview: Sendable, Hashable {
    public var url: URL
    /// Unified diff text for display.
    public var unifiedDiff: String
    public var newText: String
}

public struct RenameRecord: Sendable, Hashable {
    /// Original content of every replaced file, for one-step undo.
    public var originals: [URL: String]
}

public enum RenameError: Error, Sendable, LocalizedError {
    case stageFailed(URL, String)
    case commitFailed(URL, String)
    public var errorDescription: String? {
        switch self {
        case .stageFailed(let u, let m): return "could not prepare \(u.lastPathComponent): \(m)"
        case .commitFailed(let u, let m): return "could not replace \(u.lastPathComponent): \(m) (all files restored)"
        }
    }
}

/// Two-phase rename apply (spec/design/refactor.fsl).
public enum RenameTransaction {
    /// Builds previews. `currentText` returns the editor's text for open files, else nil (read from disk).
    public static func preview(_ edit: LSPWorkspaceEdit, currentText: @Sendable (URL) -> String?) -> [FileDiffPreview] {
        var out: [FileDiffPreview] = []
        for uri in edit.changes.keys.sorted() {
            guard let edits = edit.changes[uri], !edits.isEmpty, let url = fileURL(uri) else { continue }
            guard let old = currentText(url) ?? (try? String(contentsOf: url, encoding: .utf8)) else { continue }
            let new = applyEdits(edits, to: old)
            guard new != old else { continue }
            out.append(FileDiffPreview(url: url, unifiedDiff: UnifiedDiff.make(old: old, new: new, path: url.path), newText: new))
        }
        return out
    }

    /// Stage all files to temps, then commit one by one with backups; rolls back on any failure.
    public static func apply(_ previews: [FileDiffPreview]) throws -> RenameRecord {
        try apply(previews, fileSystem: .live)
    }

    /// Restores every file in the record.
    public static func undo(_ record: RenameRecord) throws {
        var firstError: Error?
        for (url, text) in record.originals.sorted(by: { $0.key.path < $1.key.path }) {
            do {
                try Data(text.utf8).write(to: url.resolvingSymlinksInPath(), options: .atomic)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    /// Applies LSP text edits to a string (edits may be unordered).
    public static func applyEdits(_ edits: [LSPTextEdit], to text: String) -> String {
        let lines = TextLines(text)
        let result = NSMutableString(string: text)
        // Descending by start; for equal starts, later edits first so the array order is kept in the output.
        let ranged = edits.enumerated().map { (i, e) in (i, lines.nsRange(for: e.range), e.newText) }
            .sorted { a, b in
                if a.1.location != b.1.location { return a.1.location > b.1.location }
                if a.1.length != b.1.length { return a.1.length > b.1.length }
                return a.0 > b.0
            }
        var limit = result.length      // edits must end at or before the start of the previous (later) one
        for (_, r, newText) in ranged {
            // Overlapping edits (invalid per LSP): the later-starting one wins, the overlapping one is dropped.
            guard NSMaxRange(r) <= limit else { continue }
            result.replaceCharacters(in: r, with: newText)
            limit = r.location
        }
        return result as String
    }

    // MARK: - Two-phase apply

    /// File operations, injectable for tests.
    struct FileSystem: Sendable {
        var read: @Sendable (URL) throws -> String
        var writeTemp: @Sendable (Data, URL) throws -> Void
        var replace: @Sendable (_ temp: URL, _ target: URL) throws -> Void
        var remove: @Sendable (URL) -> Void

        static let live = FileSystem(
            read: { try String(contentsOf: $0, encoding: .utf8) },
            writeTemp: { data, url in
                guard FileManager.default.createFile(atPath: url.path, contents: data) else {
                    throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
                }
            },
            replace: { temp, target in
                if Foundation.rename(temp.path, target.path) != 0 {
                    let err = errno
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(err),
                                  userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(err))])
                }
            },
            remove: { try? FileManager.default.removeItem(at: $0) }
        )
    }

    static func apply(_ previews: [FileDiffPreview], fileSystem fs: FileSystem) throws -> RenameRecord {
        struct Staged { var target: URL; var temp: URL; var original: String; var key: URL }
        var staged: [Staged] = []
        // Phase 1 — stage: read originals and write every new text to a temp file next to its target.
        for p in previews {
            let target = p.url.resolvingSymlinksInPath()
            do {
                let original = try fs.read(target)
                let temp = target.deletingLastPathComponent()
                    .appendingPathComponent(".\(target.lastPathComponent).og-rename-\(UUID().uuidString.prefix(8))")
                try fs.writeTemp(Data(p.newText.utf8), temp)
                copyPermissions(from: target, to: temp)
                staged.append(Staged(target: target, temp: temp, original: original, key: p.url))
            } catch {
                for s in staged { fs.remove(s.temp) }
                throw RenameError.stageFailed(p.url, message(error))
            }
        }
        // Phase 2 — commit: atomically rename each temp over its target; originals stay in memory as backups.
        var committed: [Staged] = []
        for s in staged {
            do {
                try fs.replace(s.temp, s.target)
                committed.append(s)
            } catch {
                // Roll back: restore committed files, drop the remaining temps.
                for c in committed.reversed() { try? Data(c.original.utf8).write(to: c.target, options: .atomic) }
                for r in staged where !committed.contains(where: { $0.temp == r.temp }) { fs.remove(r.temp) }
                throw RenameError.commitFailed(s.key, message(error))
            }
        }
        var originals: [URL: String] = [:]
        for s in staged { originals[s.key] = s.original }
        return RenameRecord(originals: originals)
    }

    private static func copyPermissions(from: URL, to: URL) {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: from.path), let perm = attrs[.posixPermissions] {
            try? FileManager.default.setAttributes([.posixPermissions: perm], ofItemAtPath: to.path)
        }
    }

    private static func message(_ error: Error) -> String {
        let ns = error as NSError
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError { return underlying.localizedDescription }
        return ns.localizedDescription
    }

    static func fileURL(_ uri: String) -> URL? {
        if let u = URL(string: uri), u.isFileURL { return u.standardizedFileURL }
        if uri.hasPrefix("/") { return URL(fileURLWithPath: uri).standardizedFileURL }
        return nil
    }
}

/// Line-based unified diff (LCS over the changed middle, 3 lines of context).
enum UnifiedDiff {
    static func make(old: String, new: String, path: String, context: Int = 3) -> String {
        let a = splitLines(old), b = splitLines(new)
        var ops = diff(a, b)
        if ops.allSatisfy({ if case .same = $0 { return true }; return false }) { return "" }
        var out = "--- a\(path)\n+++ b\(path)\n"
        // Indices into ops for hunks.
        var i = 0
        let n = ops.count
        var aLine = 0, bLine = 0
        var positions: [(Int, Int)] = []   // (aLine, bLine) before op i
        for op in ops {
            positions.append((aLine, bLine))
            switch op {
            case .same: aLine += 1; bLine += 1
            case .del: aLine += 1
            case .add: bLine += 1
            }
        }
        positions.append((aLine, bLine))
        func isChange(_ k: Int) -> Bool { if case .same = ops[k] { return false }; return true }
        while i < n {
            guard let first = (i..<n).first(where: isChange) else { break }
            var start = max(i, first - context)
            if start < i { start = i }
            var end = first
            // extend while the next change is within 2*context
            var k = first
            while k < n {
                if isChange(k) { end = k; k += 1; continue }
                // run of same lines
                var j = k
                while j < n, !isChange(j) { j += 1 }
                if j < n && j - k <= 2 * context { k = j; continue }
                break
            }
            let stop = min(n, end + 1 + context)
            let (as0, bs0) = positions[start]
            var aCount = 0, bCount = 0
            var body = ""
            for m in start..<stop {
                switch ops[m] {
                case .same(let s): body += " \(s)\n"; aCount += 1; bCount += 1
                case .del(let s): body += "-\(s)\n"; aCount += 1
                case .add(let s): body += "+\(s)\n"; bCount += 1
                }
            }
            out += "@@ -\(range(as0, aCount)) +\(range(bs0, bCount)) @@\n" + body
            i = stop
        }
        ops.removeAll()
        return out
    }

    private static func range(_ start: Int, _ count: Int) -> String {
        let s = count == 0 ? start : start + 1
        return count == 1 ? "\(s)" : "\(s),\(count)"
    }

    enum Op { case same(String), del(String), add(String) }

    static func splitLines(_ s: String) -> [String] {
        var lines = s.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    static func diff(_ a: [String], _ b: [String]) -> [Op] {
        // Trim common prefix/suffix, then LCS on the middle.
        var pre = 0
        while pre < a.count, pre < b.count, a[pre] == b[pre] { pre += 1 }
        var suf = 0
        while suf < a.count - pre, suf < b.count - pre, a[a.count - 1 - suf] == b[b.count - 1 - suf] { suf += 1 }
        let am = Array(a[pre..<(a.count - suf)]), bm = Array(b[pre..<(b.count - suf)])
        var ops: [Op] = a[0..<pre].map { .same($0) }
        if am.count * bm.count > 4_000_000 {
            ops += am.map { .del($0) } + bm.map { .add($0) }
        } else {
            let n = am.count, m = bm.count
            var lcs = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
            if n > 0 && m > 0 {
                for i in stride(from: n - 1, through: 0, by: -1) {
                    for j in stride(from: m - 1, through: 0, by: -1) {
                        lcs[i][j] = am[i] == bm[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
                    }
                }
            }
            var i = 0, j = 0
            while i < n || j < m {
                if i < n, j < m, am[i] == bm[j] {
                    ops.append(.same(am[i])); i += 1; j += 1
                } else if j == m || (i < n && lcs[i + 1][j] >= lcs[i][j + 1]) {
                    ops.append(.del(am[i])); i += 1          // deletions before additions
                } else {
                    ops.append(.add(bm[j])); j += 1
                }
            }
        }
        ops += a[(a.count - suf)...].map { .same($0) }
        return ops
    }
}
