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
    public var onRunMainRequested: (() -> Void)?
    public var onDefinitionRequested: ((TextPosition) -> Void)?
    public var onRenameRequested: ((TextPosition) -> Void)?
    public var onToggleTerminalRequested: (() -> Void)?
    public var onSaveRequested: (() -> Void)?
    public var onOpenFileRequested: (() -> Void)?
    public var onStatusMessage: ((String) -> Void)?

    public var editorFont: NSFont = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular) {
        didSet { computeFontMetrics() }
    }
    private(set) var lineHeight: CGFloat = 21.0
    private(set) var charAdvance: CGFloat = 8.2
    private(set) var fontAscent: CGFloat = 15.0
    private let gutterWidth: CGFloat = 68.0
    private let textLeftPadding: CGFloat = 12.0

    public private(set) var astAnalysis = GoASTAnalysis(
        packageName: "main",
        importsBlock: "",
        functions: [],
        types: [],
        errorHandlingBlocks: [],
        implicitInterfaceImpls: [:]
    )

    private enum BadgeAction {
        case runTest(GoASTAnalysis.FuncEntry)
        case runMain
        case jumpToSymbol(String)
        case generateStructTags(GoASTAnalysis.TypeEntry)
        case generateTableTest(GoASTAnalysis.FuncEntry)
    }

    private var badgeHitRects: [(rect: CGRect, action: BadgeAction)] = []

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
        badgeHitRects.removeAll()
        guard !visibleLines.isEmpty else { return }

        let firstVisualRow = max(0, Int(floor(dirtyRect.minY / lineHeight)))
        let lastVisualRow = min(visibleLines.count - 1, Int(ceil(dirtyRect.maxY / lineHeight)))
        guard firstVisualRow <= lastVisualRow else { return }

        for visualRow in firstVisualRow...lastVisualRow {
            let docLine = visibleLines[visualRow]
            let rowY = CGFloat(visualRow) * lineHeight

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

            if let impls = astAnalysis.implicitInterfaceImpls[docLine], let firstIface = impls.first {
                let label = "⇄ implements " + impls.joined(separator: ", ")
                let r = drawBadge(
                    text: label,
                    at: CGPoint(x: badgeX, y: rowY + 3),
                    backgroundColor: NSColor(calibratedRed: 0.05, green: 0.30, blue: 0.38, alpha: 0.88),
                    textColor: NSColor(calibratedRed: 0.45, green: 0.92, blue: 1.0, alpha: 1.0)
                )
                badgeHitRects.append((rect: r, action: .jumpToSymbol(firstIface)))
                badgeX = r.maxX + 8
            }

            if let implementors = astAnalysis.interfaceImplementors[docLine], let firstStruct = implementors.first {
                let label = "⇣ implemented by " + implementors.joined(separator: ", ")
                let r = drawBadge(
                    text: label,
                    at: CGPoint(x: badgeX, y: rowY + 3),
                    backgroundColor: NSColor(calibratedRed: 0.22, green: 0.16, blue: 0.40, alpha: 0.88),
                    textColor: NSColor(calibratedRed: 0.80, green: 0.70, blue: 1.0, alpha: 1.0)
                )
                badgeHitRects.append((rect: r, action: .jumpToSymbol(firstStruct)))
                badgeX = r.maxX + 8
            }

            if let structType = astAnalysis.types.first(where: { $0.startLine == docLine && $0.kind == "struct" }) {
                let tagRect = drawBadge(
                    text: "🏷 +json tags",
                    at: CGPoint(x: badgeX, y: rowY + 3),
                    backgroundColor: NSColor(calibratedRed: 0.32, green: 0.24, blue: 0.10, alpha: 0.88),
                    textColor: NSColor(calibratedRed: 0.98, green: 0.82, blue: 0.48, alpha: 1.0)
                )
                badgeHitRects.append((rect: tagRect, action: .generateStructTags(structType)))
                badgeX = tagRect.maxX + 8
            }

            if let fn = astAnalysis.functions.first(where: { $0.startLine == docLine }) {
                if fn.isTest || fn.isBenchmark {
                    let btnTitle = fn.isBenchmark ? "▶ Bench" : "▶ Run Test"
                    let btnRect = drawBadge(
                        text: btnTitle,
                        at: CGPoint(x: badgeX, y: rowY + 3),
                        backgroundColor: NSColor(calibratedRed: 0.14, green: 0.38, blue: 0.24, alpha: 0.95),
                        textColor: NSColor(calibratedRed: 0.65, green: 0.98, blue: 0.75, alpha: 1.0)
                    )
                    badgeHitRects.append((rect: btnRect, action: .runTest(fn)))
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
                } else if fn.isMain {
                    let runMainRect = drawBadge(
                        text: "▶ Run main",
                        at: CGPoint(x: badgeX, y: rowY + 3),
                        backgroundColor: NSColor(calibratedRed: 0.12, green: 0.40, blue: 0.28, alpha: 0.95),
                        textColor: NSColor(calibratedRed: 0.60, green: 0.98, blue: 0.80, alpha: 1.0)
                    )
                    badgeHitRects.append((rect: runMainRect, action: .runMain))
                    badgeX = runMainRect.maxX + 8
                } else {
                    let genTestRect = drawBadge(
                        text: "🧪 +Table Test",
                        at: CGPoint(x: badgeX, y: rowY + 3),
                        backgroundColor: NSColor(calibratedRed: 0.14, green: 0.24, blue: 0.38, alpha: 0.85),
                        textColor: NSColor(calibratedRed: 0.68, green: 0.86, blue: 1.0, alpha: 1.0)
                    )
                    badgeHitRects.append((rect: genTestRect, action: .generateTableTest(fn)))
                    badgeX = genTestRect.maxX + 8
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

                if let postfixCandidate = GoPostfixCompletionEngine.matchCandidate(in: buffer, at: cursorPosition) {
                    _ = drawBadge(
                        text: "⚡ Postfix [Tab]: \(postfixCandidate.previewLabel)",
                        at: CGPoint(x: max(badgeX, caretX + 10), y: rowY + 3),
                        backgroundColor: NSColor(calibratedRed: 0.08, green: 0.34, blue: 0.36, alpha: 0.95),
                        textColor: NSColor(calibratedRed: 0.35, green: 0.96, blue: 0.88, alpha: 1.0)
                    )
                } else if !ghostText.isEmpty {
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

        for hit in badgeHitRects where hit.rect.contains(pt) {
            switch hit.action {
            case .runTest(let fn):
                onRunGoTestRequested?(fn)
            case .runMain:
                onRunMainRequested?()
            case .jumpToSymbol(let symbol):
                jumpToSymbol(named: symbol)
            case .generateStructTags(let structEntry):
                applyStructTags(for: structEntry, style: .jsonSnake)
            case .generateTableTest(let fn):
                generateTableTest(for: fn)
            }
            return
        }

        let pos = textPosition(for: pt)
        if event.modifierFlags.contains(.command) {
            cursorPosition = pos
            jumpToSymbolAtCursor()
            onDefinitionRequested?(pos)
            return
        }

        ghostText = ""
        if event.clickCount >= 3 {
            let lineLen = buffer.lineCharacterRange(at: pos.line).count
            selectionAnchor = TextPosition(line: pos.line, column: 0)
            cursorPosition = TextPosition(line: pos.line, column: lineLen)
            return
        } else if event.clickCount == 2 {
            let wordRange = wordRange(at: pos)
            selectionAnchor = wordRange.start
            cursorPosition = wordRange.end
            return
        }

        if event.modifierFlags.contains(.shift) {
            if selectionAnchor == nil { selectionAnchor = cursorPosition }
            cursorPosition = pos
        } else {
            selectionAnchor = pos
            cursorPosition = pos
        }
    }

    private func wordRange(at pos: TextPosition) -> TextRange {
        let lineChars = Array(buffer.lineContent(at: pos.line))
        guard !lineChars.isEmpty else { return TextRange(start: pos, end: pos) }
        let idx = min(max(0, pos.column), lineChars.count - 1)
        let isWordChar: (Character) -> Bool = { $0.isLetter || $0.isNumber || $0 == "_" }
        guard isWordChar(lineChars[idx]) else {
            return TextRange(start: pos, end: TextPosition(line: pos.line, column: min(lineChars.count, idx + 1)))
        }
        var startCol = idx
        while startCol > 0 && isWordChar(lineChars[startCol - 1]) {
            startCol -= 1
        }
        var endCol = idx + 1
        while endCol < lineChars.count && isWordChar(lineChars[endCol]) {
            endCol += 1
        }
        return TextRange(
            start: TextPosition(line: pos.line, column: startCol),
            end: TextPosition(line: pos.line, column: endCol)
        )
    }

    override public func mouseDragged(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        cursorPosition = textPosition(for: pt)
    }

    override public func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags.contains(.option) && flags.contains(.shift) {
            if event.keyCode == 126 {
                moveCurrentLine(delta: -1)
                return
            } else if event.keyCode == 125 {
                moveCurrentLine(delta: 1)
                return
            }
        }

        if flags.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "z":
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
            case "r" where flags.contains(.shift):
                onRenameRequested?(cursorPosition)
                return
            case "t" where flags.contains(.shift):
                generateStructTagsAtCursor(style: .jsonSnake)
                return
            case "g" where flags.contains(.shift):
                generateTableTestAtCursor()
                return
            case "b":
                jumpToSymbolAtCursor()
                onDefinitionRequested?(cursorPosition)
                return
            case "d":
                duplicateSelectionOrLine()
                return
            case "c":
                copySelectionOrLine()
                return
            case "x":
                cutSelectionOrLine()
                return
            case "v":
                pasteFromClipboard()
                return
            case "a":
                selectAllDocument()
                return
            case "/":
                toggleLineComment()
                return
            case "j":
                onToggleTerminalRequested?()
                return
            case "s":
                onSaveRequested?()
                return
            case "o":
                onOpenFileRequested?()
                return
            default:
                break
            }
        }

        switch event.keyCode {
        case 48:
            if let candidate = GoPostfixCompletionEngine.matchCandidate(in: buffer, at: cursorPosition),
               let expandedPos = GoPostfixCompletionEngine.tryExpand(in: buffer, at: cursorPosition) {
                ghostText = ""
                selectionAnchor = nil
                cursorPosition = expandedPos
                notifyBufferDidMutate()
                onStatusMessage?("⚡ Postfix expanded `.\(candidate.key)` → `\(candidate.previewLabel)`")
            } else if !ghostText.isEmpty {
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
                handleTypedCharacters(chars)
            }
        }
    }

    public func jumpToSymbolAtCursor() {
        let range = wordRange(at: cursorPosition)
        let startOff = buffer.characterOffset(for: range.start)
        let endOff = buffer.characterOffset(for: range.end)
        let word = buffer.substring(in: startOff..<endOff).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        jumpToSymbol(named: word)
    }

    public func jumpToSymbol(named symbol: String) {
        guard let targetLine = GoSymbolNavigator.findDeclarationLine(forSymbol: symbol, in: astAnalysis) else {
            onStatusMessage?("Symbol `\(symbol)` not found in current file.")
            return
        }
        jumpToLine(targetLine)
        onStatusMessage?("Jumped to `\(symbol)` (Ln \(targetLine + 1)).")
    }

    public func jumpToLine(_ line: Int) {
        let clamped = max(0, min(buffer.lineCount - 1, line))
        selectionAnchor = nil
        cursorPosition = TextPosition(line: clamped, column: 0)
        let targetY = max(0, CGFloat(clamped - 3) * lineHeight)
        scroll(CGPoint(x: 0, y: targetY))
        needsDisplay = true
    }

    public func generateStructTagsAtCursor(style: GoStructTagStyle = .jsonSnake) {
        guard let structEntry = GoStructTagGenerator.enclosingStruct(in: astAnalysis, atLine: cursorPosition.line) else {
            onStatusMessage?("No Go struct found in current file.")
            return
        }
        applyStructTags(for: structEntry, style: style)
    }

    public func applyStructTags(for structEntry: GoASTAnalysis.TypeEntry, style: GoStructTagStyle) {
        let count = GoStructTagGenerator.applyStructTags(in: buffer, structEntry: structEntry, style: style)
        notifyBufferDidMutate()
        onStatusMessage?("Generated \(style.rawValue) tags for \(count) fields on `type \(structEntry.name) struct`.")
    }

    public func generateTableTestAtCursor() {
        guard let fn = GoTableTestGenerator.targetFunction(in: astAnalysis, atLine: cursorPosition.line) else {
            onStatusMessage?("No target Go function found to generate a table test.")
            return
        }
        generateTableTest(for: fn)
    }

    public func generateTableTest(for fn: GoASTAnalysis.FuncEntry) {
        let outcome = GoTableTestGenerator.appendOrLocateTableTest(for: fn, in: buffer, analysis: astAnalysis)
        notifyBufferDidMutate()
        jumpToLine(outcome.position.line)
        if outcome.created {
            onStatusMessage?("Generated GoLand Table-Driven Test `\(outcome.testName)` for `\(fn.name)`.")
        } else {
            onStatusMessage?("Jumped to existing test `\(outcome.testName)` (Ln \(outcome.position.line + 1)).")
        }
    }

    public func duplicateSelectionOrLine() {
        if let sel = currentSelectionRange() {
            let startOff = buffer.characterOffset(for: sel.start)
            let endOff = buffer.characterOffset(for: sel.end)
            let slice = buffer.substring(in: startOff..<endOff)
            cursorPosition = buffer.insert(slice, at: endOff)
            selectionAnchor = nil
        } else {
            let lineText = buffer.lineContent(at: cursorPosition.line)
            let lineRange = buffer.lineCharacterRange(at: cursorPosition.line)
            _ = buffer.insert("\n" + lineText, at: lineRange.upperBound)
            cursorPosition = TextPosition(line: cursorPosition.line + 1, column: cursorPosition.column)
        }
        notifyBufferDidMutate()
        onStatusMessage?("Duplicated line (⌘D).")
    }

    public func moveCurrentLine(delta: Int) {
        let line = cursorPosition.line
        let targetLine = line + delta
        guard targetLine >= 0 && targetLine < buffer.lineCount else { return }

        let currentText = buffer.lineContent(at: line)
        let neighborText = buffer.lineContent(at: targetLine)
        let col = cursorPosition.column

        let firstLine = min(line, targetLine)
        let secondLine = max(line, targetLine)
        let startOff = buffer.lineCharacterRange(at: firstLine).lowerBound
        let endOff = buffer.lineCharacterRange(at: secondLine).upperBound

        let replacement = (delta < 0)
            ? "\(currentText)\n\(neighborText)"
            : "\(neighborText)\n\(currentText)"

        _ = buffer.replace(range: startOff..<endOff, with: replacement)
        cursorPosition = TextPosition(line: targetLine, column: min(col, currentText.count))
        selectionAnchor = nil
        notifyBufferDidMutate()
    }

    private func handleTypedCharacters(_ chars: String) {
        if currentSelectionRange() == nil {
            let pairs: [String: String] = ["{": "}", "(": ")", "[": "]", "\"": "\""]
            if let closing = pairs[chars] {
                let offset = buffer.characterOffset(for: cursorPosition)
                _ = buffer.insert(chars + closing, at: offset)
                cursorPosition = buffer.position(forCharacterOffset: offset + 1)
                notifyBufferDidMutate()
                return
            }
        }
        insertUserText(chars)
    }

    public func copySelectionOrLine() {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let sel = currentSelectionRange() {
            let startOff = buffer.characterOffset(for: sel.start)
            let endOff = buffer.characterOffset(for: sel.end)
            pb.setString(buffer.substring(in: startOff..<endOff), forType: .string)
        } else {
            let lineText = buffer.lineContent(at: cursorPosition.line) + "\n"
            pb.setString(lineText, forType: .string)
        }
    }

    public func cutSelectionOrLine() {
        copySelectionOrLine()
        if let sel = currentSelectionRange() {
            cursorPosition = buffer.replace(textRange: sel, with: "")
            selectionAnchor = nil
            notifyBufferDidMutate()
        } else {
            let lineRange = buffer.lineCharacterRange(at: cursorPosition.line)
            let endBound = min(buffer.count, lineRange.upperBound + 1)
            cursorPosition = buffer.delete(in: lineRange.lowerBound..<endBound)
            notifyBufferDidMutate()
        }
    }

    public func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        insertUserText(text)
    }

    public func selectAllDocument() {
        selectionAnchor = .zero
        cursorPosition = buffer.position(forCharacterOffset: buffer.count)
    }

    public func toggleLineComment() {
        let range = currentSelectionRange() ?? TextRange(start: cursorPosition, end: cursorPosition)
        for line in range.start.line...range.end.line {
            let content = buffer.lineContent(at: line)
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            let lineCharRange = buffer.lineCharacterRange(at: line)
            if trimmed.hasPrefix("// ") {
                let updated = content.replacingOccurrences(of: "// ", with: "", options: [], range: content.range(of: "// "))
                _ = buffer.replace(range: lineCharRange, with: updated)
            } else if trimmed.hasPrefix("//") {
                let updated = content.replacingOccurrences(of: "//", with: "", options: [], range: content.range(of: "//"))
                _ = buffer.replace(range: lineCharRange, with: updated)
            } else {
                _ = buffer.insert("// ", at: lineCharRange.lowerBound)
            }
        }
        notifyBufferDidMutate()
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
        let leadingTabs = String(currentLineStr.prefix(while: { $0 == "\t" || $0 == " " }))
        let offset = buffer.characterOffset(for: cursorPosition)
        let prevChar = offset > 0 ? buffer.substring(in: (offset - 1)..<offset) : ""
        let nextChar = offset < buffer.count ? buffer.substring(in: offset..<(offset + 1)) : ""

        if prevChar == "{" && nextChar == "}" {
            let innerIndent = leadingTabs + "\t"
            let expansion = "\n" + innerIndent + "\n" + leadingTabs
            _ = buffer.insert(expansion, at: offset)
            cursorPosition = buffer.position(forCharacterOffset: offset + 1 + innerIndent.count)
            notifyBufferDidMutate()
            return
        }

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
    public let requestedJumpLine: Int?
    public var onBufferModified: ((TextBuffer) -> Void)?
    public var onCursorChanged: ((TextPosition) -> Void)?
    public var onRunGoTestRequested: ((GoASTAnalysis.FuncEntry) -> Void)?
    public var onRunMainRequested: (() -> Void)?
    public var onDefinitionRequested: ((TextPosition) -> Void)?
    public var onRenameRequested: ((TextPosition) -> Void)?
    public var onToggleTerminalRequested: (() -> Void)?
    public var onSaveRequested: (() -> Void)?
    public var onOpenFileRequested: (() -> Void)?
    public var onStatusMessage: ((String) -> Void)?

    public init(
        buffer: TextBuffer,
        filePath: String,
        diagnostics: [LSPDiagnostic] = [],
        inlineTestResults: [Int: GoTestRunResult] = [:],
        foldErrorBlocks: Bool = false,
        dimErrorBlocks: Bool = true,
        requestedJumpLine: Int? = nil,
        onBufferModified: ((TextBuffer) -> Void)? = nil,
        onCursorChanged: ((TextPosition) -> Void)? = nil,
        onRunGoTestRequested: ((GoASTAnalysis.FuncEntry) -> Void)? = nil,
        onRunMainRequested: (() -> Void)? = nil,
        onDefinitionRequested: ((TextPosition) -> Void)? = nil,
        onRenameRequested: ((TextPosition) -> Void)? = nil,
        onToggleTerminalRequested: (() -> Void)? = nil,
        onSaveRequested: (() -> Void)? = nil,
        onOpenFileRequested: (() -> Void)? = nil,
        onStatusMessage: ((String) -> Void)? = nil
    ) {
        self.buffer = buffer
        self.filePath = filePath
        self.diagnostics = diagnostics
        self.inlineTestResults = inlineTestResults
        self.foldErrorBlocks = foldErrorBlocks
        self.dimErrorBlocks = dimErrorBlocks
        self.requestedJumpLine = requestedJumpLine
        self.onBufferModified = onBufferModified
        self.onCursorChanged = onCursorChanged
        self.onRunGoTestRequested = onRunGoTestRequested
        self.onRunMainRequested = onRunMainRequested
        self.onDefinitionRequested = onDefinitionRequested
        self.onRenameRequested = onRenameRequested
        self.onToggleTerminalRequested = onToggleTerminalRequested
        self.onSaveRequested = onSaveRequested
        self.onOpenFileRequested = onOpenFileRequested
        self.onStatusMessage = onStatusMessage
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
        editor.onRunMainRequested = onRunMainRequested
        editor.onDefinitionRequested = onDefinitionRequested
        editor.onRenameRequested = onRenameRequested
        editor.onToggleTerminalRequested = onToggleTerminalRequested
        editor.onSaveRequested = onSaveRequested
        editor.onOpenFileRequested = onOpenFileRequested
        editor.onStatusMessage = onStatusMessage

        if let jumpLine = requestedJumpLine, editor.cursorPosition.line != jumpLine {
            editor.jumpToLine(jumpLine)
        }
    }
}
