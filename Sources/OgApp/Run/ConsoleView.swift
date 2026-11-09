import AppKit
import OgCore

/// Dark ANSI palette shared by the Run console and the terminal.
@MainActor
enum ANSIPalette {
    /// 16 base colors (normal 0-7, bright 8-15), tuned for Theme.background.
    static let base: [NSColor] = [
        rgb(0x1E, 0x1F, 0x22), rgb(0xF0, 0x52, 0x4F), rgb(0x5C, 0xB8, 0x5C), rgb(0xE5, 0xB5, 0x4A),
        rgb(0x56, 0x8A, 0xF2), rgb(0xC1, 0x7A, 0xD6), rgb(0x2A, 0xAC, 0xB8), rgb(0xBC, 0xBE, 0xC4),
        rgb(0x6F, 0x73, 0x7A), rgb(0xFF, 0x7B, 0x72), rgb(0x7E, 0xD3, 0x7E), rgb(0xF2, 0xCC, 0x60),
        rgb(0x7C, 0xA7, 0xFA), rgb(0xD9, 0x9B, 0xEB), rgb(0x56, 0xD4, 0xDD), rgb(0xFF, 0xFF, 0xFF)
    ]

    static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    static func color(_ c: ANSIColor) -> NSColor {
        switch c {
        case .rgb(let r, let g, let b): return rgb(Int(r), Int(g), Int(b))
        case .indexed(let i):
            let i = Int(i)
            if i < 16 { return base[i] }
            if i >= 232 { let v = 8 + (i - 232) * 10; return rgb(v, v, v) }
            let n = i - 16
            let steps = [0, 95, 135, 175, 215, 255]
            return rgb(steps[n / 36], steps[(n / 6) % 6], steps[n % 6])
        }
    }
}

/// Read-only monospace console with ANSI colors and clickable `file.go:LINE[:COL]` links.
///
/// Text is kept in a `log` storage that can be swapped out for another (e.g. one
/// test's output) without losing the live log.
@MainActor
final class ConsoleView: NSScrollView, NSTextViewDelegate {
    let textView: NSTextView
    private let layoutManager = NSLayoutManager()
    /// The live log of the current run.
    private(set) var log = NSTextStorage()
    private var showingLog = true
    private var parser = ANSIParser()
    /// UTF-16 offset in `log` up to which links have been scanned (line granularity).
    private var linkScanned = 0
    /// Resolves a path in console text to a file; called with the link.
    var resolveLink: ((ConsoleFileLink) -> URL?)?
    var openLink: ((URL, Int, Int?) -> Void)?

    static let maxLength = 4_000_000

    override init(frame frameRect: NSRect) {
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        log.addLayoutManager(layoutManager)
        textView = NSTextView(frame: frameRect, textContainer: container)
        super.init(frame: frameRect)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = Theme.background
        textView.textColor = Theme.text
        textView.font = Theme.editorFont
        textView.textContainerInset = NSSize(width: 6, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.linkTextAttributes = [
            .foregroundColor: Theme.function,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand
        ]
        textView.delegate = self
        documentView = textView
        hasVerticalScroller = true
        autohidesScrollers = true
        drawsBackground = true
        backgroundColor = Theme.background
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Live log

    func clear() {
        log.setAttributedString(NSAttributedString())
        parser = ANSIParser()
        linkScanned = 0
        showLog()
    }

    /// Appends process output. `color` is the default foreground (stderr uses red).
    func append(_ text: String, color: NSColor? = nil) {
        guard !text.isEmpty else { return }
        let follow = showingLog && isScrolledToBottom
        log.beginEditing()
        log.append(render(parser.parse(text), color: color))
        if log.length > ConsoleView.maxLength {
            let cut = log.length - ConsoleView.maxLength * 3 / 4
            log.deleteCharacters(in: NSRange(location: 0, length: cut))
            linkScanned = max(0, linkScanned - cut)
        }
        scanLinks(in: log, from: &linkScanned, completeLinesOnly: true)
        log.endEditing()
        if follow { scrollToEnd() }
    }

    /// Appends a line drawn in the secondary color (headers, "Process finished").
    func appendNote(_ text: String, color: NSColor = Theme.secondaryText) {
        let follow = showingLog && isScrolledToBottom
        // Close any pending partial line so the note starts on its own line.
        if log.length > 0, !log.mutableString.hasSuffix("\n") { log.append(NSAttributedString(string: "\n")) }
        scanLinks(in: log, from: &linkScanned, completeLinesOnly: false)
        let start = log.length
        log.append(NSAttributedString(string: text + "\n", attributes: [.font: Theme.editorFont, .foregroundColor: color]))
        linkScanned = max(linkScanned, start + (text as NSString).length + 1)
        if follow { scrollToEnd() }
    }

    func showLog() {
        guard !showingLog else { return }
        layoutManager.replaceTextStorage(log)
        showingLog = true
        scrollToEnd()
    }

    /// Shows static text (e.g. one test's output) without touching the live log.
    func show(text: String) {
        var p = ANSIParser()
        let storage = NSTextStorage(attributedString: render(p.parse(text), color: nil))
        var from = 0
        scanLinks(in: storage, from: &from, completeLinesOnly: false)
        layoutManager.replaceTextStorage(storage)
        showingLog = false
        textView.scrollToBeginningOfDocument(nil)
    }

    private var isScrolledToBottom: Bool {
        guard let doc = documentView else { return true }
        return contentView.bounds.maxY >= doc.frame.height - 24
    }

    private func scrollToEnd() {
        textView.scrollRangeToVisible(NSRange(location: (textView.string as NSString).length, length: 0))
    }

    // MARK: - Rendering

    private func render(_ segments: [ANSIParser.Segment], color: NSColor?) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let font = Theme.editorFont
        for seg in segments {
            var attrs: [NSAttributedString.Key: Any] = [.font: seg.style.bold ? Theme.editorBoldFont : font]
            var fg = seg.style.foreground.map(ANSIPalette.color) ?? color ?? Theme.text
            if seg.style.dim { fg = fg.withAlphaComponent(0.6) }
            attrs[.foregroundColor] = fg
            if let bg = seg.style.background { attrs[.backgroundColor] = ANSIPalette.color(bg) }
            if seg.style.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if seg.style.italic { attrs[.obliqueness] = 0.15 }
            out.append(NSAttributedString(string: seg.text, attributes: attrs))
        }
        return out
    }

    /// Adds `.link` attributes for file references in `storage` from `from` up to the
    /// last newline (or the end), then advances `from`.
    private func scanLinks(in storage: NSTextStorage, from: inout Int, completeLinesOnly: Bool) {
        let ns = storage.string as NSString
        guard from < ns.length else { return }
        var end = ns.length
        if completeLinesOnly {
            let nl = ns.range(of: "\n", options: .backwards, range: NSRange(location: from, length: ns.length - from))
            guard nl.location != NSNotFound else { return }
            end = nl.location + 1
        }
        let chunk = ns.substring(with: NSRange(location: from, length: end - from))
        for link in ConsoleFileLink.scan(chunk) {
            guard let url = resolveLink?(link) else { continue }
            var comps = URLComponents()
            comps.scheme = "og-open"
            comps.path = url.path
            comps.queryItems = [URLQueryItem(name: "line", value: String(link.line))]
                + (link.column.map { [URLQueryItem(name: "col", value: String($0))] } ?? [])
            guard let target = comps.url else { continue }
            storage.addAttribute(.link, value: target,
                                 range: NSRange(location: from + link.utf16Range.lowerBound, length: link.utf16Range.count))
        }
        from = end
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL, url.scheme == "og-open",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        let line = comps.queryItems?.first { $0.name == "line" }?.value.flatMap(Int.init) ?? 1
        let col = comps.queryItems?.first { $0.name == "col" }?.value.flatMap(Int.init)
        openLink?(URL(fileURLWithPath: comps.path), line, col)
        return true
    }
}
