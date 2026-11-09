import AppKit
import OgCore

/// Borderless child panel that never takes key focus.
final class PopupPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Completion list below the caret. Filtering is local; keys come from CodeTextView.
@MainActor
final class CompletionPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private weak var editor: EditorController?
    private let panel: PopupPanel
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let detail = NSTextField(labelWithString: "")
    private var all: [LSPCompletionItem] = []
    private var shown: [LSPCompletionItem] = []
    private var anchor = 0          // UTF-16 offset where the typed prefix starts
    private var staleRanges = false
    /// The panel stays attached to the editor window and is shown/hidden with alpha: attaching and
    /// ordering a child window on every keystroke costs ~10 ms in the window server.
    private var showing = false
    var isVisible: Bool { showing }

    init(editor: EditorController) {
        self.editor = editor
        panel = PopupPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 240), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.hasShadow = true
        panel.backgroundColor = Theme.panelBackground
        panel.isOpaque = false
        panel.level = .floating
        let col = NSTableColumn(identifier: .init("c"))
        col.width = 440
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 20
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = Theme.panelBackground
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.style = .plain
        table.selectionHighlightStyle = .regular
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        detail.font = Theme.smallFont
        detail.textColor = Theme.secondaryText
        detail.lineBreakMode = .byTruncatingTail
        let content = NSView()
        content.wantsLayer = true
        content.layer?.cornerRadius = 6
        content.layer?.borderWidth = 1
        content.layer?.borderColor = Theme.border.cgColor
        content.layer?.backgroundColor = Theme.panelBackground.cgColor
        for v in [scroll, detail] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: detail.topAnchor, constant: -2),
            detail.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            detail.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            detail.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -4),
            detail.heightAnchor.constraint(equalToConstant: 16)
        ])
        panel.contentView = content
    }

    func show(items: [LSPCompletionItem], text: NSString, caret: Int, staleRanges: Bool, explicit: Bool) {
        guard let editor else { return }
        all = items.sorted { ($0.sortText ?? $0.label) < ($1.sortText ?? $1.label) }
        self.staleRanges = staleRanges
        anchor = caret
        while anchor > 0, let u = UnicodeScalar(text.character(at: anchor - 1)), CharacterSet.alphanumerics.contains(u) || u == "_" { anchor -= 1 }
        refilter(text: text, caret: caret)
        guard !shown.isEmpty else { close(); return }
        // Position under the caret.
        let rect = editor.caretScreenRect()
        guard let window = editor.textView.window else { return }
        let inWindow = editor.textView.convert(rect, to: nil)
        let screen = window.convertToScreen(inWindow)
        let height = min(CGFloat(shown.count) * 20 + 28, 280)
        let frame = NSRect(x: screen.minX - 24, y: screen.minY - height - 2, width: 480, height: height).integral
        // Re-placing a window forces a layout pass of the table; skip it when nothing moved.
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            panel.alphaValue = 0
            window.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
        }
        if !showing {
            showing = true
            panel.alphaValue = 1
            panel.ignoresMouseEvents = false
        }
        _ = explicit
    }

    func refilter(text: NSString, caret: Int) {
        guard caret >= anchor else { close(); return }
        let prefix = text.substring(with: NSRange(location: anchor, length: caret - anchor)).lowercased()
        if prefix.isEmpty {
            shown = all
        } else {
            let scored: [(LSPCompletionItem, Int)] = all.compactMap { item in
                let key = (item.filterText ?? item.label).lowercased()
                if key.hasPrefix(prefix) { return (item, 0) }
                if Self.subsequence(prefix, of: key) { return (item, 1) }
                return nil
            }
            shown = scored.sorted { $0.1 < $1.1 }.map(\.0)
        }
        table.reloadData()
        if !shown.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            table.scrollRowToVisible(0)
            updateDetail()
        } else {
            close()
        }
    }

    static func subsequence(_ needle: String, of hay: String) -> Bool {
        var it = hay.makeIterator()
        for c in needle {
            var found = false
            while let h = it.next() { if h == c { found = true; break } }
            if !found { return false }
        }
        return true
    }

    func caretMoved(to caret: Int) {
        guard isVisible else { return }
        if caret < anchor { close() }
    }

    func move(_ delta: Int) {
        guard !shown.isEmpty else { return }
        let row = max(0, min(shown.count - 1, table.selectedRow + delta))
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        updateDetail()
    }

    func acceptSelected() {
        let row = table.selectedRow
        guard row >= 0, row < shown.count else { close(); return }
        let item = shown[row]
        let stale = staleRanges
        close()
        editor?.acceptCompletion(item, staleRanges: stale)
    }

    @objc private func doubleClicked() { acceptSelected() }

    /// Headless driver: the items currently listed, and accepting one of them.
    var debugShown: [LSPCompletionItem] { isVisible ? shown : [] }
    func debugAccept(index: Int) {
        guard index >= 0, index < shown.count else { return }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        acceptSelected()
    }

    func close() {
        guard showing else { return }
        showing = false
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
    }

    private func updateDetail() {
        let row = table.selectedRow
        guard row >= 0, row < shown.count else { detail.stringValue = ""; return }
        let item = shown[row]
        detail.stringValue = [item.detail, item.documentation?.components(separatedBy: "\n").first].compactMap { $0 }.joined(separator: " — ")
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = shown[row]
        let cell = (tableView.makeView(withIdentifier: CompletionCell.id, owner: nil) as? CompletionCell) ?? CompletionCell()
        cell.kind.stringValue = Self.kindGlyph(item.kind)
        cell.kind.textColor = Self.kindColor(item.kind)
        cell.label.stringValue = item.label
        cell.label.font = Theme.editorFont
        cell.detail.stringValue = item.detail ?? ""
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateDetail() }

    static func kindGlyph(_ k: LSPCompletionKind?) -> String {
        switch k {
        case .function, .method: return "ƒ"
        case .variable: return "v"
        case .field, .property: return "f"
        case .struct, .class: return "S"
        case .interface: return "I"
        case .module: return "P"
        case .constant, .enumMember: return "c"
        case .keyword: return "k"
        case .snippet: return "⋯"
        case .typeParameter: return "T"
        default: return "•"
        }
    }

    static func kindColor(_ k: LSPCompletionKind?) -> NSColor {
        switch k {
        case .function, .method: return Theme.function
        case .struct, .class, .interface, .typeParameter: return Theme.type
        case .keyword: return Theme.keyword
        case .constant, .enumMember: return Theme.number
        default: return Theme.secondaryText
        }
    }
}

/// Tooltip panel for hover documentation, diagnostics, and signature help.
@MainActor
final class InfoPopup {
    enum Kind { case hover, signature }
    private weak var editor: EditorController?
    private let panel: PopupPanel
    private let text = CardTextView()
    private(set) var kind: Kind = .hover
    private var monitor: Any?
    private let linkOpener = LinkOpener()
    var isVisible: Bool { panel.isVisible }
    /// The pointer is over the card (scrolling it, selecting, clicking links).
    var containsMouse: Bool { panel.isVisible && panel.frame.contains(NSEvent.mouseLocation) }

    init(editor: EditorController) {
        self.editor = editor
        panel = PopupPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 120), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 6
        box.layer?.borderWidth = 1
        box.layer?.borderColor = Theme.border.cgColor
        box.layer?.backgroundColor = Theme.panelBackground.cgColor
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 8, height: 6)
        text.linkTextAttributes = [.foregroundColor: Theme.function, .cursor: NSCursor.pointingHand]
        text.delegate = linkOpener
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: box.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor)
        ])
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        panel.contentView = box
    }

    func show(text string: String, at rect: NSRect, in view: NSView, kind: Kind) {
        let attr = NSMutableAttributedString(string: string, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: max(11, Theme.fontSize - 1), weight: .regular),
            .foregroundColor: Theme.text
        ])
        present(attr, at: rect, in: view, kind: kind)
    }

    func show(attributed attr: NSAttributedString, at rect: NSRect, in view: NSView, kind: Kind) {
        present(attr, at: rect, in: view, kind: kind)
    }

    func showSignature(_ sig: LSPSignatureHelp, at rect: NSRect, in view: NSView) {
        let attr = NSMutableAttributedString(string: sig.label, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: max(11, Theme.fontSize - 1), weight: .regular),
            .foregroundColor: Theme.secondaryText
        ])
        if let r = sig.activeParameterRange, NSMaxRange(r) <= attr.length {
            attr.addAttributes([.foregroundColor: Theme.text, .font: NSFont.monospacedSystemFont(ofSize: max(11, Theme.fontSize - 1), weight: .bold)], range: r)
        }
        present(attr, at: rect, in: view, kind: .signature, above: true)
    }

    private func present(_ attr: NSAttributedString, at rect: NSRect, in view: NSView, kind: Kind, above: Bool = false) {
        guard let window = view.window else { return }
        self.kind = kind
        text.textStorage?.setAttributedString(attr)
        let maxWidth: CGFloat = 640
        let bounding = attr.boundingRect(with: NSSize(width: maxWidth - 40, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let size = NSSize(width: min(maxWidth, max(160, ceil(bounding.width) + 40)), height: min(360, ceil(bounding.height) + 16))
        let screenRect = window.convertToScreen(view.convert(rect, to: nil))
        let y = above ? screenRect.maxY + 4 : screenRect.minY - size.height - 4
        panel.setFrame(NSRect(x: screenRect.minX, y: y, width: size.width, height: size.height), display: true)
        if !panel.isVisible {
            window.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
        }
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .scrollWheel]) { [weak self] event in
                MainActor.assumeIsolated {
                    // Clicks and scrolls inside the card (links, text selection) keep it open.
                    if let self, event.window !== self.panel, !self.containsMouse, self.kind == .hover || event.type != .keyDown { self.close() }
                }
                return event
            }
        }
    }

    func closeIf(kind: Kind) { if self.kind == kind { close() } }

    func close() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        if panel.isVisible {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
    }
}

/// Opens hover-card links (pkg.go.dev) in the default browser, then closes nothing else.
@MainActor
final class LinkOpener: NSObject, NSTextViewDelegate {
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        guard let url, url.scheme == "https" || url.scheme == "http" else { return false }
        NSWorkspace.shared.open(url)
        return true
    }
}

/// The card never becomes key, so it must take the first click itself (links).
final class CardTextView: NSTextView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// One completion row; reused by the table instead of being rebuilt on every refilter.
@MainActor
final class CompletionCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("og.completion.cell")
    let kind = NSTextField(labelWithString: "")
    let label = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        kind.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
        kind.alignment = .center
        label.font = Theme.editorFont
        label.textColor = Theme.text
        label.lineBreakMode = .byTruncatingTail
        detail.font = Theme.smallFont
        detail.textColor = Theme.secondaryText
        detail.lineBreakMode = .byTruncatingTail
        detail.alignment = .right
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [kind, label, detail])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            kind.widthAnchor.constraint(equalToConstant: 16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }
}
