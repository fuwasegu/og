import AppKit
import OgCore

/// The editing surface: NSTextView (TextKit 1) with Go-aware editing commands.
/// IME, undo, and the find bar come from AppKit.
@MainActor
final class CodeTextView: NSTextView {
    weak var controller: EditorController?
    /// Ghost text (local AI suggestion) drawn after the caret.
    var ghostText: String? { didSet { if ghostText != oldValue { needsDisplay = true } } }
    var ghostLocation: Int = 0
    var currentLineColor: NSColor = Theme.currentLine
    var debugLine: Int? { didSet { needsDisplay = true } }
    private var trackingAreaRef: NSTrackingArea?
    private var selectionStack: [NSRange] = []

    static let pairs: [String: String] = ["(": ")", "[": "]", "{": "}", "\"": "\"", "`": "`", "'": "'"]

    // MARK: - Drawing

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let lm = layoutManager, let tc = textContainer else { return }
        if let line = debugLine, let r = lineRect(forLine: line) {
            Theme.debugLine.setFill()
            NSRect(x: 0, y: r.minY, width: bounds.width, height: r.height).fill()
        }
        let sel = selectedRange()
        guard sel.length == 0 else { return }
        let length = (string as NSString).length
        let caret = min(sel.location, length)
        var rectLine: NSRect
        if length == 0 || (caret == length && (string as NSString).character(at: length - 1) == 10) {
            rectLine = lm.extraLineFragmentRect
        } else {
            let glyph = lm.glyphIndexForCharacter(at: min(caret, max(0, length - 1)))
            rectLine = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        if rectLine.height == 0 { rectLine.size.height = Theme.editorFont.ascender - Theme.editorFont.descender + 4 }
        rectLine.origin.x = 0
        rectLine.origin.y += textContainerOrigin.y
        rectLine.size.width = bounds.width
        _ = tc
        currentLineColor.setFill()
        rectLine.intersection(rect).fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ghost = ghostText, !ghost.isEmpty, let lm = layoutManager else { return }
        let length = (string as NSString).length
        guard ghostLocation <= length else { return }
        var point: NSPoint
        if length == 0 {
            point = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height)
        } else {
            let glyph = lm.glyphIndexForCharacter(at: min(ghostLocation, length - 1))
            var lineRect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let loc = lm.location(forGlyphAt: glyph)
            if ghostLocation >= length {
                let bounding = lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer!)
                point = NSPoint(x: bounding.maxX, y: lineRect.minY)
            } else {
                point = NSPoint(x: lineRect.minX + loc.x, y: lineRect.minY)
            }
            lineRect.origin.y += textContainerOrigin.y
            point.x += textContainerOrigin.x
            point.y = lineRect.minY
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.editorFont, .foregroundColor: Theme.secondaryText.withAlphaComponent(0.8)]
        let lines = ghost.components(separatedBy: "\n")
        let lineHeight = lm.defaultLineHeight(for: Theme.editorFont)
        for (i, l) in lines.enumerated() {
            let x = i == 0 ? point.x : textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0)
            (l as NSString).draw(at: NSPoint(x: x, y: point.y + CGFloat(i) * lineHeight), withAttributes: attrs)
        }
    }

    func lineRect(forLine line: Int) -> NSRect? {
        guard let lm = layoutManager else { return nil }
        let lines = TextLines(nsString: string as NSString)
        guard line >= 0, line < lines.lineCount else { return nil }
        let r = lines.lineRange(line)
        if r.location >= (string as NSString).length {
            var e = lm.extraLineFragmentRect
            e.origin.y += textContainerOrigin.y
            return e
        }
        let glyph = lm.glyphIndexForCharacter(at: r.location)
        var rect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        rect.origin.y += textContainerOrigin.y
        return rect
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        needsDisplay = true
        if !stillSelecting { controller?.selectionDidChange() }
    }

    // MARK: - Keys

    override func keyDown(with event: NSEvent) {
        if controller?.handlePopupKey(event) == true { return }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53 { // Esc
            if ghostText != nil { controller?.dismissGhost(); return }
            if controller?.dismissTransientUI() == true { return }
        }
        if event.keyCode == 48 && mods.isEmpty { // Tab
            if controller?.handleTab() == true { return }
        }
        super.keyDown(with: event)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard let s = insertString as? String, !hasMarkedText() else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        let ns = string as NSString
        let sel = selectedRange()
        // Type-over closing characters.
        if s.count == 1, [")", "]", "}", "\"", "`", "'"].contains(s), sel.length == 0, sel.location < ns.length,
           ns.substring(with: NSRange(location: sel.location, length: 1)) == s {
            setSelectedRange(NSRange(location: sel.location + 1, length: 0))
            controller?.textTyped(s)
            return
        }
        // Auto-pair.
        if let close = Self.pairs[s], shouldAutoPair(s, at: sel, in: ns) {
            if sel.length > 0 {
                let inner = ns.substring(with: sel)
                insertReplacing(sel, with: s + inner + close, caret: sel.location + 1 + (inner as NSString).length, selectLength: 0)
            } else {
                insertReplacing(sel, with: s + close, caret: sel.location + 1)
            }
            controller?.textTyped(s)
            return
        }
        // Dedent a lone closing brace.
        if s == "}" && sel.length == 0 {
            let lines = TextLines(nsString: ns)
            let line = lines.line(forOffset: sel.location)
            let lr = lines.lineRange(line)
            let before = ns.substring(with: NSRange(location: lr.location, length: sel.location - lr.location))
            if !before.isEmpty && before.trimmingCharacters(in: .whitespaces).isEmpty {
                let indent = matchingIndent(forCloseAt: sel.location, in: ns)
                insertReplacing(NSRange(location: lr.location, length: sel.location - lr.location), with: indent + "}", caret: lr.location + (indent as NSString).length + 1)
                controller?.textTyped(s)
                return
            }
        }
        super.insertText(insertString, replacementRange: replacementRange)
        controller?.textTyped(s)
    }

    private func shouldAutoPair(_ s: String, at sel: NSRange, in ns: NSString) -> Bool {
        let next: unichar = sel.location + sel.length < ns.length ? ns.character(at: sel.location + sel.length) : 10
        let nextOK = next == 10 || next == 32 || next == 9 || next == 41 || next == 93 || next == 125 || next == 44 || next == 59
        if s == "\"" || s == "'" || s == "`" {
            let prev: unichar = sel.location > 0 ? ns.character(at: sel.location - 1) : 32
            let prevIsWord = CharacterSet.alphanumerics.contains(UnicodeScalar(prev) ?? " ")
            if prevIsWord { return false }
            if controller?.isInsideStringOrComment(sel.location) == true { return false }
        }
        return sel.length > 0 || nextOK
    }

    override func deleteBackward(_ sender: Any?) {
        let ns = string as NSString
        let sel = selectedRange()
        if sel.length == 0, sel.location > 0, sel.location < ns.length {
            let prev = ns.substring(with: NSRange(location: sel.location - 1, length: 1))
            let next = ns.substring(with: NSRange(location: sel.location, length: 1))
            if let close = Self.pairs[prev], close == next {
                insertReplacing(NSRange(location: sel.location - 1, length: 2), with: "", caret: sel.location - 1)
                return
            }
        }
        super.deleteBackward(sender)
    }

    override func insertNewline(_ sender: Any?) {
        let ns = string as NSString
        let sel = selectedRange()
        let lines = TextLines(nsString: ns)
        let line = lines.line(forOffset: sel.location)
        let lr = lines.lineRange(line)
        let lineText = ns.substring(with: lr)
        let indent = String(lineText.prefix { $0 == " " || $0 == "\t" })
        let beforeCaret = ns.substring(with: NSRange(location: lr.location, length: max(0, sel.location - lr.location)))
        let trimmed = beforeCaret.trimmingCharacters(in: .whitespaces)
        let opens = trimmed.hasSuffix("{") || trimmed.hasSuffix("(") || trimmed.hasSuffix("[") || (trimmed.hasPrefix("case ") || trimmed.hasPrefix("default")) && trimmed.hasSuffix(":")
        let next: unichar = sel.location + sel.length < ns.length ? ns.character(at: sel.location + sel.length) : 0
        let closesNext = (next == 125 && trimmed.hasSuffix("{")) || (next == 41 && trimmed.hasSuffix("(")) || (next == 93 && trimmed.hasSuffix("["))
        if closesNext {
            let inner = "\n" + indent + "\t"
            insertReplacing(sel, with: inner + "\n" + indent, caret: sel.location + (inner as NSString).length)
        } else {
            let newIndent = opens ? indent + "\t" : indent
            insertReplacing(sel, with: "\n" + newIndent, caret: sel.location + 1 + (newIndent as NSString).length)
        }
    }

    override func insertTab(_ sender: Any?) {
        let sel = selectedRange()
        if sel.length > 0, (string as NSString).substring(with: sel).contains("\n") {
            shiftLines(right: true)
        } else {
            super.insertTab(sender)
        }
    }

    override func insertBacktab(_ sender: Any?) { shiftLines(right: false) }

    private func matchingIndent(forCloseAt offset: Int, in ns: NSString) -> String {
        var depth = 0
        var i = offset - 1
        while i >= 0 {
            let c = ns.character(at: i)
            if c == 125 { depth += 1 } else if c == 123 {
                if depth == 0 {
                    let lines = TextLines(nsString: ns)
                    let t = lines.lineText(lines.line(forOffset: i))
                    return String(t.prefix { $0 == " " || $0 == "\t" })
                }
                depth -= 1
            }
            i -= 1
        }
        return ""
    }

    /// Undoable replacement + caret placement.
    func insertReplacing(_ range: NSRange, with text: String, caret: Int, selectLength: Int = 0) {
        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
        setSelectedRange(NSRange(location: caret, length: selectLength))
    }

    // MARK: - Line commands (GoLand keymap)

    private func selectedLineRange() -> (range: NSRange, lines: TextLines, first: Int, last: Int) {
        let ns = string as NSString
        let lines = TextLines(nsString: ns)
        let sel = selectedRange()
        let first = lines.line(forOffset: sel.location)
        var endOffset = NSMaxRange(sel)
        if sel.length > 0 && endOffset > 0 && ns.character(at: endOffset - 1) == 10 { endOffset -= 1 }
        let last = lines.line(forOffset: endOffset)
        let start = lines.lineStarts[first]
        let end = last + 1 < lines.lineCount ? lines.lineStarts[last + 1] : ns.length
        return (NSRange(location: start, length: end - start), lines, first, last)
    }

    @objc func ogDuplicate(_ sender: Any?) {
        let sel = selectedRange()
        let ns = string as NSString
        if sel.length > 0 {
            let s = ns.substring(with: sel)
            insertReplacing(NSRange(location: NSMaxRange(sel), length: 0), with: s, caret: NSMaxRange(sel), selectLength: sel.length)
            return
        }
        let info = selectedLineRange()
        var block = ns.substring(with: info.range)
        if !block.hasSuffix("\n") { block = "\n" + block }
        let insertAt = block.hasPrefix("\n") ? NSMaxRange(info.range) : NSMaxRange(info.range)
        insertReplacing(NSRange(location: insertAt, length: 0), with: block, caret: sel.location + (block as NSString).length)
    }

    @objc func ogDeleteLine(_ sender: Any?) {
        let info = selectedLineRange()
        insertReplacing(info.range, with: "", caret: info.range.location)
    }

    @objc func ogToggleComment(_ sender: Any?) {
        let info = selectedLineRange()
        let ns = string as NSString
        let block = ns.substring(with: info.range)
        var lines = block.components(separatedBy: "\n")
        let trailingNewline = block.hasSuffix("\n")
        if trailingNewline { lines.removeLast() }
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let allCommented = !nonEmpty.isEmpty && nonEmpty.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        let minIndent = nonEmpty.map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
        let out = lines.map { line -> String in
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
            if allCommented {
                guard let r = line.range(of: "//") else { return line }
                var l = line
                l.removeSubrange(r)
                if l[r.lowerBound...].hasPrefix(" ") { l.remove(at: r.lowerBound) }
                return l
            }
            let idx = line.index(line.startIndex, offsetBy: minIndent)
            return String(line[..<idx]) + "// " + String(line[idx...])
        }
        let newBlock = out.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        let sel = selectedRange()
        insertReplacing(info.range, with: newBlock, caret: info.range.location, selectLength: 0)
        if sel.length == 0 {
            // Move to next line like GoLand.
            let nextLine = min(info.last + 1, TextLines(nsString: string as NSString).lineCount - 1)
            let lines2 = TextLines(nsString: string as NSString)
            let r = lines2.lineRange(nextLine)
            setSelectedRange(NSRange(location: min(r.location + (sel.location - info.range.location), NSMaxRange(r)), length: 0))
        } else {
            setSelectedRange(NSRange(location: info.range.location, length: (newBlock as NSString).length))
        }
    }

    private func moveLines(up: Bool) {
        let info = selectedLineRange()
        let ns = string as NSString
        let lines = info.lines
        if up && info.first == 0 { return }
        if !up && info.last >= lines.lineCount - 1 { return }
        let sel = selectedRange()
        var block = ns.substring(with: info.range)
        if !block.hasSuffix("\n") { block += "\n" }
        if up {
            let prev = lines.lineStarts[info.first - 1]
            let prevLine = ns.substring(with: NSRange(location: prev, length: info.range.location - prev))
            var combined = block + prevLine
            if info.range.location + info.range.length == ns.length && !(ns.substring(with: info.range).hasSuffix("\n")) {
                combined = String(combined.dropLast())
            }
            let total = NSRange(location: prev, length: NSMaxRange(info.range) - prev)
            insertReplacing(total, with: combined, caret: sel.location - (prevLine as NSString).length, selectLength: sel.length)
        } else {
            let nextStart = NSMaxRange(info.range)
            let nextEnd = info.last + 2 < lines.lineCount ? lines.lineStarts[info.last + 2] : ns.length
            var nextLine = ns.substring(with: NSRange(location: nextStart, length: nextEnd - nextStart))
            var b = block
            if !nextLine.hasSuffix("\n") { nextLine += "\n"; b = String(b.dropLast()) }
            let total = NSRange(location: info.range.location, length: nextEnd - info.range.location)
            insertReplacing(total, with: nextLine + b, caret: sel.location + (nextLine as NSString).length, selectLength: sel.length)
        }
    }

    @objc func ogMoveLineUp(_ sender: Any?) { moveLines(up: true) }
    @objc func ogMoveLineDown(_ sender: Any?) { moveLines(up: false) }

    func shiftLines(right: Bool) {
        let info = selectedLineRange()
        let ns = string as NSString
        let block = ns.substring(with: info.range)
        var lines = block.components(separatedBy: "\n")
        let trailing = block.hasSuffix("\n")
        if trailing { lines.removeLast() }
        let out = lines.map { l -> String in
            if right { return l.isEmpty ? l : "\t" + l }
            if l.hasPrefix("\t") { return String(l.dropFirst()) }
            if l.hasPrefix("    ") { return String(l.dropFirst(4)) }
            return l
        }
        let nb = out.joined(separator: "\n") + (trailing ? "\n" : "")
        insertReplacing(info.range, with: nb, caret: info.range.location, selectLength: (nb as NSString).length - (trailing ? 1 : 0))
    }

    @objc func ogExtendSelection(_ sender: Any?) {
        let ns = string as NSString
        let sel = selectedRange()
        selectionStack.append(sel)
        // word -> string/bracket content -> line -> enclosing block -> all
        if sel.length == 0 {
            let w = selectionRange(forProposedRange: sel, granularity: .selectByWord)
            if w.length > 0 { setSelectedRange(w); return }
        }
        if let inner = enclosingBracketRange(around: sel, in: ns), inner != sel {
            setSelectedRange(inner); return
        }
        let info = selectedLineRange()
        if info.range != sel { setSelectedRange(info.range); return }
        setSelectedRange(NSRange(location: 0, length: ns.length))
    }

    @objc func ogShrinkSelection(_ sender: Any?) {
        if let prev = selectionStack.popLast() { setSelectedRange(prev) }
    }

    private func enclosingBracketRange(around sel: NSRange, in ns: NSString) -> NSRange? {
        let opens: [unichar: unichar] = [40: 41, 91: 93, 123: 125]
        var depth: [unichar: Int] = [41: 0, 93: 0, 125: 0]
        var i = sel.location - 1
        while i >= 0 {
            let c = ns.character(at: i)
            if let close = opens[c] {
                if depth[close, default: 0] == 0 {
                    // find matching close
                    var d = 0
                    var j = i + 1
                    while j < ns.length {
                        let cj = ns.character(at: j)
                        if cj == c { d += 1 } else if cj == close {
                            if d == 0 { break }
                            d -= 1
                        }
                        j += 1
                    }
                    guard j < ns.length, j >= NSMaxRange(sel) else { return nil }
                    let inner = NSRange(location: i + 1, length: j - i - 1)
                    if inner == sel || (inner.location == sel.location && inner.length <= sel.length) {
                        return NSRange(location: i, length: j - i + 1)
                    }
                    return inner
                }
                depth[close, default: 0] -= 1
            } else if depth[c] != nil {
                depth[c, default: 0] += 1
            }
            i -= 1
        }
        return nil
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        dismissTransient()
        if event.modifierFlags.contains(.command) {
            let p = convert(event.locationInWindow, from: nil)
            let idx = characterIndexForInsertion(at: p)
            setSelectedRange(NSRange(location: idx, length: 0))
            controller?.gotoDeclaration()
            return
        }
        super.mouseDown(with: event)
    }

    private func dismissTransient() { _ = controller?.dismissTransientUI() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingAreaRef { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited], owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingAreaRef = t
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        // Moving over an open card must not retarget it to the code underneath.
        if controller?.info?.containsMouse == true { controller?.hoverLeft(); return }
        let p = convert(event.locationInWindow, from: nil)
        guard let lm = layoutManager, let tc = textContainer else { return }
        let local = NSPoint(x: p.x - textContainerOrigin.x, y: p.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = lm.glyphIndex(for: local, in: tc, fractionOfDistanceThroughGlyph: &fraction)
        let rect = lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc)
        guard rect.insetBy(dx: -1, dy: -1).contains(local) else {
            controller?.hoverLeft(); return
        }
        var r = rect
        r.origin.x += textContainerOrigin.x
        r.origin.y += textContainerOrigin.y
        controller?.hoverMoved(to: lm.characterIndexForGlyph(at: glyph), rect: r)
    }

    override func mouseExited(with event: NSEvent) {
        controller?.hoverLeft()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let p = convert(event.locationInWindow, from: nil)
        let idx = characterIndexForInsertion(at: p)
        if selectedRange().length == 0 { setSelectedRange(NSRange(location: idx, length: 0)) }
        let items: [(String, Selector)] = [
            ("Go to Declaration", #selector(ProjectWindowController.ogGotoDeclaration(_:))),
            ("Go to Implementation", #selector(ProjectWindowController.ogGotoImplementation(_:))),
            ("Find Usages", #selector(ProjectWindowController.ogFindUsages(_:))),
            ("Rename…", #selector(ProjectWindowController.ogRename(_:))),
            ("Show Context Actions", #selector(ProjectWindowController.ogQuickFix(_:)))
        ]
        menu.insertItem(.separator(), at: 0)
        for (i, (title, sel)) in items.enumerated().reversed() {
            menu.insertItem(NSMenuItem(title: title, action: sel, keyEquivalent: ""), at: 0)
            _ = i
        }
        return menu
    }
}
