import Foundation

/// Implementation of `GoStructTags`: adds tag keys to every exported named field
/// of a struct and re-aligns the body the way gofmt does (tabwriter columns).
enum GoStructTagsEngine {
    static func apply(to source: String, line: Int, keys: [String], style: GoStructTagStyle) -> String? {
        let ns = source as NSString
        let all = GoScanner.tokenize(source)
        let lines = TextLines(nsString: ns)
        // Candidate struct bodies: `struct` `{` ... `}`, outermost one containing `line`.
        var target: (kw: Int, open: Int, close: Int)?
        var i = 0
        while i < all.count {
            let t = all[i]
            if t.kind == .keyword, t.text == "struct", i + 1 < all.count, all[i + 1].isOp("{"),
               let close = GoScanner.matchForward(all, i + 1) {
                let l0 = lines.line(forOffset: t.start)
                let l1 = lines.line(forOffset: all[close].start)
                if l0 <= line && line <= l1 {
                    target = (i, i + 1, close)
                    break
                }
                i = close + 1
                continue
            }
            i += 1
        }
        guard let tgt = target else { return nil }
        guard !keys.isEmpty else { return source }
        let ctx = Context(ns: ns, toks: all, lines: lines, keys: keys, style: style)
        let indent = ctx.lineIndent(of: all[tgt.kw].start)
        guard let body = ctx.rebuildBody(open: tgt.open, close: tgt.close, indent: indent) else { return nil }
        let range = NSRange(location: all[tgt.open].end, length: all[tgt.close].start - all[tgt.open].end)
        // `struct{` (one-line form) becomes `struct {` when expanded to lines.
        var result = ns.replacingCharacters(in: range, with: body)
        if all[tgt.kw].end == all[tgt.open].start, body.hasPrefix("\n") || body.hasPrefix(" //") {
            result = (result as NSString).replacingCharacters(in: NSRange(location: all[tgt.kw].end, length: 0), with: " ")
        }
        return result
    }

    // MARK: - Naming

    static func words(_ name: String) -> [String] {
        let c = Array(name)
        var out: [String] = []
        var cur = ""
        for i in 0..<c.count {
            let ch = c[i]
            if ch == "_" {
                if !cur.isEmpty { out.append(cur); cur = "" }
                continue
            }
            if !cur.isEmpty, let prev = cur.last {
                let next: Character? = i + 1 < c.count ? c[i + 1] : nil
                var boundary = false
                if ch.isUppercase && (prev.isLowercase || prev.isNumber) { boundary = true }
                if ch.isUppercase && prev.isUppercase, let n = next, n.isLowercase {
                    // `HTTPServer` → HTTP|Server, but `IDs` / `URLs` stay whole.
                    let plural = n == "s" && (i + 2 >= c.count || c[i + 2].isUppercase || c[i + 2] == "_")
                    boundary = !plural
                }
                if boundary { out.append(cur); cur = "" }
            }
            cur.append(ch)
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    static func tagName(_ field: String, style: GoStructTagStyle) -> String {
        let w = words(field).map { $0.lowercased() }
        switch style {
        case .snake: return w.joined(separator: "_")
        case .camel:
            guard let first = w.first else { return field }
            return first + w.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        }
    }

    /// Parses a struct tag body (`json:"a,omitempty" db:"x"`) into ordered pairs, or nil if malformed.
    static func parseTag(_ s: String) -> [(key: String, value: String)]? {
        let c = Array(s)
        var i = 0
        var out: [(String, String)] = []
        while i < c.count {
            while i < c.count, c[i] == " " { i += 1 }
            if i >= c.count { break }
            var key = ""
            while i < c.count, c[i] > " ", c[i] != ":", c[i] != "\"", c[i] != "\u{7f}" { key.append(c[i]); i += 1 }
            guard !key.isEmpty, i + 1 < c.count, c[i] == ":", c[i + 1] == "\"" else { return nil }
            i += 2
            var value = ""
            var closed = false
            while i < c.count {
                if c[i] == "\\", i + 1 < c.count { value.append(c[i]); value.append(c[i + 1]); i += 2; continue }
                if c[i] == "\"" { closed = true; i += 1; break }
                value.append(c[i]); i += 1
            }
            guard closed else { return nil }
            out.append((key, value))
        }
        return out
    }

    // MARK: - Rebuilding a struct body

    /// One output line of the body: tabwriter cells (all but the last are column-terminated)
    /// plus verbatim text that follows on later lines (multi-line fields).
    struct OutLine {
        var cells: [String]
        var tail: String = ""
        var breakAfter = false
    }

    struct Context {
        let ns: NSString
        let toks: [GoTok]
        let lines: TextLines
        let keys: [String]
        let style: GoStructTagStyle

        func text(_ a: Int, _ b: Int) -> String { ns.substring(with: NSRange(location: a, length: max(0, b - a))) }

        func lineIndent(of offset: Int) -> String {
            let r = lines.lineRange(lines.line(forOffset: offset))
            var s = ""
            var k = r.location
            while k < NSMaxRange(r) {
                let c = ns.character(at: k)
                guard c == 32 || c == 9 else { break }
                s.append(c == 9 ? "\t" : " ")
                k += 1
            }
            return s
        }

        /// New text between `{` (index `open`) and `}` (index `close`).
        func rebuildBody(open: Int, close: Int, indent: String) -> String? {
            // Split into statements at depth-0 newlines and semicolons.
            enum Item { case blank, comment(String), stmt([Int]) }
            var items: [Item] = []
            var headComment: String?
            var cur: [Int] = []
            var depth = 0
            var sawNewline = false
            var newlinesInRow = 0
            func flush() {
                if !cur.isEmpty {
                    if cur.allSatisfy({ toks[$0].kind == .comment }) {
                        let s = text(toks[cur[0]].start, toks[cur.last ?? cur[0]].end)
                        if !sawNewline && items.isEmpty { headComment = s } else { items.append(.comment(s)) }
                    } else {
                        items.append(.stmt(cur))
                    }
                }
                cur = []
            }
            var j = open + 1
            while j < close {
                let t = toks[j]
                if t.kind == .op {
                    if t.text == "(" || t.text == "[" || t.text == "{" { depth += 1 }
                    if t.text == ")" || t.text == "]" || t.text == "}" { depth -= 1 }
                }
                if depth == 0 && t.kind == .newline {
                    flush()
                    newlinesInRow += 1
                    if newlinesInRow == 2, !items.isEmpty { items.append(.blank) }
                    sawNewline = true
                    j += 1
                    continue
                }
                if depth == 0 && t.isOp(";") { flush(); j += 1; continue }
                newlinesInRow = t.kind == .newline ? newlinesInRow : 0
                cur.append(j)
                j += 1
            }
            flush()
            while case .blank? = items.last { items.removeLast() }

            var out: [OutLine] = []
            for item in items {
                switch item {
                case .blank: out.append(OutLine(cells: [""]))
                case .comment(let s): out.append(OutLine(cells: [s]))
                case .stmt(let idx): out += field(idx, indent: indent + "\t")
                }
            }
            if out.isEmpty && headComment == nil { return text(toks[open].end, toks[close].start) }
            let inner = indent + "\t"
            var s = headComment.map { " " + $0 } ?? ""
            s += "\n"
            s += align(out).map { $0.isEmpty ? "" : inner + $0 }.joined(separator: "\n")
            s += "\n" + indent
            return s
        }

        /// Output lines for one field statement (token indices).
        func field(_ idx: [Int], indent: String) -> [OutLine] {
            let code = idx.filter { toks[$0].isCode }
            guard let firstCode = code.first, let lastCode = code.last else { return [] }
            // Trailing comments only; a comment in the middle keeps the statement verbatim.
            let trailing = idx.filter { $0 > lastCode && toks[$0].kind == .comment }
            let middleComment = idx.contains { $0 > firstCode && $0 < lastCode && toks[$0].kind == .comment }
            let verbatim = OutLine(cells: [text(toks[firstCode].start, toks[idx.last ?? lastCode].end)])
            if middleComment { return [verbatim] }
            let comment = trailing.isEmpty ? nil : text(toks[trailing[0]].start, toks[trailing.last ?? trailing[0]].end)

            // Existing tag.
            var typeEnd = code.count            // exclusive index into `code`
            var tagTok: GoTok?
            let last = toks[lastCode]
            if code.count >= 2, last.kind == .rawString || last.kind == .string {
                tagTok = last
                typeEnd = code.count - 1
            }
            // Names.
            var names: [String] = []
            var typeStart = 0
            let c0 = toks[code[0]]
            if c0.kind == .ident, typeEnd >= 2 {
                let c1 = toks[code[1]]
                if c1.isOp(",") {
                    var k = 0
                    while k + 1 < typeEnd, toks[code[k]].kind == .ident {
                        names.append(toks[code[k]].text)
                        if toks[code[k + 1]].isOp(",") { k += 2 } else { k += 1; break }
                    }
                    typeStart = k
                } else if !(c1.isOp(".") || (c1.isOp("[") && c1.start == c0.end)) {
                    names = [c0.text]
                    typeStart = 1
                }
            }
            func cells(_ head: String?, _ type: String, _ tag: String?) -> [String] {
                var c: [String] = []
                if let h = head { c.append(h) }
                c.append(type)
                if let t = tag { c.append(t) }
                if let m = comment { c.append(m) }
                return c
            }
            guard typeStart < typeEnd else { return [verbatim] }
            let tyFirst = toks[code[typeStart]], tyLast = toks[code[typeEnd - 1]]
            let typeText = text(tyFirst.start, tyLast.end)
            let existingTag = tagTok?.text
            // Embedded field: leave as is (re-aligned).
            if names.isEmpty {
                let multi = typeText.contains("\n")
                if multi { return [verbatim] }
                return [OutLine(cells: cells(nil, typeText, existingTag))]
            }

            // Tag for one name.
            func tag(for name: String) -> String? {
                guard let first = name.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first) else { return existingTag }
                var pairs: [(key: String, value: String)] = []
                if let t = tagTok {
                    guard t.kind == .rawString, !t.unterminated, let p = GoStructTagsEngine.parseTag(String(t.text.dropFirst().dropLast())) else {
                        return existingTag
                    }
                    pairs = p
                }
                if pairs.contains(where: { $0.value == "-" }) { return existingTag }
                var changed = false
                for k in keys where !pairs.contains(where: { $0.key == k }) {
                    pairs.append((k, GoStructTagsEngine.tagName(name, style: style)))
                    changed = true
                }
                guard changed else { return existingTag }
                return "`" + pairs.map { "\($0.key):\"\($0.value)\"" }.joined(separator: " ") + "`"
            }

            // Multi-line type (nested struct or a type spanning lines).
            if typeText.contains("\n") {
                guard names.count == 1 else { return [verbatim] }
                let t = tag(for: names[0])
                var body = typeText
                if tyFirst.kind == .keyword, tyFirst.text == "struct", typeStart + 1 < typeEnd,
                   toks[code[typeStart + 1]].isOp("{"), GoScanner.matchForward(toks, code[typeStart + 1]) == code[typeEnd - 1],
                   let nested = rebuildBody(open: code[typeStart + 1], close: code[typeEnd - 1], indent: indent) {
                    body = "struct {" + nested + "}"
                }
                let nl = body.firstIndex(of: "\n") ?? body.endIndex
                var tail = String(body[nl...])
                if let t { tail += " " + t }
                if let m = comment { tail += " " + m }
                return [OutLine(cells: [names[0], String(body[..<nl])], tail: tail, breakAfter: true)]
            }

            let exported = names.filter { $0.unicodeScalars.first.map { CharacterSet.uppercaseLetters.contains($0) } ?? false }
            if names.count == 1 || exported.isEmpty {
                return [OutLine(cells: cells(names.joined(separator: ", "), typeText, names.count == 1 ? tag(for: names[0]) : existingTag))]
            }
            // `A, B int` → one line per name so each gets its own tag (vet rejects duplicate json names).
            return names.enumerated().map { i, n in
                var c = [n, typeText]
                if let t = tag(for: n) { c.append(t) }
                if i == names.count - 1, let m = comment { c.append(m) }
                return OutLine(cells: c)
            }
        }

        /// text/tabwriter-style alignment (padding 1, spaces), as gofmt prints struct fields.
        func align(_ input: [OutLine]) -> [String] {
            // Sections end after multi-line fields.
            var result: [String] = []
            var section: [OutLine] = []
            func emit() {
                var widths = Array(repeating: [Int](), count: section.count)
                for (i, l) in section.enumerated() { widths[i] = Array(repeating: 0, count: max(0, l.cells.count - 1)) }
                format(section, &widths, 0, section.count, 0)
                for (i, l) in section.enumerated() {
                    var s = ""
                    for (c, cell) in l.cells.enumerated() {
                        if c < l.cells.count - 1 {
                            s += cell + String(repeating: " ", count: max(1, widths[i][c] - cell.count))
                        } else {
                            s += cell
                        }
                    }
                    result.append(s + l.tail)
                }
                section = []
            }
            for l in input {
                section.append(l)
                if l.breakAfter { emit() }
            }
            emit()
            return result
        }

        private func format(_ ls: [OutLine], _ widths: inout [[Int]], _ line0: Int, _ line1: Int, _ column: Int) {
            var this = line0
            while this < line1 {
                if column >= ls[this].cells.count - 1 { this += 1; continue }
                let start = this
                var width = 0
                while this < line1, column < ls[this].cells.count - 1 {
                    width = max(width, ls[this].cells[column].count + 1)
                    this += 1
                }
                for k in start..<this { widths[k][column] = width }
                format(ls, &widths, start, this, column + 1)
            }
        }
    }
}
