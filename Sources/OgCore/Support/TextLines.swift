import Foundation

/// UTF-16 line index over a string. LSP positions and NSRange both use UTF-16
/// code units, so all conversions go through this type.
public struct TextLines: @unchecked Sendable {  // `text` is an immutable copy
    public let text: NSString
    /// UTF-16 offset of the first character of each line.
    public let lineStarts: [Int]

    public init(_ string: String) {
        self.init(nsString: string as NSString)
    }

    public init(nsString: NSString) {
        self.text = NSString(string: nsString as String)
        var starts = [0]
        let length = nsString.length
        var i = 0
        // Fast scan over UTF-16 code units.
        let buffer = UnsafeMutablePointer<unichar>.allocate(capacity: max(length, 1))
        defer { buffer.deallocate() }
        nsString.getCharacters(buffer, range: NSRange(location: 0, length: length))
        while i < length {
            let c = buffer[i]
            if c == 0x0A {
                starts.append(i + 1)
            } else if c == 0x0D {
                if i + 1 < length && buffer[i + 1] == 0x0A { i += 1 }
                starts.append(i + 1)
            }
            i += 1
        }
        self.lineStarts = starts
    }

    public var lineCount: Int { lineStarts.count }
    public var length: Int { text.length }

    /// Line containing a UTF-16 offset (0-based).
    public func line(forOffset offset: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        let o = max(0, min(offset, text.length))
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= o { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Range of a line, excluding its terminator.
    public func lineRange(_ line: Int) -> NSRange {
        guard line >= 0, line < lineStarts.count else { return NSRange(location: text.length, length: 0) }
        let start = lineStarts[line]
        var end = line + 1 < lineStarts.count ? lineStarts[line + 1] : text.length
        while end > start {
            let c = text.character(at: end - 1)
            if c == 0x0A || c == 0x0D { end -= 1 } else { break }
        }
        return NSRange(location: start, length: end - start)
    }

    public func lineText(_ line: Int) -> String {
        text.substring(with: lineRange(line))
    }

    public func position(forOffset offset: Int) -> LSPPosition {
        let l = line(forOffset: offset)
        return LSPPosition(line: l, character: max(0, min(offset, text.length) - lineStarts[l]))
    }

    public func offset(for position: LSPPosition) -> Int {
        guard position.line < lineStarts.count else { return text.length }
        guard position.line >= 0 else { return 0 }
        let r = lineRange(position.line)
        return r.location + max(0, min(position.character, r.length))
    }

    public func nsRange(for range: LSPRange) -> NSRange {
        let s = offset(for: range.start)
        let e = offset(for: range.end)
        return NSRange(location: min(s, e), length: abs(e - s))
    }

    public func lspRange(for range: NSRange) -> LSPRange {
        LSPRange(start: position(forOffset: range.location), end: position(forOffset: NSMaxRange(range)))
    }
}
