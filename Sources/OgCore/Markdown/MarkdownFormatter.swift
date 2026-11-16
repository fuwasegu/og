import Foundation

/// og's Markdown formatter (⌘S). Conservative: it only changes layout that never changes the
/// rendered result. Code blocks and front matter are kept byte for byte.
///
/// - Tables: cells padded so the pipes line up (East Asian wide characters count as 2 columns).
/// - ATX headings: `##   Title  ` becomes `## Title`, with a blank line before and after.
/// - Trailing whitespace is removed, except a two-space hard line break.
/// - Runs of blank lines become one; no blank lines at the start; exactly one final newline.
public enum MarkdownFormatter {
    public static func format(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let crlf = text.contains("\r\n")
        var lines = text.components(separatedBy: "\n")
        if crlf { lines = lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 } }
        let kinds = classify(lines)

        var out: [String] = []
        var outKinds: [Kind] = []
        var i = 0
        while i < lines.count {
            let k = kinds[i]
            if k == .verbatim {
                out.append(lines[i]); outKinds.append(.verbatim); i += 1
                continue
            }
            if let end = tableEnd(lines, kinds, from: i) {
                for row in formatTable(Array(lines[i..<end])) { out.append(row); outKinds.append(.text) }
                i = end
                continue
            }
            let line = lines[i]
            if let h = heading(line) {
                out.append(h); outKinds.append(.heading)
            } else {
                let next = i + 1 < lines.count ? lines[i + 1] : ""
                let nextIsText = i + 1 < kinds.count && kinds[i + 1] == .text
                out.append(trimTrailing(line, keepHardBreak: !isBlank(next) && nextIsText))
                outKinds.append(isBlank(line) ? .blank : (k == .fence ? .fence : .text))
            }
            i += 1
        }
        return join(blankLines(out, outKinds), crlf: crlf)
    }

    /// Minimal whole-line replacements turning `old` into `new` (UTF-16 ranges in `old`).
    public static func edits(from old: String, to new: String) -> [(range: NSRange, text: String)] {
        let a = linesKeepingEnds(old), b = linesKeepingEnds(new)
        var starts = [0]
        for l in a { starts.append(starts[starts.count - 1] + (l as NSString).length) }
        return LineDiff.hunks(old: a, new: b).map { h in
            let r = NSRange(location: starts[h.oldStart], length: starts[h.oldStart + h.oldCount] - starts[h.oldStart])
            return (r, b[h.newStart..<(h.newStart + h.newCount)].joined())
        }
    }

    /// Where a caret at UTF-16 `caret` in `old` lands in `new`: the same line and column, clamped.
    public static func mapCaret(_ caret: Int, from old: String, to new: String) -> Int {
        let a = linesKeepingEnds(old), b = linesKeepingEnds(new)
        func starts(_ ls: [String]) -> [Int] {
            var s = [0]
            for l in ls { s.append(s[s.count - 1] + (l as NSString).length) }
            return s
        }
        let sa = starts(a), sb = starts(b)
        guard !a.isEmpty, !b.isEmpty else { return min(caret, sb.last ?? 0) }
        let line = max(0, (sa.lastIndex(where: { $0 <= caret }) ?? 0).clamped(to: a.count - 1))
        let col = caret - sa[line]
        func body(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        // The expected line shifts by the hunks above; nearby, prefer the line with the same content
        // (formatting changes only whitespace, so the caret's line keeps its trimmed text).
        var delta = 0
        for h in LineDiff.hunks(old: a, new: b) where h.oldStart + h.oldCount <= line { delta += h.newCount - h.oldCount }
        let expected = (line + delta).clamped(to: b.count - 1)
        let want = body(a[line])
        var target = expected
        if !want.isEmpty, body(b[expected]) != want {
            for d in 1...3 {
                if expected - d >= 0, body(b[expected - d]) == want { target = expected - d; break }
                if expected + d < b.count, body(b[expected + d]) == want { target = expected + d; break }
            }
        }
        let len = (b[target] as NSString).length - (b[target].hasSuffix("\n") ? 1 : 0)
        return sb[target] + min(col, max(0, len))
    }

    // MARK: - Line kinds

    enum Kind: Equatable { case text, blank, heading, fence, verbatim }

    /// Front matter and fenced code are verbatim (the fence lines themselves are `.fence`).
    static func classify(_ lines: [String]) -> [Kind] {
        var kinds = Array(repeating: Kind.text, count: lines.count)
        var i = 0
        if lines.first == "---", let close = lines.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." }) {
            for j in 0...close { kinds[j] = .verbatim }
            i = close + 1
        }
        var open: (char: Character, count: Int)?
        while i < lines.count {
            let f = fence(lines[i])
            if let o = open {
                if let f, f.char == o.char, f.count >= o.count, f.info.isEmpty {
                    kinds[i] = .fence
                    open = nil
                } else {
                    kinds[i] = .verbatim
                }
            } else if let f, !(f.char == "`" && f.info.contains("`")) {
                kinds[i] = .fence
                open = (f.char, f.count)
            } else if isBlank(lines[i]) {
                kinds[i] = .blank
            }
            i += 1
        }
        return kinds
    }

    /// A code fence line (up to 3 spaces of indentation inside its container is not tracked:
    /// any indentation counts, so fences in list items stay verbatim too).
    static func fence(_ line: String) -> (char: Character, count: Int, info: String)? {
        let t = line.drop(while: { $0 == " " || $0 == "\t" })
        guard let c = t.first, c == "`" || c == "~" else { return nil }
        let run = t.prefix(while: { $0 == c }).count
        guard run >= 3 else { return nil }
        return (c, run, t.dropFirst(run).trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Headings and whitespace

    /// Only unindented headings: an indented `#` line may belong to a list item.
    static func heading(_ line: String) -> String? {
        let t = Substring(line)
        let level = t.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let rest = t.dropFirst(level)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        let body = rest.trimmingCharacters(in: .whitespaces)
        return String(repeating: "#", count: level) + (body.isEmpty ? "" : " " + body)
    }

    static func isBlank(_ s: String) -> Bool { s.allSatisfy { $0 == " " || $0 == "\t" } }

    static func trimTrailing(_ line: String, keepHardBreak: Bool) -> String {
        if isBlank(line) { return "" }
        var end = line.endIndex
        while end > line.startIndex, line[line.index(before: end)] == " " || line[line.index(before: end)] == "\t" {
            end = line.index(before: end)
        }
        let trimmed = String(line[..<end])
        let spaces = line[end...].count
        return keepHardBreak && spaces >= 2 && !line[end...].contains("\t") ? trimmed + "  " : trimmed
    }

    /// One blank line around headings and between blocks; never inside verbatim regions.
    static func blankLines(_ lines: [String], _ kinds: [Kind]) -> [String] {
        var out: [String] = []
        var outKinds: [Kind] = []
        func pushBlank() {
            guard let last = outKinds.last, last != .blank else { return }
            out.append(""); outKinds.append(.blank)
        }
        for (line, k) in zip(lines, kinds) {
            switch k {
            case .blank:
                // Blank lines inside indented code keep the code intact.
                if let prev = out.last(where: { !$0.isEmpty }), prev.hasPrefix("    ") || prev.hasPrefix("\t") {
                    out.append(""); outKinds.append(.blank)
                } else {
                    pushBlank()
                }
            case .heading:
                pushBlank()
                out.append(line); outKinds.append(.heading)
            default:
                if outKinds.last == .heading { pushBlank() }
                out.append(line); outKinds.append(k)
            }
        }
        // Collapse the runs left by indented-code lines whose next line is not code.
        var result: [String] = []
        var resultKinds: [Kind] = []
        for (idx, line) in out.enumerated() {
            if outKinds[idx] == .blank, resultKinds.last == .blank {
                let nextCode = out[(idx + 1)...].first(where: { !$0.isEmpty }).map { $0.hasPrefix("    ") || $0.hasPrefix("\t") } ?? false
                if !nextCode { continue }
            }
            result.append(line); resultKinds.append(outKinds[idx])
        }
        while resultKinds.last == .blank { result.removeLast(); resultKinds.removeLast() }
        return result
    }

    static func join(_ lines: [String], crlf: Bool) -> String {
        guard !lines.isEmpty else { return "" }
        let nl = crlf ? "\r\n" : "\n"
        return lines.joined(separator: nl) + nl
    }

    static func linesKeepingEnds(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        for c in s {
            cur.append(c)
            if c == "\n" || c == "\r\n" { out.append(cur); cur = "" }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    // MARK: - Tables

    /// The end (exclusive) of a GitHub table starting at `start`: a header row, a delimiter row with
    /// the same number of cells, then rows up to a blank line or a line without `|`.
    static func tableEnd(_ lines: [String], _ kinds: [Kind], from start: Int) -> Int? {
        guard start + 1 < lines.count, kinds[start] == .text, kinds[start + 1] == .text,
              lines[start].contains("|"), let aligns = delimiterRow(lines[start + 1]),
              cells(lines[start]).count == aligns.count else { return nil }
        var end = start + 2
        while end < lines.count, kinds[end] == .text, !isBlank(lines[end]), lines[end].contains("|") { end += 1 }
        return end
    }

    enum Align { case none, left, center, right }

    static func delimiterRow(_ line: String) -> [Align]? {
        let cs = cells(line)
        guard !cs.isEmpty else { return nil }
        var out: [Align] = []
        for c in cs {
            guard !c.isEmpty, c.allSatisfy({ $0 == "-" || $0 == ":" }), c.contains("-"),
                  !c.dropFirst().dropLast().contains(":") else { return nil }
            let l = c.hasPrefix(":"), r = c.hasSuffix(":")
            out.append(l && r ? .center : l ? .left : r ? .right : .none)
        }
        return out
    }

    /// Cells of a table row, trimmed. Pipes inside code spans or escaped as `\|` do not split.
    static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|"), !t.hasSuffix("\\|") { t.removeLast() }
        var out: [String] = []
        var cur = ""
        var inCode = 0
        var escaped = false
        var i = t.startIndex
        while i < t.endIndex {
            let c = t[i]
            if escaped {
                cur.append(c); escaped = false
            } else if c == "\\" {
                cur.append(c); escaped = true
            } else if c == "`" {
                let run = t[i...].prefix(while: { $0 == "`" }).count
                if inCode == 0 { inCode = run } else if inCode == run { inCode = 0 }
                cur += String(repeating: "`", count: run)
                i = t.index(i, offsetBy: run)
                continue
            } else if c == "|", inCode == 0 {
                out.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""
            } else {
                cur.append(c)
            }
            i = t.index(after: i)
        }
        out.append(cur.trimmingCharacters(in: .whitespaces))
        return out
    }

    static func formatTable(_ rows: [String]) -> [String] {
        let indent = String(rows[0].prefix(while: { $0 == " " || $0 == "\t" }))
        guard let aligns = delimiterRow(rows[1]) else { return rows }
        let body = [cells(rows[0])] + rows.dropFirst(2).map(cells)
        let columns = max(aligns.count, body.map(\.count).max() ?? 0)
        let grid = body.map { $0 + Array(repeating: "", count: columns - $0.count) }
        let aligned = aligns + Array(repeating: Align.none, count: columns - aligns.count)
        let widths = (0..<columns).map { c in max(3, grid.map { displayWidth($0[c]) }.max() ?? 0) }

        func pad(_ s: String, _ w: Int, _ a: Align) -> String {
            let gap = w - displayWidth(s)
            switch a {
            case .right: return String(repeating: " ", count: gap) + s
            case .center:
                let l = gap / 2
                return String(repeating: " ", count: l) + s + String(repeating: " ", count: gap - l)
            default: return s + String(repeating: " ", count: gap)
            }
        }
        func row(_ cs: [String]) -> String {
            indent + "| " + (0..<columns).map { pad(cs[$0], widths[$0], aligned[$0]) }.joined(separator: " | ") + " |"
        }
        let delim = indent + "| " + (0..<columns).map { c -> String in
            let w = widths[c]
            switch aligned[c] {
            case .none: return String(repeating: "-", count: w)
            case .left: return ":" + String(repeating: "-", count: w - 1)
            case .right: return String(repeating: "-", count: w - 1) + ":"
            case .center: return ":" + String(repeating: "-", count: w - 2) + ":"
            }
        }.joined(separator: " | ") + " |"
        return [row(grid[0]), delim] + grid.dropFirst().map(row)
    }

    /// Terminal-style column width: East Asian wide and fullwidth characters and emoji count 2.
    static func displayWidth(_ s: String) -> Int {
        s.reduce(0) { sum, ch in
            let scalars = ch.unicodeScalars
            guard let first = scalars.first else { return sum }
            if scalars.contains(where: { $0.value == 0xFE0F }) { return sum + 2 }
            return sum + width(first.value)
        }
    }

    static func width(_ v: UInt32) -> Int {
        switch v {
        case 0x0300...0x036F, 0x200B...0x200F, 0xFE00...0xFE0F: return 0
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
             0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x1FA70...0x1FAFF, 0x20000...0x3FFFD:
            return 2
        default: return 1
        }
    }
}

private extension Int {
    func clamped(to upper: Int) -> Int { Swift.max(0, Swift.min(self, upper)) }
}
