import Foundation

/// Where the caret sits in a Markdown buffer, as far as completion cares.
public enum MarkdownCompletionContext: Sendable, Hashable {
    /// The info string of an opening code fence (```` ```go ````).
    case fenceLanguage(replace: NSRange)
    /// A relative path in a link or image destination. `directory` is the typed part up to and
    /// including the last `/`, percent-decoded ("" for the document's own folder).
    case path(directory: String, image: Bool, replace: NSRange)
    /// A heading anchor after `#` in a link destination. `file` is the path before `#`
    /// ("" for the document itself), percent-decoded.
    case anchor(file: String, replace: NSRange)
    /// A reference label in `[text][label]`.
    case reference(replace: NSRange)
    /// A plain word (only on explicit request).
    case word(replace: NSRange)

    public var replaceRange: NSRange {
        switch self {
        case .fenceLanguage(let r), .path(_, _, let r), .anchor(_, let r), .reference(let r), .word(let r): return r
        }
    }
}

/// One Markdown completion: `text` replaces `replace`, the caret lands at its end.
public struct MarkdownCompletion: Sendable, Hashable {
    public var label: String
    public var detail: String
    public var text: String
    public var replace: NSRange
    public var sortText: String
}

/// A directory entry offered for path completion.
public struct MarkdownPathEntry: Sendable, Hashable {
    public var name: String
    public var isDirectory: Bool
    public init(name: String, isDirectory: Bool) {
        self.name = name
        self.isDirectory = isDirectory
    }
}

public enum MarkdownCompletions {
    /// Languages offered after an opening fence, most common first.
    public static let languages = [
        "go", "bash", "sh", "shell", "console", "json", "yaml", "toml", "text", "diff", "mermaid",
        "swift", "python", "javascript", "typescript", "tsx", "html", "css", "sql", "proto",
        "dockerfile", "makefile", "c", "cpp", "rust", "java", "kotlin", "ruby", "php", "xml", "ini", "markdown",
    ]

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "svg", "webp", "bmp", "ico"]

    // MARK: - Context

    /// The completion context at `caret`, or nil where Markdown offers nothing.
    /// `explicit` (⌃Space) also allows an empty fence info string and plain words.
    public static func context(in ns: NSString, caret: Int, explicit: Bool = false) -> MarkdownCompletionContext? {
        guard caret >= 0, caret <= ns.length else { return nil }
        let lineStart = ns.lineRange(for: NSRange(location: caret, length: 0)).location
        let before = ns.substring(with: NSRange(location: lineStart, length: caret - lineStart))
        let b = before as NSString

        if let fence = fenceInfoStart(before), isOpeningFence(ns, lineStart: lineStart) {
            let partial = b.substring(from: fence)
            if partial.allSatisfy({ $0.isLetter || $0.isNumber || "+-#_".contains($0) }), explicit || !partial.isEmpty {
                return .fenceLanguage(replace: NSRange(location: lineStart + fence, length: b.length - fence))
            }
            return nil
        }
        if insideFence(ns, lineStart: lineStart) { return nil }

        // `](dest` or `![alt](dest` with the caret still inside the destination.
        let open = b.range(of: "](", options: .backwards)
        if open.location != NSNotFound {
            let destStart = NSMaxRange(open)
            let dest = b.substring(from: destStart)
            if !dest.contains(where: { $0 == ")" || $0 == " " || $0 == "\t" || $0 == "<" || $0 == ">" }),
               !hasScheme(dest), countBackticks(b.substring(to: open.location)) % 2 == 0 {
                let image = isImage(b, closeBracket: open.location)
                let d = dest as NSString
                let hash = d.range(of: "#")
                if hash.location != NSNotFound {
                    let file = d.substring(to: hash.location)
                    return .anchor(file: file.removingPercentEncoding ?? file,
                                   replace: NSRange(location: lineStart + destStart + NSMaxRange(hash), length: d.length - NSMaxRange(hash)))
                }
                let slash = d.range(of: "/", options: .backwards)
                let cut = slash.location == NSNotFound ? 0 : NSMaxRange(slash)
                let dir = d.substring(to: cut)
                return .path(directory: dir.removingPercentEncoding ?? dir, image: image,
                             replace: NSRange(location: lineStart + destStart + cut, length: d.length - cut))
            }
        }

        // `][label` — a reference link.
        let ref = b.range(of: "][", options: .backwards)
        if ref.location != NSNotFound {
            let label = b.substring(from: NSMaxRange(ref))
            if !label.contains("]"), !label.contains("["), countBackticks(b.substring(to: ref.location)) % 2 == 0 {
                return .reference(replace: NSRange(location: lineStart + NSMaxRange(ref), length: (label as NSString).length))
            }
        }

        guard explicit else { return nil }
        var start = caret
        while start > lineStart, isWordUnit(ns.character(at: start - 1)) { start -= 1 }
        return .word(replace: NSRange(location: start, length: caret - start))
    }

    // MARK: - Items

    /// Items for `context`. `entries` lists the directory of a `.path` context; `headings` are the
    /// heading texts of the anchor target (the buffer itself when nil).
    public static func items(for context: MarkdownCompletionContext, in text: String,
                             entries: [MarkdownPathEntry] = [], headings: [String]? = nil, caret: Int) -> [MarkdownCompletion] {
        switch context {
        case .fenceLanguage(let r):
            return languages.enumerated().map { i, l in
                MarkdownCompletion(label: l, detail: "language", text: l, replace: r, sortText: String(format: "%03d", i))
            }
        case .path(_, let image, let r):
            return entries.filter { $0.name != ".git" && $0.name != ".DS_Store" }.map { e in
                let ext = (e.name as NSString).pathExtension.lowercased()
                // Directories first; for images, image files before other files.
                let rank = e.isDirectory ? "0" : (image && imageExtensions.contains(ext)) || (!image && ext == "md") ? "1" : "2"
                let name = e.name + (e.isDirectory ? "/" : "")
                return MarkdownCompletion(label: name, detail: e.isDirectory ? "directory" : "file",
                                          text: encodePath(name), replace: r, sortText: rank + e.name.lowercased())
            }
        case .anchor(_, let r):
            return headingSlugs(headings ?? self.headings(in: text)).enumerated().map { i, h in
                MarkdownCompletion(label: "#" + h.slug, detail: h.title, text: h.slug, replace: r, sortText: String(format: "%04d", i))
            }
        case .reference(let r):
            return referenceLabels(in: text).enumerated().map { i, l in
                MarkdownCompletion(label: l, detail: "reference", text: l, replace: r, sortText: String(format: "%04d", i))
            }
        case .word(let r):
            let ns = text as NSString
            let current = ns.substring(with: NSRange(location: r.location, length: max(0, min(caret, ns.length) - r.location)))
            return words(in: text, excluding: r.location).filter { $0 != current }.enumerated().map { i, w in
                MarkdownCompletion(label: w, detail: "word", text: w, replace: r, sortText: String(format: "%04d", i))
            }
        }
    }

    // MARK: - Headings and anchors

    /// Heading texts of a Markdown document, in order (ATX and setext, outside code).
    public static func headings(in text: String) -> [String] {
        Markdown.parse(text).compactMap { block in
            if case .heading(_, let inl, _) = block { return inl.map(\.plainText).joined() }
            return nil
        }
    }

    /// GitHub-style anchors: lowercased, punctuation dropped, spaces to `-`, duplicates numbered.
    public static func headingSlugs(_ titles: [String]) -> [(slug: String, title: String)] {
        var seen: [String: Int] = [:]
        var out: [(String, String)] = []
        for t in titles {
            let base = slug(t)
            guard !base.isEmpty else { continue }
            let n = seen[base, default: 0]
            seen[base] = n + 1
            out.append((n == 0 ? base : "\(base)-\(n)", t))
        }
        return out
    }

    public static func slug(_ title: String) -> String {
        var s = ""
        for c in title.lowercased() {
            if c == " " { s.append("-") } else if c.isLetter || c.isNumber || c == "-" || c == "_" { s.append(c) }
        }
        return s
    }

    /// Labels of `[label]: url` definitions, in order, without duplicates.
    public static func referenceLabels(in text: String) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let t = line.drop(while: { $0 == " " })
            guard t.first == "[", let close = t.firstIndex(of: "]") else { continue }
            let after = t[t.index(after: close)...]
            guard after.first == ":" else { continue }
            let label = String(t[t.index(after: t.startIndex)..<close])
            if !label.isEmpty, !label.hasPrefix("^"), seen.insert(label.lowercased()).inserted { out.append(label) }
        }
        return out
    }

    // MARK: - Helpers

    /// UTF-16 offset in `line` where an opening fence's info string starts, if the line is a fence.
    static func fenceInfoStart(_ line: String) -> Int? {
        let ns = line as NSString
        var i = 0
        while i < ns.length, i < 3, ns.character(at: i) == 32 { i += 1 }
        guard i < ns.length else { return nil }
        let f = ns.character(at: i)
        guard f == 96 || f == 126 else { return nil }   // ` or ~
        var j = i
        while j < ns.length, ns.character(at: j) == f { j += 1 }
        guard j - i >= 3 else { return nil }
        return j
    }

    /// The line at `lineStart` opens a fence: an even number of fences precede it.
    static func isOpeningFence(_ ns: NSString, lineStart: Int) -> Bool { !insideFence(ns, lineStart: lineStart) }

    /// Lines before `lineStart` leave a fence open.
    static func insideFence(_ ns: NSString, lineStart: Int) -> Bool {
        var open = false
        ns.substring(to: lineStart).enumerateLines { line, _ in
            if fenceInfoStart(line) != nil { open.toggle() }
        }
        return open
    }

    static func hasScheme(_ dest: String) -> Bool {
        let lower = dest.lowercased()
        return lower.hasPrefix("http:") || lower.hasPrefix("https:") || lower.hasPrefix("mailto:") || lower.hasPrefix("//")
            || lower.contains("://")
    }

    /// The `](` at `closeBracket` ends `![alt]`.
    static func isImage(_ line: NSString, closeBracket: Int) -> Bool {
        var depth = 0
        var i = closeBracket - 1
        while i >= 0 {
            let c = line.character(at: i)
            if c == 93 { depth += 1 }                     // ]
            if c == 91 {                                   // [
                if depth == 0 { return i > 0 && line.character(at: i - 1) == 33 }   // !
                depth -= 1
            }
            i -= 1
        }
        return false
    }

    static func countBackticks(_ s: String) -> Int { s.utf16.filter { $0 == 96 }.count }

    static func encodePath(_ s: String) -> String {
        s.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
    }

    static func isWordUnit(_ u: unichar) -> Bool {
        guard let s = UnicodeScalar(u) else { return false }
        return CharacterSet.alphanumerics.contains(s) || u == 95 || u == 45   // _ -
    }

    /// Distinct words (3+ characters) of the text, most frequent first; the one at `excluding` is skipped.
    static func words(in text: String, excluding: Int) -> [String] {
        let ns = text as NSString
        var counts: [String: Int] = [:]
        var order: [String] = []
        var i = 0
        while i < ns.length {
            guard isWordUnit(ns.character(at: i)) else { i += 1; continue }
            let start = i
            while i < ns.length, isWordUnit(ns.character(at: i)) { i += 1 }
            guard start != excluding, i - start >= 3 else { continue }
            let w = ns.substring(with: NSRange(location: start, length: i - start))
            guard w.first?.isLetter == true else { continue }
            if counts[w] == nil { order.append(w) }
            counts[w, default: 0] += 1
        }
        return order.sorted { counts[$0, default: 0] > counts[$1, default: 0] }.prefix(300).map { $0 }
    }
}
