import Foundation

/// User breakpoints (gutter). Lines are 0-based.
@MainActor
final class BreakpointStore {
    private(set) var lines: [URL: Set<Int>] = [:]
    private weak var context: ProjectContext?

    init(context: ProjectContext) { self.context = context }

    func toggle(_ url: URL, line: Int) {
        var set = lines[url.standardizedFileURL] ?? []
        if set.contains(line) { set.remove(line) } else { set.insert(line) }
        lines[url.standardizedFileURL] = set.isEmpty ? nil : set
        NotificationCenter.default.post(name: .ogBreakpointsChanged, object: context)
    }

    func has(_ url: URL, line: Int) -> Bool { lines[url.standardizedFileURL]?.contains(line) ?? false }

    func lines(in url: URL) -> Set<Int> { lines[url.standardizedFileURL] ?? [] }

    /// Shift breakpoints after an edit inserted/removed lines at `line`.
    func shift(_ url: URL, from line: Int, by delta: Int) {
        guard delta != 0, let set = lines[url.standardizedFileURL] else { return }
        lines[url.standardizedFileURL] = Set(set.compactMap { l in
            if l < line { return l }
            let n = l + delta
            return n >= line ? n : nil
        })
    }
}
