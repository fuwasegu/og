import Foundation

/// A string prepared for repeated fuzzy matching (UTF-16 units, case-folded copy,
/// per-position bonuses). Build once per path, reuse for every query.
public struct FuzzyCandidate: Sendable {
    public let text: String
    let chars: [UInt16]
    let folded: [UInt16]
    let bonus: [Int32]
    /// UTF-16 offset where the last path component starts.
    public let nameStart: Int

    public init(_ text: String, pathAware: Bool = true) {
        self.text = text
        let chars = Array(text.utf16)
        self.chars = chars
        self.folded = chars.map(FuzzyMatcher.fold)
        var nameStart = 0
        if pathAware, let slash = chars.lastIndex(of: 0x2F) { nameStart = slash + 1 }
        self.nameStart = nameStart
        var bonus = [Int32](repeating: 0, count: chars.count)
        for j in 0..<chars.count {
            var b = FuzzyMatcher.boundaryBonus(prev: j > 0 ? chars[j - 1] : 0x2F, cur: chars[j])
            if pathAware && j >= nameStart { b += FuzzyMatcher.bonusFileName }
            bonus[j] = b
        }
        self.bonus = bonus
    }
}

public struct FuzzyQuery: Sendable, Hashable {
    let units: [UInt16]
    public let caseSensitive: Bool
    public let normalized: String

    /// Smart case: case-insensitive unless the query has an uppercase letter. Spaces are ignored.
    public init(_ query: String) {
        let stripped = query.filter { !$0.isWhitespace }
        normalized = stripped
        caseSensitive = stripped.contains { $0.isUppercase }
        let raw = Array(stripped.utf16)
        units = caseSensitive ? raw : raw.map(FuzzyMatcher.fold)
    }

    public var isEmpty: Bool { units.isEmpty }
}

/// fzf-style (v2, Smith-Waterman-like) scorer: rewards consecutive runs, word / camelCase /
/// `/` `_` `.` boundaries, and matches inside the file name; penalizes gaps.
/// Not thread-safe (reuses scratch buffers); use one per thread.
public struct FuzzyMatcher {
    static let scoreMatch: Int32 = 16
    static let gapStart: Int32 = 3
    static let gapExtension: Int32 = 1
    static let bonusSlash: Int32 = 10
    static let bonusBoundary: Int32 = 8
    static let bonusCamel: Int32 = 7
    static let bonusNumber: Int32 = 3
    static let bonusConsecutive: Int32 = 5
    static let bonusFileName: Int32 = 5
    static let firstCharMultiplier: Int32 = 2
    static let minusInf: Int32 = -1_000_000

    private var hPrev: [Int32] = []
    private var hCur: [Int32] = []
    private var rPrev: [Int32] = []   // bonus at the start of the current consecutive run
    private var rCur: [Int32] = []
    private var lo: [Int] = []

    public init() {}

    @inline(__always)
    static func fold(_ c: UInt16) -> UInt16 {
        if c >= 0x41 && c <= 0x5A { return c + 32 }
        if c < 0x80 { return c }
        guard let s = Unicode.Scalar(c) else { return c }
        let lower = s.properties.lowercaseMapping.utf16
        return lower.count == 1 ? lower[lower.startIndex] : c
    }

    @inline(__always)
    static func isLower(_ c: UInt16) -> Bool { c >= 0x61 && c <= 0x7A }
    @inline(__always)
    static func isUpper(_ c: UInt16) -> Bool { c >= 0x41 && c <= 0x5A }
    @inline(__always)
    static func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }
    @inline(__always)
    static func isAlnum(_ c: UInt16) -> Bool { isLower(c) || isUpper(c) || isDigit(c) || c >= 0x80 }

    static func boundaryBonus(prev: UInt16, cur: UInt16) -> Int32 {
        guard isAlnum(cur) else { return 0 }
        if prev == 0x2F || prev == 0x5C { return bonusSlash }                 // / \
        if !isAlnum(prev) { return bonusBoundary }                             // _ - . space ...
        if isLower(prev) && isUpper(cur) { return bonusCamel }                 // fooBar
        if !isDigit(prev) && isDigit(cur) { return bonusNumber }               // file2
        return 0
    }

    /// Score only (nil = no match).
    public mutating func score(_ query: FuzzyQuery, _ cand: FuzzyCandidate) -> Int? {
        run(query, cand, trace: false)?.score
    }

    /// Score plus the matched UTF-16 offsets.
    public mutating func match(_ query: FuzzyQuery, _ cand: FuzzyCandidate) -> (score: Int, offsets: [Int])? {
        run(query, cand, trace: true)
    }

    /// Convenience for one-off matching of arbitrary strings (symbol names, recent files).
    public static func match(_ query: String, in text: String, pathAware: Bool = true) -> (score: Int, offsets: [Int])? {
        var m = FuzzyMatcher()
        return m.match(FuzzyQuery(query), FuzzyCandidate(text, pathAware: pathAware))
    }

    private mutating func run(_ query: FuzzyQuery, _ cand: FuzzyCandidate, trace: Bool) -> (score: Int, offsets: [Int])? {
        let q = query.units
        let m = q.count
        let n = cand.chars.count
        if m == 0 { return (0, []) }
        if m > n { return nil }
        let text = query.caseSensitive ? cand.chars : cand.folded

        // Forward greedy pass: earliest position of each query char (also the subsequence test).
        if lo.count < m { lo = [Int](repeating: 0, count: m) }
        var j = 0
        for i in 0..<m {
            let c = q[i]
            while j < n && text[j] != c { j += 1 }
            if j == n { return nil }
            lo[i] = j
            j += 1
        }
        // Backward greedy pass: latest possible end position.
        var hi = n - 1
        do {
            var i = m - 1
            var k = n - 1
            while i >= 0 {
                while text[k] != q[i] { k -= 1 }
                if i == m - 1 { hi = k }
                i -= 1; k -= 1
            }
        }

        if hPrev.count < n {
            hPrev = [Int32](repeating: Self.minusInf, count: n)
            hCur = hPrev; rPrev = hPrev; rCur = hPrev
        }
        var full: [Int32] = trace ? [Int32](repeating: Self.minusInf, count: m * n) : []
        var diagFlags: [Bool] = trace ? [Bool](repeating: false, count: m * n) : []
        let bonus = cand.bonus
        let tailFree = n - 1 - hi  // columns after `hi` can never end the match

        for i in 0..<m {
            let c = q[i]
            let start = lo[i]
            let end = n - 1 - (m - 1 - i) - tailFree  // inclusive
            var gapBest = Self.minusInf
            // Reset the slice we write this row.
            if start > 0 { hCur[start - 1] = Self.minusInf }
            // Start early enough that the gap accumulator sees every cell of the previous row.
            var jj = i > 0 ? min(start, lo[i - 1] + 2) : start
            while jj <= end {
                if i > 0 && jj >= 2 {
                    let prev = hPrev[jj - 2]
                    gapBest = max(gapBest &- Self.gapExtension, prev &- Self.gapStart)
                }
                if jj < start { jj += 1; continue }
                var h = Self.minusInf
                var r: Int32 = 0
                var fromDiag = false
                if text[jj] == c {
                    let b = bonus[jj]
                    if i == 0 {
                        h = Self.scoreMatch + b * Self.firstCharMultiplier
                        r = b
                    } else {
                        if jj >= 1 && hPrev[jj - 1] > Self.minusInf / 2 {
                            let runBonus = rPrev[jj - 1]
                            let cb = max(b, runBonus, Self.bonusConsecutive)
                            h = hPrev[jj - 1] + Self.scoreMatch + cb
                            r = max(runBonus, b)
                            fromDiag = true
                        }
                        if gapBest > Self.minusInf / 2 {
                            let g = gapBest + Self.scoreMatch + b
                            if g > h { h = g; r = b; fromDiag = false }
                        }
                    }
                }
                hCur[jj] = h
                rCur[jj] = r
                if trace { full[i * n + jj] = h; diagFlags[i * n + jj] = fromDiag }
                jj += 1
            }
            // Row i+1 reads hPrev[j-1] and hPrev[j-2] for j in [lo[i+1], end+1] with
            // lo[i+1] > lo[i], i.e. indices [lo[i]-1, end]; all are written above.
            swap(&hPrev, &hCur)
            swap(&rPrev, &rCur)
        }

        // Best end in the last row.
        var best = Self.minusInf
        var bestJ = -1
        let lastStart = lo[m - 1]
        let lastEnd = n - 1 - tailFree
        if lastStart <= lastEnd {
            for jj in lastStart...lastEnd where hPrev[jj] > best { best = hPrev[jj]; bestJ = jj }
        }
        guard bestJ >= 0, best > Self.minusInf / 2 else { return nil }
        guard trace else { return (Int(best), []) }

        // Backtrack.
        var offsets = [Int](repeating: 0, count: m)
        var col = bestJ
        var i = m - 1
        while i >= 0 {
            offsets[i] = col
            if i == 0 { break }
            if diagFlags[i * n + col] {
                col -= 1
            } else {
                var bestK = -1
                var bestV = Self.minusInf
                var k = col - 2
                while k >= 0 {
                    let v = full[(i - 1) * n + k]
                    if v > Self.minusInf / 2 {
                        let pen = Self.gapStart + Self.gapExtension * Int32(col - 2 - k)
                        if v - pen > bestV { bestV = v - pen; bestK = k }
                    }
                    k -= 1
                }
                if bestK < 0 { return (Int(best), offsets) }
                col = bestK
            }
            i -= 1
        }
        return (Int(best), offsets)
    }
}
