import Foundation

/// In-process line diff (Myers O(ND)) used for the editor's change gutter.
public enum LineDiff {
    /// A differing region: `oldCount` lines at `oldStart` were replaced by `newCount` lines at `newStart`.
    public struct Hunk: Sendable, Hashable {
        public var oldStart: Int, oldCount: Int, newStart: Int, newCount: Int
        public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int) {
            self.oldStart = oldStart; self.oldCount = oldCount; self.newStart = newStart; self.newCount = newCount
        }
    }

    /// Above this edit distance the middle region is reported as one hunk (bounds time and memory).
    static let maxEditDistance = 1500

    /// Splits text into lines on "\n" (a trailing newline does not start an extra line; "\r" stays in the line).
    public static func lines(_ text: String) -> [Substring] {
        if text.isEmpty { return [] }
        var result: [Substring] = []
        var start = text.startIndex
        let utf8 = text.utf8
        var i = utf8.startIndex
        while i != utf8.endIndex {
            if utf8[i] == 10 {
                // Slice through the UTF-8 view so a "\r\n" grapheme is split exactly at the "\n".
                result.append(Substring(utf8[start..<i]))
                start = utf8.index(after: i)
            }
            i = utf8.index(after: i)
        }
        if start != utf8.endIndex { result.append(Substring(utf8[start..<utf8.endIndex])) }
        return result
    }

    /// Changes in `new` relative to `old`, with 0-based line numbers in `new`.
    public static func changes(old: String, new: String) -> [GitLineChange] {
        changes(from: hunks(old: lines(old), new: lines(new)))
    }

    public static func changes(from hunks: [Hunk]) -> [GitLineChange] {
        hunks.map { h in
            if h.newCount == 0 { return GitLineChange(startLine: h.newStart, lineCount: 0, kind: .deleted) }
            if h.oldCount == 0 { return GitLineChange(startLine: h.newStart, lineCount: h.newCount, kind: .added) }
            return GitLineChange(startLine: h.newStart, lineCount: h.newCount, kind: .modified)
        }
    }

    public static func hunks<S: Hashable>(old: [S], new: [S]) -> [Hunk] {
        // Intern lines so comparisons are integer compares.
        var ids: [S: Int] = [:]
        let a = old.map { s -> Int in if let id = ids[s] { return id }; let id = ids.count; ids[s] = id; return id }
        let b = new.map { s -> Int in if let id = ids[s] { return id }; let id = ids.count; ids[s] = id; return id }
        return hunks(a, b)
    }

    static func hunks(_ a: [Int], _ b: [Int]) -> [Hunk] {
        // Trim the common prefix and suffix.
        var lo = 0
        while lo < a.count, lo < b.count, a[lo] == b[lo] { lo += 1 }
        var ea = a.count, eb = b.count
        while ea > lo, eb > lo, a[ea - 1] == b[eb - 1] { ea -= 1; eb -= 1 }
        if lo == ea && lo == eb { return [] }
        let midA = Array(a[lo..<ea]), midB = Array(b[lo..<eb])
        guard let ops = myers(midA, midB) else {
            return [Hunk(oldStart: lo, oldCount: ea - lo, newStart: lo, newCount: eb - lo)]
        }
        // Group runs of non-equal ops into hunks.
        var result: [Hunk] = []
        var x = 0, y = 0
        var current: Hunk?
        for op in ops {
            switch op {
            case .equal:
                if let c = current { result.append(c); current = nil }
                x += 1; y += 1
            case .delete:
                if current == nil { current = Hunk(oldStart: lo + x, oldCount: 0, newStart: lo + y, newCount: 0) }
                current?.oldCount += 1
                x += 1
            case .insert:
                if current == nil { current = Hunk(oldStart: lo + x, oldCount: 0, newStart: lo + y, newCount: 0) }
                current?.newCount += 1
                y += 1
            }
        }
        if let c = current { result.append(c) }
        return result
    }

    enum Op { case equal, delete, insert }

    /// Myers shortest edit script; nil if the edit distance exceeds `maxEditDistance`.
    static func myers(_ a: [Int], _ b: [Int]) -> [Op]? {
        let n = a.count, m = b.count
        if n == 0 { return Array(repeating: .insert, count: m) }
        if m == 0 { return Array(repeating: .delete, count: n) }
        let maxD = min(n + m, maxEditDistance)
        let offset = maxD + 1
        var v = [Int](repeating: 0, count: 2 * maxD + 3)
        // trace[d] holds v[k] for k in -(d-1)...(d-1) as it was before step d.
        var trace: [[Int]] = []
        var found = false
        outer: for d in 0...maxD {
            trace.append(d == 0 ? [] : Array(v[(offset - d + 1)...(offset + d - 1)]))
            var k = -d
            while k <= d {
                var x: Int
                if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
                    x = v[offset + k + 1]
                } else {
                    x = v[offset + k - 1] + 1
                }
                var y = x - k
                while x < n, y < m, a[x] == b[y] { x += 1; y += 1 }
                v[offset + k] = x
                if x >= n && y >= m { found = true; break outer }
                k += 2
            }
        }
        guard found else { return nil }
        // Backtrack.
        var ops: [Op] = []
        var x = n, y = m
        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            if d == 0 {
                while x > 0 && y > 0 { ops.append(.equal); x -= 1; y -= 1 }
                break
            }
            let snap = trace[d]
            func val(_ k: Int) -> Int { snap[k + d - 1] }
            let k = x - y
            let prevK = (k == -d || (k != d && val(k - 1) < val(k + 1))) ? k + 1 : k - 1
            let prevX = val(prevK)
            let prevY = prevX - prevK
            while x > prevX && y > prevY { ops.append(.equal); x -= 1; y -= 1 }
            ops.append(x == prevX ? .insert : .delete)
            x = prevX; y = prevY
        }
        return ops.reversed()
    }
}
