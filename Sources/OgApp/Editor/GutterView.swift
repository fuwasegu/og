import AppKit
import OgCore

/// Line numbers, breakpoints, run badges, diagnostics, git changes, debug arrow.
@MainActor
final class GutterView: NSRulerView {
    private weak var editor: EditorController?
    private var runTargets: [Int: RunRequest] = [:]   // line -> request

    init(scrollView: NSScrollView, editor: EditorController) {
        self.editor = editor
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = editor.textView
        ruleThickness = 64
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
        scrollView.contentView.postsBoundsChangedNotifications = true
    }

    required init(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let editor, let tv = editor.textView as CodeTextView?, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        Theme.gutterBackground.setFill()
        bounds.fill()
        let ns = tv.string as NSString
        let lines = TextLines(nsString: ns)
        let visible = scrollView?.contentView.bounds ?? bounds
        let glyphRange = lm.glyphRange(forBoundingRect: visible, in: tc)
        let charRange = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let firstLine = lines.line(forOffset: charRange.location)
        let lastLine = lines.line(forOffset: NSMaxRange(charRange))
        let caretLine = lines.line(forOffset: tv.selectedRange().location)
        let font = NSFont.monospacedDigitSystemFont(ofSize: max(10, Theme.fontSize - 2), weight: .regular)
        let breakpoints = editor.context.breakpoints.lines(in: editor.document.url)
        let diagLines = Dictionary(grouping: editor.diagnostics, by: { $0.range.start.line })
        let debugLine = editor.textView.debugLine
        runTargets = computeRunTargets(lines: lines, from: firstLine, to: lastLine)
        let yOffset = convert(NSPoint.zero, from: tv).y

        // Git change bars.
        for change in editor.gitChanges {
            let start = change.startLine
            let end = max(start, start + max(change.lineCount, 1) - 1)
            guard end >= firstLine, start <= lastLine else { continue }
            guard let r1 = tv.lineRect(forLine: start), let r2 = tv.lineRect(forLine: min(end, lines.lineCount - 1)) else { continue }
            let color: NSColor = change.kind == .added ? Theme.gitAdded : (change.kind == .modified ? Theme.gitModified : Theme.gitDeleted)
            color.setFill()
            if change.kind == .deleted {
                NSBezierPath(rect: NSRect(x: bounds.width - 6, y: r1.minY + yOffset - 2, width: 5, height: 4)).fill()
            } else {
                NSRect(x: bounds.width - 5, y: r1.minY + yOffset, width: 3, height: r2.maxY - r1.minY).fill()
            }
        }

        guard firstLine <= lastLine else { return }
        for line in firstLine...lastLine {
            guard let r = tv.lineRect(forLine: line) else { continue }
            let y = r.minY + yOffset
            let h = r.height
            // Number
            let num = "\(line + 1)" as NSString
            let color = line == caretLine ? Theme.text : Theme.lineNumber
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let size = num.size(withAttributes: attrs)
            num.draw(at: NSPoint(x: 40 - size.width, y: y + (h - size.height) / 2), withAttributes: attrs)
            // Breakpoint
            if breakpoints.contains(line) {
                Theme.breakpoint.setFill()
                NSBezierPath(ovalIn: NSRect(x: 4, y: y + (h - 11) / 2, width: 11, height: 11)).fill()
            }
            // Debug arrow
            if debugLine == line {
                NSColor.systemYellow.setFill()
                let p = NSBezierPath()
                let cy = y + h / 2
                p.move(to: NSPoint(x: 3, y: cy - 5)); p.line(to: NSPoint(x: 13, y: cy)); p.line(to: NSPoint(x: 3, y: cy + 5)); p.close()
                p.fill()
            }
            // Run badge
            if runTargets[line] != nil {
                Theme.gitAdded.setFill()
                let cx: CGFloat = 50, cy = y + h / 2
                let p = NSBezierPath()
                p.move(to: NSPoint(x: cx - 4, y: cy - 5)); p.line(to: NSPoint(x: cx + 5, y: cy)); p.line(to: NSPoint(x: cx - 4, y: cy + 5)); p.close()
                p.fill()
            } else if let diags = diagLines[line], let worst = diags.map({ $0.severity?.rawValue ?? 4 }).min() {
                let c = worst == 1 ? Theme.error : (worst == 2 ? Theme.warning : Theme.info)
                c.setFill()
                NSBezierPath(ovalIn: NSRect(x: 46, y: y + (h - 7) / 2, width: 7, height: 7)).fill()
            }
        }
    }

    private func computeRunTargets(lines: TextLines, from: Int, to: Int) -> [Int: RunRequest] {
        guard let editor, editor.document.isGo else { return [:] }
        var out: [Int: RunRequest] = [:]
        let dir = editor.document.url.deletingLastPathComponent()
        let isTestFile = editor.document.url.lastPathComponent.hasSuffix("_test.go")
        guard from <= to else { return [:] }
        for line in from...min(to, lines.lineCount - 1) {
            let t = lines.lineText(line)
            guard t.hasPrefix("func ") else { continue }
            if t.hasPrefix("func main()") {
                out[line] = .runMain(packageDir: dir)
            } else if isTestFile, let name = Self.funcName(t), name.hasPrefix("Test"), t.contains("*testing.T") {
                out[line] = .test(packageDir: dir, name: name)
            } else if isTestFile, let name = Self.funcName(t), name.hasPrefix("Benchmark"), t.contains("*testing.B") {
                out[line] = .bench(packageDir: dir, name: name)
            } else if isTestFile, let name = Self.funcName(t), name.hasPrefix("Fuzz"), t.contains("*testing.F") {
                out[line] = .test(packageDir: dir, name: name)
            }
        }
        return out
    }

    static func funcName(_ line: String) -> String? {
        guard line.hasPrefix("func "), !line.hasPrefix("func (") else { return nil }
        let rest = line.dropFirst(5)
        let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return name.isEmpty ? nil : String(name)
    }

    override func mouseDown(with event: NSEvent) {
        guard let editor else { return }
        let p = convert(event.locationInWindow, from: nil)
        let tv = editor.textView
        let tvPoint = tv.convert(NSPoint(x: 10, y: p.y), from: self)
        let idx = tv.characterIndexForInsertion(at: tvPoint)
        let line = TextLines(nsString: tv.string as NSString).line(forOffset: idx)
        if p.x >= 42, let req = runTargets[line] {
            let menu = NSMenu()
            let run = NSMenuItem(title: "Run \(req.title)", action: #selector(runItem(_:)), keyEquivalent: "")
            run.target = self
            run.representedObject = RunBox(req, debug: false)
            menu.addItem(run)
            if case .bench = req {} else {
                let dbg = NSMenuItem(title: "Debug \(req.title)", action: #selector(runItem(_:)), keyEquivalent: "")
                dbg.target = self
                dbg.representedObject = RunBox(req, debug: true)
                menu.addItem(dbg)
            }
            menu.popUp(positioning: nil, at: p, in: self)
            return
        }
        editor.context.breakpoints.toggle(editor.document.url, line: line)
        needsDisplay = true
    }

    @objc private func runItem(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? RunBox, let editor else { return }
        if box.debug { editor.context.debug(box.request) } else { editor.context.run(box.request) }
    }
}

final class RunBox: NSObject {
    let request: RunRequest
    let debug: Bool
    init(_ r: RunRequest, debug: Bool) { request = r; self.debug = debug }
}
