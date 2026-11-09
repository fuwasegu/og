import Foundation

/// Comma-separated file masks like GoLand's: `*.go, *.mod, !*_test.go`.
/// Patterns without `/` match the file name, others the relative path. Case-insensitive.
public struct FileMask: Sendable, Hashable {
    public let include: [String]
    public let exclude: [String]

    public init(_ mask: String?) {
        var inc: [String] = [], exc: [String] = []
        for part in (mask ?? "").split(separator: ",") {
            let p = part.trimmingCharacters(in: .whitespaces)
            if p.isEmpty { continue }
            if p.hasPrefix("!") {
                let rest = String(p.dropFirst())
                if !rest.isEmpty { exc.append(rest) }
            } else {
                inc.append(p)
            }
        }
        include = inc
        exclude = exc
    }

    public var isEmpty: Bool { include.isEmpty && exclude.isEmpty }

    public func matches(_ relativePath: String) -> Bool {
        let name = relativePath.split(separator: "/").last.map(String.init) ?? relativePath
        func hit(_ pattern: String) -> Bool {
            let subject = pattern.contains("/") ? relativePath : name
            return fnmatch(pattern, subject, FNM_CASEFOLD) == 0
        }
        if !include.isEmpty && !include.contains(where: hit) { return false }
        return !exclude.contains(where: hit)
    }
}

/// An `NSRegularExpression` is immutable and documented thread-safe.
public final class CompiledQuery: @unchecked Sendable {
    public let regex: NSRegularExpression
    /// For literal queries: UTF-8 bytes used to cheaply skip files that cannot match.
    let literalBytes: [UInt8]?
    let foldASCII: Bool

    init(regex: NSRegularExpression, literalBytes: [UInt8]?, foldASCII: Bool) {
        self.regex = regex
        self.literalBytes = literalBytes
        self.foldASCII = foldASCII
    }
}

public enum TextSearch {
    public static let maxFileSize = 5 * 1024 * 1024
    /// Lines longer than this are clipped around the match in `SearchHit.lineText`.
    public static let maxPreviewLength = 1000

    /// Builds the matcher used by both search and replace (so they always agree).
    public static func compile(_ query: String, options: SearchOptions) throws -> CompiledQuery {
        var pattern = options.regex ? query : NSRegularExpression.escapedPattern(for: query)
        if options.wholeWord {
            pattern = "(?<![\\p{L}\\p{N}_])(?:" + pattern + ")(?![\\p{L}\\p{N}_])"
        }
        var opts: NSRegularExpression.Options = [.anchorsMatchLines]
        if !options.caseSensitive { opts.insert(.caseInsensitive) }
        let re = try NSRegularExpression(pattern: pattern, options: opts)
        var bytes: [UInt8]? = nil
        var fold = false
        if !options.regex && !query.isEmpty {
            let utf8 = Array(query.utf8)
            if options.caseSensitive {
                bytes = utf8
            } else if utf8.allSatisfy({ $0 < 0x80 }) {
                bytes = utf8.map(asciiLower)
                fold = true
            }
        }
        return CompiledQuery(regex: re, literalBytes: bytes, foldASCII: fold)
    }

    /// nil when the query is valid; otherwise a short error message (invalid regex).
    public static func validate(_ query: String, options: SearchOptions) -> String? {
        do {
            _ = try compile(query, options: options)
            return nil
        } catch {
            return options.regex ? "Invalid regular expression" : error.localizedDescription
        }
    }

    @inline(__always)
    static func asciiLower(_ b: UInt8) -> UInt8 { (b >= 0x41 && b <= 0x5A) ? b + 32 : b }

    /// Cheap byte-level test for literal queries (no false negatives).
    static func mayContain(_ data: Data, _ q: CompiledQuery) -> Bool {
        guard let needle = q.literalBytes, !needle.isEmpty else { return true }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress, raw.count >= needle.count else { return false }
            if !q.foldASCII {
                return needle.withUnsafeBytes { n in memmem(base, raw.count, n.baseAddress, n.count) != nil }
            }
            let bytes = raw.bindMemory(to: UInt8.self)
            let first = needle[0]
            let firstUpper: UInt8 = (first >= 0x61 && first <= 0x7A) ? first - 32 : first
            let last = raw.count - needle.count
            // Next candidate position for each case of the first byte (recomputed only when consumed).
            func next(_ b: UInt8, from i: Int) -> Int {
                guard i <= last, let p = memchr(base + i, Int32(b), last - i + 1) else { return Int.max }
                return base.distance(to: p)
            }
            var nl = next(first, from: 0)
            var nu = first == firstUpper ? Int.max : next(firstUpper, from: 0)
            while true {
                let k = min(nl, nu)
                if k == Int.max { return false }
                if matchFolded(bytes, at: k, needle) { return true }
                if nl == k { nl = next(first, from: k + 1) }
                if nu == k { nu = next(firstUpper, from: k + 1) }
            }
        }
    }

    @inline(__always)
    private static func matchFolded(_ bytes: UnsafeBufferPointer<UInt8>, at k: Int, _ needle: [UInt8]) -> Bool {
        var j = 1
        while j < needle.count {
            if asciiLower(bytes[k + j]) != needle[j] { return false }
            j += 1
        }
        return true
    }

    static func looksBinary(_ data: Data) -> Bool {
        let n = min(data.count, 8000)
        if n == 0 { return false }
        return data.withUnsafeBytes { raw in memchr(raw.baseAddress, 0, n) != nil }
    }

    /// Reads a regular file of at most `maxFileSize` bytes with plain POSIX I/O
    /// (much cheaper per file than `Data(contentsOf:)`, which matters for thousands of small files).
    static func readFile(_ path: String) -> Data? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= maxFileSize else { return nil }
        let size = Int(st.st_size)
        if size == 0 { return Data() }
        var data = Data(count: size)
        let got = data.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) -> Int in
            var off = 0
            while off < size {
                let n = read(fd, buf.baseAddress.map { $0 + off }, size - off)
                if n <= 0 { break }
                off += n
            }
            return off
        }
        if got < size { data.count = got }
        return data
    }

    /// Reads a searchable text file (nil for missing, huge, binary, or non-UTF-8 files).
    public static func readText(_ url: URL) -> (data: Data, text: String)? {
        guard let data = readFile(url.path), !looksBinary(data) else { return nil }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return (data, text)
    }

    /// All matches in one file. Zero-length matches are skipped; a match spanning lines
    /// is reported on its first line, clipped to that line.
    public static func hits(in text: String, url: URL, query: CompiledQuery, limit: Int = .max) -> [SearchHit] {
        let ns = text as NSString
        var hits: [SearchHit] = []
        var lines: TextLines?
        query.regex.enumerateMatches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) { m, _, stop in
            guard let r = m?.range, r.length > 0 else { return }
            if lines == nil { lines = TextLines(nsString: ns) }
            guard let tl = lines else { return }
            let line = tl.line(forOffset: r.location)
            let lr = tl.lineRange(line)
            let col = r.location - lr.location
            let len = min(r.length, max(0, NSMaxRange(lr) - r.location))
            var previewStart = 0
            var preview: String
            if lr.length > maxPreviewLength {
                previewStart = max(0, col - 120)
                let end = min(lr.length, max(col + len + 300, previewStart + 400))
                preview = ns.substring(with: NSRange(location: lr.location + previewStart, length: end - previewStart))
            } else {
                preview = ns.substring(with: lr)
            }
            var hit = SearchHit(url: url, line: line, column: col, length: len, lineText: preview)
            hit.lineTextOffset = previewStart
            hits.append(hit)
            if hits.count >= limit { stop.pointee = true }
        }
        return hits
    }

    /// Searches one file on disk (prefilter, binary/size checks, then regex).
    public static func searchFile(_ url: URL, query: CompiledQuery, limit: Int = .max) -> [SearchHit] {
        guard let data = readFile(url.path), !data.isEmpty else { return [] }
        guard mayContain(data, query), !looksBinary(data) else { return [] }
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return hits(in: text, url: url, query: query, limit: limit)
    }

    /// Replaces every match. For regex queries `$1`-style templates are honored;
    /// literal queries insert the replacement verbatim.
    public static func replace(in text: String, query: CompiledQuery, replacement: String, regexTemplate: Bool) -> (text: String, count: Int) {
        let ns = NSMutableString(string: text)
        let template = regexTemplate ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
        // Count non-empty matches only, mirroring `hits(in:)`.
        let matches = query.regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)).filter { $0.range.length > 0 }
        for m in matches.reversed() {
            let rep = query.regex.replacementString(for: m, in: text, offset: 0, template: template)
            ns.replaceCharacters(in: m.range, with: rep)
        }
        return (ns as String, matches.count)
    }
}
