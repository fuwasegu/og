import Foundation

/// A Markdown document as blocks, for og's native preview (CommonMark + GitHub tables, task lists,
/// strikethrough and autolinks; raw HTML is shown as text). Parsing is linear and allocation-light so
/// the preview can follow every keystroke.
public enum MarkdownBlock: Sendable, Hashable {
    case heading(level: Int, text: [MarkdownInline], line: Int)
    case paragraph([MarkdownInline], line: Int)
    /// Fenced or indented code. `language` is the info string's first word, lowercased.
    case code(language: String, text: String, line: Int)
    case list(ordered: Bool, start: Int, items: [MarkdownListItem], line: Int)
    case quote([MarkdownBlock], line: Int)
    case table(header: [[MarkdownInline]], alignments: [MarkdownAlignment], rows: [[[MarkdownInline]]], line: Int)
    case rule(line: Int)
    case html(String, line: Int)

    /// The block with every source line set to 0: equal for the same content anywhere in the file
    /// (the preview reuses its layout when lines above it were added or removed).
    public var content: MarkdownBlock {
        switch self {
        case .heading(let l, let t, _): return .heading(level: l, text: t, line: 0)
        case .paragraph(let t, _): return .paragraph(t, line: 0)
        case .code(let lang, let t, _): return .code(language: lang, text: t, line: 0)
        case .list(let o, let s, let items, _):
            return .list(ordered: o, start: s, items: items.map { MarkdownListItem(checked: $0.checked, blocks: $0.blocks.map(\.content)) }, line: 0)
        case .quote(let b, _): return .quote(b.map(\.content), line: 0)
        case .table(let h, let a, let r, _): return .table(header: h, alignments: a, rows: r, line: 0)
        case .rule: return .rule(line: 0)
        case .html(let s, _): return .html(s, line: 0)
        }
    }

    /// 0-based source line where the block starts.
    public var line: Int {
        switch self {
        case .heading(_, _, let l), .paragraph(_, let l), .code(_, _, let l), .list(_, _, _, let l),
             .quote(_, let l), .table(_, _, _, let l), .rule(let l), .html(_, let l):
            return l
        }
    }
}

public struct MarkdownListItem: Sendable, Hashable {
    /// nil: plain item; true / false: a `- [x]` / `- [ ]` task.
    public var checked: Bool?
    public var blocks: [MarkdownBlock]
}

public enum MarkdownAlignment: Sendable, Hashable { case none, left, center, right }

public indirect enum MarkdownInline: Sendable, Hashable {
    case text(String)
    case code(String)
    case emphasis([MarkdownInline])
    case strong([MarkdownInline])
    case strike([MarkdownInline])
    case link(text: [MarkdownInline], url: String)
    case image(alt: String, url: String)
    case lineBreak

    /// The visible text, without markup.
    public var plainText: String {
        switch self {
        case .text(let s), .code(let s): return s
        case .emphasis(let c), .strong(let c), .strike(let c), .link(let c, _): return c.map(\.plainText).joined()
        case .image(let alt, _): return alt
        case .lineBreak: return "\n"
        }
    }
}

public enum Markdown {
    public static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var p = BlockParser(lines: lines.map { Substring($0) }, base: 0)
        return p.parse()
    }

    public static func parseInline(_ text: String) -> [MarkdownInline] {
        var p = InlineParser(text)
        return p.parse()
    }
}

// MARK: - Blocks

private struct BlockParser {
    let lines: [Substring]
    /// Line number of `lines[0]` in the whole document.
    let base: Int
    var i = 0

    init(lines: [Substring], base: Int) {
        self.lines = lines
        self.base = base
    }

    mutating func parse() -> [MarkdownBlock] {
        var out: [MarkdownBlock] = []
        while i < lines.count {
            let line = lines[i]
            if isBlank(line) { i += 1; continue }
            if let b = fence() ?? heading(line) ?? rule(line) ?? quote() ?? list() ?? table() ?? indentedCode() ?? html() {
                out.append(b)
            } else {
                out.append(paragraph())
            }
        }
        return out
    }

    // MARK: Leaf blocks

    private mutating func heading(_ line: Substring) -> MarkdownBlock? {
        let t = line.drop { $0 == " " }
        guard line.count - t.count < 4, t.first == "#" else { return nil }
        let level = t.prefix { $0 == "#" }.count
        guard level <= 6 else { return nil }
        let rest = t.dropFirst(level)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var content = rest.trimmingCharacters(in: .whitespaces)
        // Closing #s.
        if let r = content.range(of: #"\s+#+$"#, options: .regularExpression) { content.removeSubrange(r) }
        else if content.allSatisfy({ $0 == "#" }) { content = "" }
        let at = i
        i += 1
        return .heading(level: level, text: Markdown.parseInline(content), line: base + at)
    }

    private mutating func rule(_ line: Substring) -> MarkdownBlock? {
        guard isRule(line) else { return nil }
        let at = i
        i += 1
        return .rule(line: base + at)
    }

    private mutating func fence() -> MarkdownBlock? {
        let line = lines[i]
        let indent = line.prefix { $0 == " " }.count
        guard indent < 4 else { return nil }
        let t = line.dropFirst(indent)
        guard let ch = t.first, ch == "`" || ch == "~" else { return nil }
        let n = t.prefix { $0 == ch }.count
        guard n >= 3 else { return nil }
        let info = t.dropFirst(n).trimmingCharacters(in: .whitespaces)
        if ch == "`" && info.contains("`") { return nil }
        let lang = String(info.split(separator: " ").first ?? "").lowercased()
        let at = i
        i += 1
        var body: [Substring] = []
        while i < lines.count {
            let l = lines[i]
            let li = l.prefix { $0 == " " }.count
            let lt = l.dropFirst(li)
            if li < 4, lt.prefix(while: { $0 == ch }).count >= n, lt.drop(while: { $0 == ch }).allSatisfy({ $0 == " " || $0 == "\t" }) {
                i += 1
                break
            }
            // Content lines lose up to the fence's indentation.
            var c = l
            var k = 0
            while k < indent, c.first == " " { c = c.dropFirst(); k += 1 }
            body.append(c)
            i += 1
        }
        return .code(language: lang, text: body.joined(separator: "\n"), line: base + at)
    }

    private mutating func indentedCode() -> MarkdownBlock? {
        guard indentWidth(lines[i]) >= 4 else { return nil }
        let at = i
        var body: [Substring] = []
        while i < lines.count, isBlank(lines[i]) || indentWidth(lines[i]) >= 4 {
            body.append(stripIndent(lines[i], 4))
            i += 1
        }
        while let last = body.last, isBlank(last) { body.removeLast() }
        return .code(language: "", text: body.joined(separator: "\n"), line: base + at)
    }

    private mutating func html() -> MarkdownBlock? {
        let t = lines[i].drop { $0 == " " }
        guard t.hasPrefix("<"), let c = t.dropFirst().first, c.isLetter || c == "/" || c == "!" else { return nil }
        let at = i
        var body: [Substring] = []
        while i < lines.count, !isBlank(lines[i]) {
            body.append(lines[i])
            i += 1
        }
        return .html(body.joined(separator: "\n"), line: base + at)
    }

    private mutating func paragraph() -> MarkdownBlock {
        let at = i
        var body: [String] = []
        while i < lines.count {
            let l = lines[i]
            if isBlank(l) { break }
            if !body.isEmpty {
                // Setext heading underline.
                let u = l.trimmingCharacters(in: .whitespaces)
                if indentWidth(l) < 4, !u.isEmpty, u.allSatisfy({ $0 == "=" }) || (u.allSatisfy({ $0 == "-" })) {
                    i += 1
                    return .heading(level: u.first == "=" ? 1 : 2, text: inlines(body), line: base + at)
                }
                if interrupts(l) { break }
            }
            body.append(String(l))
            i += 1
        }
        return .paragraph(inlines(body), line: base + at)
    }

    /// Paragraph lines join with a space; two trailing spaces or a backslash make a hard break.
    private func inlines(_ body: [String]) -> [MarkdownInline] {
        var text = ""
        for (k, raw) in body.enumerated() {
            var l = Substring(raw.drop { $0 == " " })
            var hard = false
            if l.hasSuffix("  ") { hard = true }
            while l.last == " " { l = l.dropLast() }
            if l.hasSuffix("\\") { hard = true; l = l.dropLast() }
            text += l
            if k < body.count - 1 { text += hard ? "\u{2028}" : "\n" }
        }
        return Markdown.parseInline(text)
    }

    // MARK: Container blocks

    private mutating func quote() -> MarkdownBlock? {
        guard quoteContent(lines[i]) != nil else { return nil }
        let at = i
        var inner: [Substring] = []
        while i < lines.count {
            if let c = quoteContent(lines[i]) {
                inner.append(c)
            } else if !isBlank(lines[i]), let last = inner.last, !isBlank(last), !interrupts(lines[i]) {
                inner.append(lines[i])  // lazy continuation
            } else {
                break
            }
            i += 1
        }
        var sub = BlockParser(lines: inner, base: base + at)
        return .quote(sub.parse(), line: base + at)
    }

    private func quoteContent(_ l: Substring) -> Substring? {
        let t = l.drop { $0 == " " }
        guard l.count - t.count < 4, t.first == ">" else { return nil }
        var c = t.dropFirst()
        if c.first == " " { c = c.dropFirst() }
        return c
    }

    private struct Marker {
        var ordered: Bool
        var number: Int
        var delimiter: Character
        /// Columns before the item's content.
        var contentIndent: Int
        var content: Substring
    }

    private func marker(_ l: Substring) -> Marker? {
        let indent = l.prefix { $0 == " " }.count
        guard indent < 4 else { return nil }
        let t = l.dropFirst(indent)
        guard let c = t.first else { return nil }
        if c == "-" || c == "*" || c == "+" {
            let rest = t.dropFirst()
            guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
            if isRule(l) { return nil }
            let pad = min(max(rest.prefix { $0 == " " }.count, 1), 4)
            return Marker(ordered: false, number: 0, delimiter: c, contentIndent: indent + 1 + (rest.isEmpty ? 1 : pad),
                          content: rest.isEmpty ? rest : rest.dropFirst(pad))
        }
        let digits = t.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let after = t.dropFirst(digits.count)
        guard let d = after.first, d == "." || d == ")" else { return nil }
        let rest = after.dropFirst()
        guard rest.isEmpty || rest.first == " " else { return nil }
        let pad = min(max(rest.prefix { $0 == " " }.count, 1), 4)
        return Marker(ordered: true, number: Int(digits) ?? 1, delimiter: d, contentIndent: indent + digits.count + 1 + (rest.isEmpty ? 1 : pad),
                      content: rest.isEmpty ? rest : rest.dropFirst(pad))
    }

    private mutating func list() -> MarkdownBlock? {
        guard let first = marker(lines[i]) else { return nil }
        let at = i
        var items: [MarkdownListItem] = []
        while i < lines.count, let m = marker(lines[i]), m.ordered == first.ordered, m.delimiter == first.delimiter {
            let itemLine = i
            var body: [Substring] = [m.content]
            i += 1
            var sawBlank = false
            while i < lines.count {
                let l = lines[i]
                if isBlank(l) {
                    sawBlank = true
                    body.append("")
                    i += 1
                    continue
                }
                if indentWidth(l) >= m.contentIndent {
                    body.append(stripIndent(l, m.contentIndent))
                    sawBlank = false
                    i += 1
                } else if !sawBlank, marker(l) == nil, !interrupts(l) {
                    body.append(l)  // lazy continuation of the item's paragraph
                    i += 1
                } else {
                    break
                }
            }
            while let last = body.last, isBlank(last) { body.removeLast() }
            // Task list: `[ ]` / `[x]` at the start of the item.
            var checked: Bool?
            if let head = body.first {
                let h = head.lowercased()
                if h.hasPrefix("[ ] ") || h == "[ ]" { checked = false; body[0] = head.dropFirst(min(4, head.count)) }
                else if h.hasPrefix("[x] ") || h == "[x]" { checked = true; body[0] = head.dropFirst(min(4, head.count)) }
            }
            var sub = BlockParser(lines: body, base: base + itemLine)
            items.append(MarkdownListItem(checked: checked, blocks: sub.parse()))
            // A blank line followed by something that is not an item ends the list.
            var j = i
            while j < lines.count, isBlank(lines[j]) { j += 1 }
            if j < lines.count, let next = marker(lines[j]), next.ordered == first.ordered, next.delimiter == first.delimiter { i = j } else { break }
        }
        return .list(ordered: first.ordered, start: first.number, items: items, line: base + at)
    }

    private mutating func table() -> MarkdownBlock? {
        guard i + 1 < lines.count, lines[i].contains("|"),
              let aligns = delimiterRow(lines[i + 1]) else { return nil }
        let header = cells(lines[i])
        guard header.count == aligns.count else { return nil }
        let at = i
        i += 2
        var rows: [[[MarkdownInline]]] = []
        while i < lines.count, !isBlank(lines[i]), lines[i].contains("|") || !interrupts(lines[i]) {
            var r = cells(lines[i])
            if r.count < aligns.count { r += Array(repeating: "", count: aligns.count - r.count) }
            rows.append(r.prefix(aligns.count).map { Markdown.parseInline($0) })
            i += 1
        }
        return .table(header: header.map { Markdown.parseInline($0) }, alignments: aligns, rows: rows, line: base + at)
    }

    private func delimiterRow(_ l: Substring) -> [MarkdownAlignment]? {
        let parts = cells(l)
        guard !parts.isEmpty else { return nil }
        var out: [MarkdownAlignment] = []
        for p in parts {
            let s = p.trimmingCharacters(in: .whitespaces)
            let core = s.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !core.isEmpty, core.allSatisfy({ $0 == "-" }) else { return nil }
            let l = s.hasPrefix(":"), r = s.hasSuffix(":")
            out.append(l && r ? .center : r ? .right : l ? .left : .none)
        }
        return out
    }

    /// Cells of a table row; `\|` is a literal pipe.
    private func cells(_ l: Substring) -> [String] {
        var s = l.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") && !s.hasSuffix("\\|") { s.removeLast() }
        var out: [String] = []
        var cur = ""
        var escaped = false
        var inCode = false
        for ch in s {
            if escaped { cur.append(ch == "|" ? "|" : "\\"); if ch != "|" { cur.append(ch) }; escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "`" { inCode.toggle() }
            if ch == "|" && !inCode { out.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""; continue }
            cur.append(ch)
        }
        if escaped { cur.append("\\") }
        out.append(cur.trimmingCharacters(in: .whitespaces))
        return out
    }

    // MARK: Helpers

    /// A line that starts a new block even inside a paragraph.
    private func interrupts(_ l: Substring) -> Bool {
        let t = l.drop { $0 == " " }
        guard l.count - t.count < 4 else { return false }
        if t.hasPrefix("#") || t.hasPrefix(">") || t.hasPrefix("```") || t.hasPrefix("~~~") || isRule(l) { return true }
        if let m = marker(l), !m.content.isEmpty, !m.ordered || m.number == 1 { return true }
        return false
    }

    private func isRule(_ l: Substring) -> Bool {
        let t = l.filter { $0 != " " && $0 != "\t" }
        guard t.count >= 3, let c = t.first, c == "-" || c == "*" || c == "_" else { return false }
        return l.prefix { $0 == " " }.count < 4 && t.allSatisfy { $0 == c }
    }

    private func isBlank(_ l: Substring) -> Bool { l.allSatisfy { $0 == " " || $0 == "\t" } }

    private func indentWidth(_ l: Substring) -> Int {
        var w = 0
        for c in l {
            if c == " " { w += 1 } else if c == "\t" { w += 4 - w % 4 } else { break }
        }
        return w
    }

    private func stripIndent(_ l: Substring, _ n: Int) -> Substring {
        var w = 0
        var s = l
        while w < n, let c = s.first, c == " " || c == "\t" {
            w += c == "\t" ? 4 - w % 4 : 1
            s = s.dropFirst()
        }
        return s
    }
}

// MARK: - Inlines

private struct InlineParser {
    let chars: [Character]
    var i = 0

    init(_ text: String) { chars = Array(text) }

    mutating func parse() -> [MarkdownInline] { parse(until: nil) }

    /// Parses until `close` (consumed) or the end. Returns nil when `close` never appears.
    private mutating func parse(until close: String?) -> [MarkdownInline] {
        var out: [MarkdownInline] = []
        var text = ""
        func flush() { if !text.isEmpty { out.append(.text(text)); text = "" } }
        while i < chars.count {
            if let close, matches(close) { flush(); return out }
            let c = chars[i]
            switch c {
            case "\\" where i + 1 < chars.count && chars[i + 1].isPunctuation || i + 1 < chars.count && chars[i + 1].isSymbol:
                text.append(chars[i + 1]); i += 2
            case "\u{2028}":
                flush(); out.append(.lineBreak); i += 1
            case "\n":
                text.append(" "); i += 1
            case "`":
                if let code = codeSpan() { flush(); out.append(.code(code)) } else { text.append(c); i += 1 }
            case "*", "_", "~":
                if let node = delimited(c) { flush(); out.append(node) } else { text.append(c); i += 1 }
            case "!" where i + 1 < chars.count && chars[i + 1] == "[":
                if let img = image() { flush(); out.append(img) } else { text.append(c); i += 1 }
            case "[":
                if let link = link() { flush(); out.append(link) } else { text.append(c); i += 1 }
            case "<":
                if let auto = autolink() { flush(); out.append(auto) } else { text.append(c); i += 1 }
            case "h" where matches("https://") || matches("http://"):
                if wordBoundaryBefore(), let url = bareURL() { flush(); out.append(.link(text: [.text(url)], url: url)) } else { text.append(c); i += 1 }
            default:
                text.append(c); i += 1
            }
        }
        flush()
        return out
    }

    private func matches(_ s: String) -> Bool {
        var k = i
        for ch in s {
            guard k < chars.count, chars[k] == ch else { return false }
            k += 1
        }
        return true
    }

    private func wordBoundaryBefore() -> Bool {
        i == 0 || !(chars[i - 1].isLetter || chars[i - 1].isNumber)
    }

    private mutating func codeSpan() -> String? {
        let n = run(of: "`", at: i)
        var k = i + n
        while k < chars.count {
            if chars[k] == "`" {
                let m = run(of: "`", at: k)
                if m == n {
                    var s = String(chars[(i + n)..<k]).replacingOccurrences(of: "\n", with: " ")
                    if s.count >= 2, s.first == " ", s.last == " ", !s.allSatisfy({ $0 == " " }) { s = String(s.dropFirst().dropLast()) }
                    i = k + m
                    return s
                }
                k += m
            } else {
                k += 1
            }
        }
        return nil
    }

    private func run(of c: Character, at k: Int) -> Int {
        var n = 0
        while k + n < chars.count, chars[k + n] == c { n += 1 }
        return n
    }

    /// `*em*`, `**strong**`, `***both***`, `_em_`, `__strong__`, `~~strike~~`.
    private mutating func delimited(_ c: Character) -> MarkdownInline? {
        let n = run(of: c, at: i)
        if c == "~" && n != 2 { return nil }
        let count = c == "~" ? 2 : min(n, 3)
        let after = i + count
        guard after < chars.count, !chars[after].isWhitespace else { return nil }
        // Intraword `_` is literal (snake_case).
        if c == "_", i > 0, chars[i - 1].isLetter || chars[i - 1].isNumber { return nil }
        // Find a closing run that is not preceded by whitespace.
        var k = after
        var depth = 0
        while k < chars.count {
            if chars[k] == "`" { k += max(1, run(of: "`", at: k)); continue }
            if chars[k] == "[" { depth += 1 } else if chars[k] == "]" { depth -= 1 }
            if depth <= 0, chars[k] == c, run(of: c, at: k) >= count, !chars[k - 1].isWhitespace, k > after {
                if c == "_", k + count < chars.count, chars[k + count].isLetter || chars[k + count].isNumber { k += 1; continue }
                break
            }
            k += 1
        }
        guard k < chars.count else { return nil }
        var inner = InlineParser(String(chars[after..<k]))
        let content = inner.parse()
        i = k + count
        switch (c, count) {
        case ("~", _): return .strike(content)
        case (_, 1): return .emphasis(content)
        case (_, 2): return .strong(content)
        default: return .strong([.emphasis(content)])
        }
    }

    /// `[text](url "title")`.
    private mutating func link() -> MarkdownInline? {
        let save = i
        guard let (label, dest) = bracketThenParen(from: i) else { i = save; return nil }
        var inner = InlineParser(label)
        return .link(text: inner.parse(), url: dest)
    }

    private mutating func image() -> MarkdownInline? {
        let save = i
        guard let (alt, dest) = bracketThenParen(from: i + 1) else { i = save; return nil }
        return .image(alt: alt, url: dest)
    }

    /// Parses `[...](...)` starting at `start` (the `[`). On success moves `i` past it.
    private mutating func bracketThenParen(from start: Int) -> (String, String)? {
        guard start < chars.count, chars[start] == "[" else { return nil }
        var k = start + 1
        var depth = 1
        while k < chars.count {
            if chars[k] == "\\" { k += 2; continue }
            if chars[k] == "`" { k += max(1, run(of: "`", at: k)); continue }
            if chars[k] == "[" { depth += 1 }
            if chars[k] == "]" { depth -= 1; if depth == 0 { break } }
            k += 1
        }
        guard k < chars.count, k + 1 < chars.count, chars[k + 1] == "(" else { return nil }
        let label = String(chars[(start + 1)..<k])
        var j = k + 2
        var parens = 1
        var dest = ""
        if j < chars.count, chars[j] == "<" {
            j += 1
            while j < chars.count, chars[j] != ">" { dest.append(chars[j]); j += 1 }
            guard j < chars.count else { return nil }
            j += 1
            while j < chars.count, chars[j] != ")" { j += 1 }
        } else {
            while j < chars.count {
                let ch = chars[j]
                if ch == "(" { parens += 1 }
                if ch == ")" { parens -= 1; if parens == 0 { break } }
                if ch == " " { break }
                dest.append(ch)
                j += 1
            }
            // Optional title.
            while j < chars.count, chars[j] != ")" { j += 1 }
        }
        guard j < chars.count, chars[j] == ")" else { return nil }
        i = j + 1
        return (label, dest)
    }

    private mutating func autolink() -> MarkdownInline? {
        var k = i + 1
        var s = ""
        while k < chars.count, chars[k] != ">", chars[k] != " ", chars[k] != "<" { s.append(chars[k]); k += 1 }
        guard k < chars.count, chars[k] == ">" else { return nil }
        if s.hasPrefix("http://") || s.hasPrefix("https://") || s.hasPrefix("mailto:") {
            i = k + 1
            return .link(text: [.text(s)], url: s)
        }
        if s.contains("@"), !s.contains(":") {
            i = k + 1
            return .link(text: [.text(s)], url: "mailto:" + s)
        }
        return nil
    }

    private mutating func bareURL() -> String? {
        var k = i
        var s = ""
        while k < chars.count, !chars[k].isWhitespace, chars[k] != "<" { s.append(chars[k]); k += 1 }
        // Trailing punctuation is not part of the URL.
        while let last = s.last, ".,:;!?\"'".contains(last) || (last == ")" && s.filter({ $0 == "(" }).count < s.filter({ $0 == ")" }).count) {
            s.removeLast()
        }
        guard s.count > "https://".count else { return nil }
        i += s.count
        return s
    }
}
