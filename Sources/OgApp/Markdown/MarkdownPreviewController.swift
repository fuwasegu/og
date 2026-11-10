import AppKit
import OgCore

/// Live preview of a Markdown document, beside its editor. Native text layout (no WebView);
/// Mermaid blocks are rendered by merman and cached, so typing only re-lays out text.
@MainActor
final class MarkdownPreviewController: NSViewController, NSTextViewDelegate {
    private let document: Document
    private let scrollView = NSScrollView()
    private let textView = PreviewTextView()
    private var timer: Timer?
    private var parseTask: Task<Void, Never>?
    private var renderedVersion = -1
    /// Diagram images for the current appearance, by Mermaid source.
    private var diagrams: [String: NSImage] = [:]
    private var diagramsDark: Bool?
    private var errors: [String: String] = [:]
    private var blocks: [MarkdownBlock] = []
    private var observers: [Any] = []
    private var lastRebuildMs: Double = 0
    /// Editor line at the top of the editor's viewport (scroll sync).
    var topLine: () -> Int = { 0 }
    /// Opens a local link (another Markdown file, a Go file) in og.
    var openFile: (URL) -> Void = { _ in }

    init(document: Document) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.background
        scrollView.borderType = .noBorder
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = Theme.background
        textView.textContainerInset = NSSize(width: 28, height: 22)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.linkTextAttributes = [.foregroundColor: Theme.accent, .cursor: NSCursor.pointingHand]
        textView.delegate = self
        textView.layoutManager?.allowsNonContiguousLayout = true
        scrollView.documentView = textView
        view = scrollView

        observers.append(NotificationCenter.default.addObserver(forName: .ogThemeChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.scrollView.backgroundColor = Theme.background
                self.textView.backgroundColor = Theme.background
                self.rebuild()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.widthChanged() }
        })
        scrollView.postsFrameChangedNotifications = true
        document.onChange.append { [weak self] _ in self?.scheduleUpdate() }
        update()
    }

    // MARK: - Updates

    private func scheduleUpdate() {
        timer?.invalidate()
        // Short: the preview should feel live; parsing runs off the main thread.
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    func update() {
        let version = document.version
        guard version != renderedVersion else { return }
        let text = document.text
        parseTask?.cancel()
        parseTask = Task { [weak self] in
            let blocks = await Task.detached(priority: .userInitiated) { OgCore.Markdown.parse(text) }.value
            guard let self, !Task.isCancelled else { return }
            self.renderedVersion = version
            self.blocks = blocks
            self.rebuild()
        }
    }

    private var lastWidth: CGFloat = 0
    private func widthChanged() {
        let w = scrollView.contentSize.width
        guard abs(w - lastWidth) > 24 else { return }
        lastWidth = w
        rebuild()
    }

    /// Top-level blocks now in the text view (content keys) and their rendered text.
    private var shownKeys: [MarkdownBlock] = []
    /// (source line, character offset) of each top-level block, in order.
    private var lineMap: [(line: Int, offset: Int)] = []
    private var pieceCache: [MarkdownBlock: NSAttributedString] = [:]
    private var cacheWidth: CGFloat = 0

    /// Brings the text view up to `blocks`. Only the run of blocks that changed is re-rendered and
    /// replaced, so typing in a long document re-lays out a paragraph, not the file.
    private func rebuild() {
        let t0 = Date()
        defer { lastRebuildMs = Date().timeIntervalSince(t0) * 1000 }
        guard let storage = textView.textStorage else { return }
        let dark = Theme.isDark
        let width = max(100, scrollView.contentSize.width - textView.textContainerInset.width * 2 - 12)
        if diagramsDark != dark || abs(width - cacheWidth) > 0.5 {
            // Theme or width changed: every piece is stale.
            if diagramsDark != dark { diagrams = [:]; errors = [:] }
            diagramsDark = dark
            cacheWidth = width
            pieceCache = [:]
            shownKeys = []
        }
        let renderer = MarkdownRenderer(baseURL: document.url.deletingLastPathComponent(), contentWidth: width, diagrams: diagrams)
        let keys = blocks.map(\.content)
        var used: [MarkdownBlock: NSAttributedString] = [:]
        func piece(_ k: MarkdownBlock) -> NSAttributedString {
            if let p = used[k] ?? pieceCache[k] { used[k] = p; return p }
            let p = NSMutableAttributedString(attributedString: renderer.render(block: k))
            markErrors(in: p)
            used[k] = p
            return p
        }
        // Common prefix / suffix with what is shown.
        var head = 0
        while head < keys.count, head < shownKeys.count, keys[head] == shownKeys[head] { head += 1 }
        var tail = 0
        while tail < keys.count - head, tail < shownKeys.count - head,
              keys[keys.count - 1 - tail] == shownKeys[shownKeys.count - 1 - tail] { tail += 1 }
        let lengths = shownKeys.map { pieceCache[$0]?.length ?? 0 }
        let start = lengths.prefix(head).reduce(0, +)
        // Nothing reusable (first layout, theme or width change): replace all of the text.
        let oldMiddle = shownKeys.isEmpty ? storage.length - start : lengths.dropFirst(head).dropLast(tail).reduce(0, +)
        let middle = NSMutableAttributedString()
        for k in keys[head..<(keys.count - tail)] { middle.append(piece(k)) }
        for k in keys.prefix(head) + keys.suffix(tail) { _ = piece(k) }

        let anchor = scrollView.contentView.bounds.origin
        storage.beginEditing()
        if start + oldMiddle <= storage.length {
            storage.replaceCharacters(in: NSRange(location: start, length: oldMiddle), with: middle)
        } else {
            storage.setAttributedString(NSAttributedString())
            for k in keys { storage.append(piece(k)) }
        }
        storage.endEditing()
        // Where each block starts, for scroll sync. Kept outside the text: stamping attributes would
        // invalidate the layout of the whole document on every keystroke.
        var at = 0
        lineMap = zip(blocks, keys).map { b, k in
            defer { at += used[k]?.length ?? 0 }
            return (b.line, at)
        }
        pieceCache = used
        shownKeys = keys
        scrollView.contentView.scroll(to: anchor)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        renderPendingDiagrams(width: width)
    }

    // MARK: - Mermaid

    private func renderPendingDiagrams(width: CGFloat) {
        guard let storage = textView.textStorage else { return }
        var pending: [String] = []
        storage.enumerateAttribute(.ogMermaid, in: NSRange(location: 0, length: storage.length)) { v, _, _ in
            if let src = v as? String, diagrams[src] == nil, errors[src] == nil, !pending.contains(src) { pending.append(src) }
        }
        guard !pending.isEmpty else { return }
        let dark = Theme.isDark
        let bg = Self.hex(Theme.background)
        Task { [weak self] in
            for src in pending {
                let out = await MermaidRenderer.shared.render(.init(source: src, dark: dark, background: bg))
                guard let self, self.diagramsDark == dark else { return }
                if let png = out.png, let rep = NSBitmapImageRep(data: png) {
                    let img = NSImage(size: NSSize(width: CGFloat(rep.pixelsWide) / out.scale, height: CGFloat(rep.pixelsHigh) / out.scale))
                    img.addRepresentation(rep)
                    self.diagrams[src] = img
                    self.place(src, image: img, width: width)
                } else {
                    self.errors[src] = out.error ?? "Mermaid error"
                    self.replaceWithError(src)
                }
            }
        }
    }

    /// Swaps a placeholder for its rendered diagram without rebuilding the rest.
    private func place(_ source: String, image: NSImage, width: CGFloat) {
        guard let storage = textView.textStorage else { return }
        let r = MarkdownRenderer(baseURL: document.url, contentWidth: width, diagrams: [:])
        storage.beginEditing()
        storage.enumerateAttribute(.ogMermaid, in: NSRange(location: 0, length: storage.length)) { v, range, _ in
            guard (v as? String) == source, let a = storage.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment else { return }
            a.image = image
            a.bounds = r.fitted(image.size)
            storage.edited(.editedAttributes, range: range, changeInLength: 0)
        }
        storage.endEditing()
    }

    /// A diagram failed: its block changes length, so lay everything out again.
    private func replaceWithError(_ source: String) {
        guard errors[source] != nil else { return }
        pieceCache = [:]
        shownKeys = []
        rebuild()
    }

    /// Diagrams merman rejected show their source with the error, like a code block.
    private func markErrors(in text: NSMutableAttributedString) {
        guard !errors.isEmpty else { return }
        var hits: [(NSRange, String)] = []
        text.enumerateAttribute(.ogMermaid, in: NSRange(location: 0, length: text.length)) { v, range, _ in
            if let src = v as? String, let err = errors[src] { hits.append((range, "\(err)\n\n\(src)")) }
        }
        let mono = NSFont(name: Theme.editorFont.fontName, size: 12) ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        for (range, msg) in hits.reversed() {
            let p = NSMutableParagraphStyle()
            let block = NSTextBlock()
            block.setValue(100, type: .percentageValueType, for: .width)
            block.backgroundColor = Theme.bannerError.withAlphaComponent(0.25)
            block.setWidth(10, type: .absoluteValueType, for: .padding)
            p.textBlocks = [block]
            p.alignment = .left
            text.replaceCharacters(in: range, with: NSAttributedString(string: msg, attributes: [
                .font: mono, .foregroundColor: Theme.text, .paragraphStyle: p,
            ]))
        }
    }

    /// `#rrggbb` of a dynamic color as the app currently shows it.
    static func hex(_ c: NSColor) -> String {
        var out = "#ffffff"
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            guard let rgb = c.usingColorSpace(.sRGB) else { return }
            out = String(format: "#%02x%02x%02x", Int(round(rgb.redComponent * 255)), Int(round(rgb.greenComponent * 255)), Int(round(rgb.blueComponent * 255)))
        }
        return out
    }

    // MARK: - Scroll sync (editor -> preview)

    /// Scrolls so the block that holds editor line `line` is at the top.
    func syncScroll(toEditorLine line: Int) {
        guard let storage = textView.textStorage, let lm = textView.layoutManager, let tc = textView.textContainer, storage.length > 0 else { return }
        // Last block starting at or above `line` (binary search: the map is sorted by line).
        var lo = 0, hi = lineMap.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lineMap[mid].line <= line { lo = mid + 1 } else { hi = mid }
        }
        guard lo > 0, lineMap[lo - 1].offset < storage.length else {
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            return
        }
        let target = (line: lineMap[lo - 1].line, location: lineMap[lo - 1].offset)
        let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: target.location, length: 1), actualCharacterRange: nil)
        let rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
        let y = max(0, rect.minY + textView.textContainerOrigin.y - 8)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: - Links

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) else { return false }
        if url.isFileURL {
            if ["md", "markdown", "go", "mod", "txt", "json", "yaml", "yml", "toml"].contains(url.pathExtension.lowercased()) {
                openFile(url)
            } else {
                NSWorkspace.shared.open(url)
            }
            return true
        }
        NSWorkspace.shared.open(url)
        return true
    }

    // MARK: - Headless driver

    var debugSummary: String {
        let s = textView.textStorage
        var diagramsShown = 0
        s?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: s?.length ?? 0)) { v, _, _ in
            if let a = v as? NSTextAttachment, let img = a.image, img.size.width > 1 { diagramsShown += 1 }
        }
        let top = scrollView.contentView.bounds.minY
        return "blocks=\(blocks.count) chars=\(s?.length ?? 0) images=\(diagramsShown) errors=\(errors.count) rebuild=\(String(format: "%.1f", lastRebuildMs))ms top=\(Int(top))"
    }
}

/// The preview's text view: read-only, but selectable and copyable.
private final class PreviewTextView: NSTextView {
    override var acceptsFirstResponder: Bool { true }
}
