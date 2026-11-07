import Foundation
#if canImport(_RopeModule)
import _RopeModule
#endif

/// Represents a 0-indexed (line, column) position in the document.
public struct TextPosition: Sendable, Equatable, Comparable, Hashable, Codable {
    public var line: Int
    public var column: Int // Character / UTF-8 column index within the line

    public init(line: Int, column: Int) {
        self.line = max(0, line)
        self.column = max(0, column)
    }

    public static func < (lhs: TextPosition, rhs: TextPosition) -> Bool {
        if lhs.line != rhs.line {
            return lhs.line < rhs.line
        }
        return lhs.column < rhs.column
    }

    public static let zero = TextPosition(line: 0, column: 0)
}

/// Represents a half-open range of text positions `[start, end)`.
public struct TextRange: Sendable, Equatable, Hashable, Codable {
    public var start: TextPosition
    public var end: TextPosition

    public init(start: TextPosition, end: TextPosition) {
        if start <= end {
            self.start = start
            self.end = end
        } else {
            self.start = end
            self.end = start
        }
    }

    public var isEmpty: Bool {
        start == end
    }
}

/// Represents an atomic edit operation for Undo/Redo and incremental AST/LSP synchronization.
public struct TextEdit: Sendable, Equatable {
    public let range: Range<Int> // Character offset range
    public let oldText: String
    public let newText: String
    public let cursorBefore: TextPosition
    public let cursorAfter: TextPosition

    public init(
        range: Range<Int>,
        oldText: String,
        newText: String,
        cursorBefore: TextPosition,
        cursorAfter: TextPosition
    ) {
        self.range = range
        self.oldText = oldText
        self.newText = newText
        self.cursorBefore = cursorBefore
        self.cursorAfter = cursorAfter
    }
}

/// High-performance B-Tree Rope-backed text buffer designed for 120fps native editing.
public final class TextBuffer: @unchecked Sendable {
    private static let targetChunkSize = 1024

    private struct Chunk: Sendable {
        var text: String
        var charCount: Int
        var utf8Count: Int
        var utf16Count: Int
        var newlineOffsets: [Int]

        init(_ text: String) {
            self.text = text
            self.charCount = text.count
            self.utf8Count = text.utf8.count
            self.utf16Count = text.utf16.count
            var nl: [Int] = []
            var idx = 0
            for ch in text {
                if ch == "\n" {
                    nl.append(idx)
                }
                idx += 1
            }
            self.newlineOffsets = nl
        }
    }

    private var chunks: [Chunk] = []
    private var cachedLineStarts: [Int]?
    public private(set) var version: Int = 1

    private var undoStack: [TextEdit] = []
    private var redoStack: [TextEdit] = []

    public init(_ initialText: String = "") {
        rebuildChunks(from: initialText)
    }

    public var string: String {
        chunks.map(\.text).joined()
    }

    public var count: Int {
        chunks.reduce(0) { $0 + $1.charCount }
    }

    public var utf8Count: Int {
        chunks.reduce(0) { $0 + $1.utf8Count }
    }

    public var utf16Count: Int {
        chunks.reduce(0) { $0 + $1.utf16Count }
    }

    public var lineCount: Int {
        ensureLineCache().count
    }

    @discardableResult
    private func ensureLineCache() -> [Int] {
        if let cached = cachedLineStarts {
            return cached
        }
        var starts: [Int] = [0]
        var globalOffset = 0
        for chunk in chunks {
            for nl in chunk.newlineOffsets {
                starts.append(globalOffset + nl + 1)
            }
            globalOffset += chunk.charCount
        }
        cachedLineStarts = starts
        return starts
    }

    public func lineContent(at lineIndex: Int) -> String {
        let starts = ensureLineCache()
        guard lineIndex >= 0 && lineIndex < starts.count else { return "" }
        let startOffset = starts[lineIndex]
        let endOffset = (lineIndex + 1 < starts.count) ? (starts[lineIndex + 1] - 1) : count
        guard startOffset <= endOffset else { return "" }
        return substring(in: startOffset..<endOffset)
    }

    public func lineCharacterRange(at lineIndex: Int) -> Range<Int> {
        let starts = ensureLineCache()
        guard lineIndex >= 0 && lineIndex < starts.count else { return 0..<0 }
        let startOffset = starts[lineIndex]
        let endOffset = (lineIndex + 1 < starts.count) ? (starts[lineIndex + 1] - 1) : count
        return startOffset..<max(startOffset, endOffset)
    }

    public func characterOffset(for position: TextPosition) -> Int {
        let starts = ensureLineCache()
        guard !starts.isEmpty else { return 0 }
        let clampedLine = min(max(0, position.line), starts.count - 1)
        let lineStart = starts[clampedLine]
        let lineEnd = (clampedLine + 1 < starts.count) ? (starts[clampedLine + 1] - 1) : count
        let maxCol = max(0, lineEnd - lineStart)
        let clampedCol = min(max(0, position.column), maxCol)
        return lineStart + clampedCol
    }

    public func position(forCharacterOffset offset: Int) -> TextPosition {
        let starts = ensureLineCache()
        let clamped = min(max(0, offset), count)
        var low = 0
        var high = starts.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if starts[mid] <= clamped {
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        let lineIdx = max(0, high)
        let col = clamped - starts[lineIdx]
        return TextPosition(line: lineIdx, column: col)
    }

    public func utf16Offset(for position: TextPosition) -> Int {
        let charOff = characterOffset(for: position)
        return utf16Offset(forCharacterOffset: charOff)
    }

    public func utf16Offset(forCharacterOffset charOffset: Int) -> Int {
        let clamped = min(max(0, charOffset), count)
        var remaining = clamped
        var utf16Total = 0
        for chunk in chunks {
            if remaining >= chunk.charCount {
                remaining -= chunk.charCount
                utf16Total += chunk.utf16Count
                if remaining == 0 { break }
            } else {
                let prefix = chunk.text.prefix(remaining)
                utf16Total += prefix.utf16.count
                break
            }
        }
        return utf16Total
    }

    public func characterOffset(forUTF8Offset utf8Offset: Int) -> Int {
        let clamped = min(max(0, utf8Offset), utf8Count)
        var remainingUTF8 = clamped
        var charTotal = 0
        for chunk in chunks {
            if remainingUTF8 >= chunk.utf8Count {
                remainingUTF8 -= chunk.utf8Count
                charTotal += chunk.charCount
                if remainingUTF8 == 0 { break }
            } else {
                let utf8View = chunk.text.utf8
                let endIdx = utf8View.index(utf8View.startIndex, offsetBy: remainingUTF8, limitedBy: utf8View.endIndex) ?? utf8View.endIndex
                let sub = String(decoding: utf8View[..<endIdx], as: UTF8.self)
                charTotal += sub.count
                break
            }
        }
        return charTotal
    }

    public func lspUTF16Column(for position: TextPosition) -> Int {
        let lineStr = lineContent(at: position.line)
        let prefix = lineStr.prefix(max(0, position.column))
        return prefix.utf16.count
    }

    public func position(forLSPPosition lspPos: LSPPosition) -> TextPosition {
        let clampedLine = min(max(0, lspPos.line), max(0, lineCount - 1))
        let lineStr = lineContent(at: clampedLine)
        let utf16View = lineStr.utf16
        let clampedUTF16 = min(max(0, lspPos.character), utf16View.count)
        let utf16Idx = utf16View.index(utf16View.startIndex, offsetBy: clampedUTF16)
        let charIdx = utf16Idx.samePosition(in: lineStr) ?? lineStr.endIndex
        let col = lineStr.distance(from: lineStr.startIndex, to: charIdx)
        return TextPosition(line: clampedLine, column: col)
    }

    public func substring(in range: Range<Int>) -> String {
        let lower = min(max(0, range.lowerBound), count)
        let upper = min(max(lower, range.upperBound), count)
        guard lower < upper else { return "" }

        var result = ""
        result.reserveCapacity(upper - lower)
        var currentGlobal = 0

        for chunk in chunks {
            let chunkStart = currentGlobal
            let chunkEnd = currentGlobal + chunk.charCount
            currentGlobal = chunkEnd

            if chunkEnd <= lower { continue }
            if chunkStart >= upper { break }

            let localStart = max(0, lower - chunkStart)
            let localEnd = min(chunk.charCount, upper - chunkStart)
            let sIdx = chunk.text.index(chunk.text.startIndex, offsetBy: localStart)
            let eIdx = chunk.text.index(chunk.text.startIndex, offsetBy: localEnd)
            result.append(contentsOf: chunk.text[sIdx..<eIdx])
        }
        return result
    }

    @discardableResult
    public func insert(_ newText: String, at charOffset: Int) -> TextPosition {
        replace(range: charOffset..<charOffset, with: newText)
    }

    @discardableResult
    public func delete(in range: Range<Int>) -> TextPosition {
        replace(range: range, with: "")
    }

    @discardableResult
    public func replace(
        range: Range<Int>,
        with replacement: String,
        recordUndo: Bool = true
    ) -> TextPosition {
        let lower = min(max(0, range.lowerBound), count)
        let upper = min(max(lower, range.upperBound), count)
        let safeRange = lower..<upper

        let oldText = substring(in: safeRange)
        let cursorBefore = position(forCharacterOffset: upper)

        applyRawReplace(range: safeRange, with: replacement)
        version += 1

        let newCursorOffset = lower + replacement.count
        let cursorAfter = position(forCharacterOffset: newCursorOffset)

        if recordUndo && (oldText != replacement) {
            let edit = TextEdit(
                range: lower..<(lower + replacement.count),
                oldText: oldText,
                newText: replacement,
                cursorBefore: cursorBefore,
                cursorAfter: cursorAfter
            )
            undoStack.append(edit)
            redoStack.removeAll()
        }

        return cursorAfter
    }

    @discardableResult
    public func replace(textRange: TextRange, with replacement: String, recordUndo: Bool = true) -> TextPosition {
        let startOff = characterOffset(for: textRange.start)
        let endOff = characterOffset(for: textRange.end)
        return replace(range: startOff..<endOff, with: replacement, recordUndo: recordUndo)
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    @discardableResult
    public func undo() -> TextPosition? {
        guard let last = undoStack.popLast() else { return nil }
        applyRawReplace(range: last.range, with: last.oldText)
        version += 1
        redoStack.append(last)
        return last.cursorBefore
    }

    @discardableResult
    public func redo() -> TextPosition? {
        guard let next = redoStack.popLast() else { return nil }
        let oldRange = next.range.lowerBound..<(next.range.lowerBound + next.oldText.count)
        applyRawReplace(range: oldRange, with: next.newText)
        version += 1
        undoStack.append(next)
        return next.cursorAfter
    }

    private static func splitIntoChunks(_ text: String) -> [Chunk] {
        guard !text.isEmpty else { return [] }
        var result: [Chunk] = []
        var idx = text.startIndex
        while idx < text.endIndex {
            let nextIdx = text.index(idx, offsetBy: targetChunkSize, limitedBy: text.endIndex) ?? text.endIndex
            result.append(Chunk(String(text[idx..<nextIdx])))
            idx = nextIdx
        }
        return result
    }

    private func rebuildChunks(from fullText: String) {
        cachedLineStarts = nil
        let split = Self.splitIntoChunks(fullText)
        chunks = split.isEmpty ? [Chunk("")] : split
    }

    private func applyRawReplace(range: Range<Int>, with replacement: String) {
        cachedLineStarts = nil
        if chunks.isEmpty {
            rebuildChunks(from: replacement)
            return
        }

        var firstChunkIdx = 0
        var firstChunkStart = 0
        var running = 0
        for (idx, chunk) in chunks.enumerated() {
            let nextRunning = running + chunk.charCount
            if range.lowerBound <= nextRunning || idx == chunks.count - 1 {
                firstChunkIdx = idx
                firstChunkStart = running
                break
            }
            running = nextRunning
        }

        var lastChunkIdx = firstChunkIdx
        var lastChunkEnd = firstChunkStart + chunks[firstChunkIdx].charCount
        for idx in firstChunkIdx..<chunks.count {
            let endOff = (idx == firstChunkIdx) ? lastChunkEnd : (lastChunkEnd + chunks[idx].charCount)
            lastChunkIdx = idx
            lastChunkEnd = endOff
            if range.upperBound <= endOff {
                break
            }
        }

        let firstChunkText = chunks[firstChunkIdx].text
        let prefixCount = max(0, range.lowerBound - firstChunkStart)
        let prefixPart = String(firstChunkText.prefix(prefixCount))

        let lastChunkText = chunks[lastChunkIdx].text
        let suffixCount = max(0, lastChunkEnd - range.upperBound)
        let suffixPart = String(lastChunkText.suffix(suffixCount))

        let combined = prefixPart + replacement + suffixPart
        var replacementChunks = Self.splitIntoChunks(combined)
        if replacementChunks.isEmpty && chunks.count == (lastChunkIdx - firstChunkIdx + 1) {
            replacementChunks = [Chunk("")]
        }
        chunks.replaceSubrange(firstChunkIdx...lastChunkIdx, with: replacementChunks)
    }
}
