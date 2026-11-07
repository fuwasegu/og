import AppKit
import CoreText
import SwiftUI

@MainActor
public final class EditorView: NSView {
    public var buffer: TextBuffer {
        didSet {
            rebuildAnalysesAndRedraw()
        }
    }

    public let highlighter = SyntaxHighlighter()
    public let completionCoordinator = InlineCompletionCoordinator()

    public var filePath: String = "main.go"
    public var cursorPosition: TextPosition = .zero {
        didSet {
            needsDisplay = true
            onCursorChanged?(cursorPosition)
        }
    }
    public var selectionAnchor: TextPosition?
    public var ghostText: String = "" {
        didSet { needsDisplay = true }
    }

    public var diagnostics: [LSPDiagnostic] = [] {
        didSet { needsDisplay = true }
    }

    public var inlineTestResults: [Int: GoTestRunResult] = [:] {
        didSet { needsDisplay = true }
    }

    public var foldErrorBlocks: Bool = false {
        didSet { needsDisplay = true }
    }

    public var dimErrorBlocks: Bool = true {
        didSet {
            highlighter.dimErrorBoilerplate = dimErrorBlocks
            needsDisplay = true
        }
    }

    public var onBufferModified: ((TextBuffer) -> Void)?
    public var onCursorChanged: ((TextPosition) -> Void)?
    public var onRunGoTestRequested: ((GoASTAnalysis.FuncEntry) -> Void)?
    public var onDefinitionRequested: ((TextPosition) -> Void)?
    public var onRenameRequested: ((TextPosition) -> Void)?

    public var editorFont: NSFont = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular) {
        didSet { computeFontMetrics() }
    }
    private(set) var lineHeight: CGFloat = 21.0
    private(set) var charAdvance: CGFloat = 8.2
    private(set) var fontAscent: CGFloat = 15.0
    private let gutterWidth: CGFloat = 68.0
    private let textLeftPadding: CGFloat = 12.0

    private(set) var astAnalysis = GoASTAnalysis(
        packageName: "main",
        importsBlock: "",
        functions: [],
        types: [],
        errorHandlingBlocks: [],
        implicitInterfaceImpls: [:]
    )

    private var testButtonHitRects: [(rect: CGRect, funcEntry: GoASTAnalysis.FuncEntry)] = []

    public init(buffer: TextBuffer = TextBuffer(""), frame frameRect: NSRect = .zero) {
        self.buffer = buffer
        super.init(frame: frameRect)
        self.wantsLayer = true
        computeFontMetrics()
        rebuildAnalysesAndRedraw()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public var isFlipped: Bool { true }
    override public var acceptsFirstResponder: Bool { true }

    private func computeFontMetrics() {
        let ctFont = editorFont as CTFont
        let ascent = CTFontGetAscent(ctFont)
        let descent = CTFontGetDescent(ctFont)
        let leading = CTFontGetLeading(ctFont)
        self.fontAscent = ceil(ascent)
        self.lineHeight = ceil(ascent + descent + leading + 5.0)

        let sample = NSAttributedString(string: "M", attributes: [.font: editorFont])
        let ctLine = CTLineCreateWithAttributedString(sample)
        self.charAdvance = max(7.0, CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil)))
        needsDisplay = true
    }

    public func rebuildAnalysesAndRedraw() {
        astAnalysis = highlighter.analyzeGoAST(in: buffer)
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override public var intrinsicContentSize: NSSize {
        let height = CGFloat(max(buffer.lineCount + 6, 30)) * lineHeight
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    override public func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let theme = highlighter.theme

        ctx.setFillColor(theme.background.cgColor)
        ctx.fill(dirtyRect)

        let gutterRect = CGRect(x: 0, y: dirtyRect.minY, width: gutterWidth, height: dirtyRect.height)
        ctx.setFillColor(theme.gutterBackground.cgColor)
        ctx.fill(gutterRect)

        let attrText = highlighter.attributedString(for: buffer, font: editorFont)
        let visibleLines = computeVisibleLines()
        testButtonHitRects.removeAll()

        for (visualRow, docLine) in visibleLines.enumerated() {
            let rowY = CGFloat(visualRow) * lineHeight
            if rowY + lineHeight < dirtyRect.minY || rowY > dirtyRect.maxY {
                continue
            }

            if docLine == cursorPosition.line {
                ctx.setFillColor(theme.currentLineHighlight.cgColor)
                ctx.fill(CGRect(x: gutterWidth, y: rowY, width: bounds.width - gutterWidth, height: lineHeight))
            }

            if let selRange = currentSelectionRange() {
                drawSelectionHighlight(in: ctx, docLine: docLine, rowY: rowY, selection: selRange)
            }

            drawLineNumber(in: ctx, docLine: docLine, rowY: rowY)

            let charRange = buffer.lineCharacterRange(at: docLine)
            let utf16Start = buffer.utf16Offset(forCharacterOffset: charRange.lowerBound)
            let utf16End = buffer.utf16Offset(forCharacterOffset: charRange.upperBound)
            let nsLineRange = NSRange(location: utf16Start, length: max(0, utf16End - utf16Start))

            let lineX = gutterWidth + textLeftPadding
            if nsLineRange.length > 0 && NSMaxRange(nsLineRange) <= attrText.length {
                let lineAttr = attrText.attributedSubstring(from: nsLineRange)
                drawCoreTextLine(lineAttr, in: ctx, x: lineX, y: rowY + fontAscent + 1.0)
            }

            let lineCharCount = charRange.count
            let lineEndX = lineX + CGFloat(lineCharCount) * charAdvance
            var badgeX = lineEndX + 12

            if foldErrorBlocks,
               let errBlock = astAnalysis.errorHandlingBlocks.first(where: { $0.lowerBound == docLine && $0.count > 1 }) {
                let r = drawBadge(
                    text: " ⋯ folded (\(errBlock.count) lines: return err) ",
                    at: CGPoint(x: badgeX, y: rowY + 3),
                    backgroundColor: NSColor(calibratedWhite: 0.22, alpha: 0.9),
                    textColor: NSColor(calibratedWhite: 0.78, alpha: 1.0)
                )
                badgeX = r.maxX + 8
            }

            if let impls = astAnalysis.implicitInterfaceImpls[docLine] {
                let label = "⇄ implements " + impls.joined(separator: ", ")
                let r = drawBadge(
                    text: label,
                    at: CGPoint(x: badgeX, y: rowY + 3),
                    backgroundColor: NSColor(calibratedRed: 0.05, green: 0.30, blue: 0.38, alpha: 0.85),
                    textColor: NSColor(calibratedRed: 0.45, green: 0.92, blue: 1.0, alpha: 1.0)
                )
                badgeX = r.maxX + 8
            }

            if let fn = astAnalysis.functions.first(where: { $0.startLine == docLine && ($0.isTest || $0.isBenchmark) }) {
                let btnTitle = fn.isBenchmark ? "▶ Bench" : "▶ Run Test"
                let btnRect = drawBadge(
                    text: btnTitle,
                    at: CGPoint(x: badgeX, y: rowY + 3),
                    backgroundColor: NSColor(calibratedRed: 0.14, green: 0.38, blue: 0.24, alpha: 0.95),
                    textColor: NSColor(calibratedRed: 0.65, green: 0.98, blue: 0.75, alpha: 1.0)
                )
                testButtonHitRects.append((rect: btnRect, funcEntry: fn))
                badgeX = btnRect.maxX + 8

                if let res = inlineTestResults[docLine] {
                    let statusIcon = res.passed ? "✓ PASS" : "✗ FAIL"
                    let metricText = [
                        statusIcon,
                        String(format: "%.3fs", res.durationSeconds),
                        res.nsPerOp,
                        res.allocsPerOp
                    ].compactMap { $0 }.joined(separator: " · ")

                    let bg = res.passed
                        ? NSColor(calibratedRed: 0.10, green: 0.32, blue: 0.18, alpha: 0.85)
                        : NSColor(calibratedRed: 0.42, green: 0.12, blue: 0.14, alpha: 0.90)
                    let fg = res.passed
                        ? NSColor(calibratedRed: 0.55, green: 0.95, blue: 0.68, alpha: 1.0)
                        : NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.65, alpha: 1.0)

                    let r = drawBadge(
                        text: metricText,
                        at: CGPoint(x: badgeX, y: rowY + 3),
                        backgroundColor: bg,
                        textColor: fg
                    )
                    badgeX = r.maxX + 8
                }
            }

            if let diag = diagnostics.first(where: { $0.range.start.line == docLine }) {
                let isErr = (diag.severity ?? .error) == .error
                let bg = isErr
                    ? NSColor(calibratedRed: 0.45, green: 0.12, blue: 0.15, alpha: 0.85)
                    : NSColor(calibratedRed: 0.42, green: 0.32, blue: 0.08, alpha: 0.85)
                let fg = isErr
                    ? NSColor(calibratedRed: 1.0, green: 0.65, blue: 0.68, alpha: 1.0)
                    : NSColor(calibratedRed: 1.0, green: 0.88, blue: 0.52, alpha: 1.0)
                let r = drawBadge(
                    text: "⚠ \(diag.message)",
                    at: CGPoint(x: badgeX, y: rowY + 3),
                    backgroundColor: bg,
                    textColor: fg
                )
                badgeX = r.maxX + 8
            }

            if docLine == cursorPosition.line {
                let caretX = lineX + CGFloat(cursorPosition.column) * charAdvance
                ctx.setFillColor(theme.caretColor.cgColor)
                ctx.fill(CGRect(x: caretX, y: rowY + 2, width: 2.0, height: lineHeight - 4))

                if !ghostText.isEmpty {
                    let firstGhostLine = ghostText.components(separatedBy: "\n").first ?? ghostText
                    let ghostAttr = NSAttributedString(
                        string: firstGhostLine + "  [Tab]",
                        attributes: [
                            .font: editorFont,
                            .foregroundColor: theme.ghostTextColor
                        ]
                    )
                    drawCoreTextLine(ghostAttr, in: ctx, x: caretX + 2, y: rowY + fontAscent + 1.0)
                }
            }
        }
    }

    private func computeVisibleLines() -> [Int] {
        let total = buffer.lineCount
        guard foldErrorBlocks else {
            return Array(0..<total)
        }
        var lines: [Int] = []
        var line = 0
        while line < total {
            lines.append(line)
            if let block = astAnalysis.errorHandlingBlocks.first(where: { $0.lowerBound == line && $0.count > 1 }) {
                line = block.upperBound + 1
            } else {
                line += 1
            }
        }
        return lines
    }

    private func drawCoreTextLine(_ attrString: NSAttributedString, in ctx: CGContext, x: CGFloat, y: CGFloat) {
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1.0, y: -1.0)
        ctx.textPosition = CGPoint(x: x, y: y)
        let ctLine = CTLineCreateWithAttributedString(attrString)
        CTLineDraw(ctLine, ctx)
        ctx.restoreGState()
    }

    private func drawLineNumber(in ctx: CGContext, docLine: Int, rowY: CGFloat) {
        let numStr = "\(docLine + 1)"
        let isCurrent = docLine == cursorPosition.line
        let color = isCurrent ? NSColor.white : highlighter.theme.gutterText
        let attr = NSAttributedString(
            string: numStr,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: isCurrent ? .semibold : .regular),
                .foregroundColor: color
            ]
        )
        let size = attr.size()
        let x = gutterWidth - size.width - 10
        drawCoreTextLine(attr, in: ctx, x: max(4, x), y: rowY + fontAscent)
    }

    private func drawSelectionHighlight(in ctx: CGContext, docLine: Int, rowY: CGFloat, selection: TextRange) {
        guard docLine >= selection.start.line && docLine <= selection.end.line else { return }
        let lineLen = buffer.lineCharacterRange(at: docLine).count
        let startCol = (docLine == selection.start.line) ? selection.start.column : 0
        let endCol = (docLine == selection.end.line) ? selection.end.column : max(1, lineLen)
        guard endCol > startCol else { return }

        let x = gutterWidth + textLeftPadding + CGFloat(startCol) * charAdvance
        let w = CGFloat(endCol - startCol) * charAdvance
        ctx.setFillColor(highlighter.theme.selectionBackground.cgColor)
        ctx.fill(CGRect(x: x, y: rowY, width: w, height: lineHeight))
    }

    @discardableResult
    private func drawBadge(
        text: String,
        at origin: CGPoint,
        backgroundColor: NSColor,
        textColor: NSColor
    ) -> CGRect {
        let badgeFont = NSFont.monospacedSystemFont(ofSize: 11.0, weight: .medium)
        let attr = NSAttributedString(
            string: text,
            attributes: [
                .font: badgeFont,
                .foregroundColor: textColor
            ]
        )
        let textSize = attr.size()
        let rect = CGRect(
            x: origin.x,
            y: origin.y,
            width: ceil(textSize.width) + 12,
            height: lineHeight - 6
        )
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        backgroundColor.setFill()
        path.fill()

        if let ctx = NSGraphicsContext.current?.cgContext {
            drawCoreTextLine(attr, in: ctx, x: rect.minX + 6, y: rect.minY + fontAscent - 3)
        }
        return rect
    }

    public func currentSelectionRange() -> TextRange? {
        guard let anchor = selectionAnchor, anchor != cursorPosition else { return nil }
        return TextRange(start: anchor, end: cursorPosition)
    }

    private func textPosition(for viewPoint: CGPoint) -> TextPosition {
        let visible = computeVisibleLines()
        guard !visible.isEmpty else { return .zero }
        let rowIdx = max(0, min(Int(floor(viewPoint.y / lineHeight)), visible.count - 1))
        let docLine = visible[rowIdx]
        let lineLen = buffer.lineCharacterRange(at: docLine).count
        let rawCol = Int(round((viewPoint.x - gutterWidth - textLeftPadding) / charAdvance))
        let col = max(0, min(rawCol, lineLen))
        return TextPosition(line: docLine, column: col)
    }

    override public func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let pt = convert(event.locationInWindow, from: nil)

        for hit in testButtonHitRects where hit.rect.contains(pt) {
            onRunGoTestRequested?(hit.funcEntry)
            return
        }

        let pos = textPosition(for: pt)
        if event.modifierFlags.contains(.command) {
            cursorPosition = pos
            onDefinitionRequested?(pos)
            return
        }

        ghostText = ""
        if event.modifierFlags.contains(.shift) {
            if selectionAnchor == nil { selectionAnchor = cursorPosition }
            cursorPosition = pos
        } else {
            selectionAnchor = pos
            cursorPosition = pos
        }
    }

    override public func mouseDragged(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        cursorPosition = textPosition(for: pt)
    }

    override public func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags.contains(.command) {
            if event.charactersIgnoringModifiers?.lowercased() == "z" {
                if flags.contains(.shift) {
                    if let pos = buffer.redo() {
                        cursorPosition = pos
                        selectionAnchor = nil
                        notifyBufferDidMutate()
                    }
                } else {
                    if let pos = buffer.undo() {
                        cursorPosition = pos
                        selectionAnchor = nil
                        notifyBufferDidMutate()
                    }
                }
                return
            }
            if event.charactersIgnoringModifiers?.lowercased() == "r" && flags.contains(.shift) {
                onRenameRequested?(cursorPosition)
                return
            }
        }

        switch event.keyCode {
        case 48:
            if !ghostText.isEmpty {
                let accepted = ghostText
                ghostText = ""
                insertUserText(accepted)
            } else {
                insertUserText("\t")
            }
        case 51:
            handleBackspace()
        case 36, 76:
            handleReturnKey()
        case 123:
            moveCursorHorizontally(delta: -1, extendSelection: flags.contains(.shift))
        case 124:
            moveCursorHorizontally(delta: 1, extendSelection: flags.contains(.shift))
        case 125:
            moveCursorVertically(delta: 1, extendSelection: flags.contains(.shift))
        case 126:
            moveCursorVertically(delta: -1, extendSelection: flags.contains(.shift))
        case 53:
            ghostText = ""
            selectionAnchor = nil
            completionCoordinator.cancelCurrentRequest()
            needsDisplay = true
        default:
            if let chars = event.characters, !chars.isEmpty, !flags.contains(.command), !flags.contains(.control) {
                insertUserText(chars)
            }
        }
    }

    public func insertUserText(_ text: String) {
        ghostText = ""
        completionCoordinator.cancelCurrentRequest()

        if let sel = currentSelectionRange() {
            cursorPosition = buffer.replace(textRange: sel, with: text)
            selectionAnchor = nil
        } else {
            let offset = buffer.characterOffset(for: cursorPosition)
            cursorPosition = buffer.insert(text, at: offset)
        }

        notifyBufferDidMutate()
        completionCoordinator.scheduleCompletion(
            buffer: buffer,
            cursor: cursorPosition,
            filePath: filePath,
            astAnalysis: astAnalysis
        ) { [weak self] streamedGhost in
            self?.ghostText = streamedGhost
        }
    }

    private func handleBackspace() {
        ghostText = ""
        completionCoordinator.cancelCurrentRequest()

        if let sel = currentSelectionRange() {
            cursorPosition = buffer.replace(textRange: sel, with: "")
            selectionAnchor = nil
            notifyBufferDidMutate()
            return
        }

        let offset = buffer.characterOffset(for: cursorPosition)
        guard offset > 0 else { return }
        cursorPosition = buffer.delete(in: (offset - 1)..<offset)
        notifyBufferDidMutate()
    }

    private func handleReturnKey() {
        let currentLineStr = buffer.lineContent(at: cursorPosition.line)
        let leadingTabs = currentLineStr.prefix(while: { $0 == "\t" || $0 == " " })
        let trimmed = currentLineStr.trimmingCharacters(in: .whitespaces)
        let extraTab = trimmed.hasSuffix("{") ? "\t" : ""
        insertUserText("\n" + leadingTabs + extraTab)
    }

    private func moveCursorHorizontally(delta: Int, extendSelection: Bool) {
        ghostText = ""
        if extendSelection && selectionAnchor == nil {
            selectionAnchor = cursorPosition
        } else if !extendSelection {
            selectionAnchor = nil
        }
        let nextOffset = max(0, min(buffer.count, buffer.characterOffset(for: cursorPosition) + delta))
        cursorPosition = buffer.position(forCharacterOffset: nextOffset)
    }

    private func moveCursorVertically(delta: Int, extendSelection: Bool) {
        ghostText = ""
        if extendSelection && selectionAnchor == nil {
            selectionAnchor = cursorPosition
        } else if !extendSelection {
            selectionAnchor = nil
        }
        let visible = computeVisibleLines()
        guard !visible.isEmpty else { return }
        let currentVisualIdx = visible.firstIndex(where: { $0 >= cursorPosition.line }) ?? (visible.count - 1)
        let targetVisualIdx = max(0, min(visible.count - 1, currentVisualIdx + delta))
        let targetLine = visible[targetVisualIdx]
        let maxCol = buffer.lineCharacterRange(at: targetLine).count
        cursorPosition = TextPosition(line: targetLine, column: min(cursorPosition.column, maxCol))
    }

    private func notifyBufferDidMutate() {
        rebuildAnalysesAndRedraw()
        onBufferModified?(buffer)
    }
}

public struct GoEditorCanvasRepresentable: NSViewRepresentable {
    public let buffer: TextBuffer
    public let filePath: String
    public let diagnostics: [LSPDiagnostic]
    public let inlineTestResults: [Int: GoTestRunResult]
    public let foldErrorBlocks: Bool
    public let dimErrorBlocks: Bool
    public var onBufferModified: ((TextBuffer) -> Void)?
    public var onCursorChanged: ((TextPosition) -> Void)?
    public var onRunGoTestRequested: ((GoASTAnalysis.FuncEntry) -> Void)?
    public var onDefinitionRequested: ((TextPosition) -> Void)?
    public var onRenameRequested: ((TextPosition) -> Void)?

    public init(
        buffer: TextBuffer,
        filePath: String,
        diagnostics: [LSPDiagnostic] = [],
        inlineTestResults: [Int: GoTestRunResult] = [:],
        foldErrorBlocks: Bool = false,
        dimErrorBlocks: Bool = true,
        onBufferModified: ((TextBuffer) -> Void)? = nil,
        onCursorChanged: ((TextPosition) -> Void)? = nil,
        onRunGoTestRequested: ((GoASTAnalysis.FuncEntry) -> Void)? = nil,
        onDefinitionRequested: ((TextPosition) -> Void)? = nil,
        onRenameRequested: ((TextPosition) -> Void)? = nil
    ) {
        self.buffer = buffer
        self.filePath = filePath
        self.diagnostics = diagnostics
        self.inlineTestResults = inlineTestResults
        self.foldErrorBlocks = foldErrorBlocks
        self.dimErrorBlocks = dimErrorBlocks
        self.onBufferModified = onBufferModified
        self.onCursorChanged = onCursorChanged
        self.onRunGoTestRequested = onRunGoTestRequested
        self.onDefinitionRequested = onDefinitionRequested
        self.onRenameRequested = onRenameRequested
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = GoTheme().background

        let editor = EditorView(buffer: buffer, frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        editor.autoresizingMask = [.width]
        scrollView.documentView = editor
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let editor = scrollView.documentView as? EditorView else { return }
        if editor.buffer !== buffer {
            editor.buffer = buffer
        }
        editor.filePath = filePath
        editor.diagnostics = diagnostics
        editor.inlineTestResults = inlineTestResults
        editor.foldErrorBlocks = foldErrorBlocks
        editor.dimErrorBlocks = dimErrorBlocks
        editor.onBufferModified = onBufferModified
        editor.onCursorChanged = onCursorChanged
        editor.onRunGoTestRequested = onRunGoTestRequested
        editor.onDefinitionRequested = onDefinitionRequested
        editor.onRenameRequested = onRenameRequested
    }
}
