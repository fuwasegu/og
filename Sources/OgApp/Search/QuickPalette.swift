import AppKit
import OgCore
import UniformTypeIdentifiers

/// One row of a quick-open palette.
struct PaletteItem {
    var title: String
    /// UTF-16 offsets into `title` to highlight.
    var titleHighlights: [Int] = []
    var detail: String = ""
    var detailHighlights: [Int] = []
    var badge: String = ""
    var icon: NSImage?
    var open: @MainActor () -> Void
}

/// Floating, borderless panel that can take keyboard focus.
final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Shared quick-open UI (GoLand "Go to File / Symbol / Recent"): a search field and a
/// results table in a panel at the top center of the project window.
@MainActor
final class QuickPalette: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    /// The palette currently on screen (kept alive while visible).
    private static var current: QuickPalette?

    typealias Provider = @MainActor (String) async -> [PaletteItem]

    private let panel: PalettePanel
    private let field = NSTextField()
    private let table = NSTableView()
    private let hint = NSTextField(labelWithString: "")
    private weak var parent: NSWindow?
    private let provider: Provider
    private let debounce: TimeInterval
    private var items: [PaletteItem] = []
    private var queryTask: Task<Void, Never>?
    private var generation = 0
    /// Row selected after the first result list arrives (Cmd-E selects the second most recent).
    private var initialSelection = 0
    private var closed = false

    static let width: CGFloat = 640
    static let height: CGFloat = 420

    /// Shows a palette over `parent`. `provider` is called (off the keystroke) for every query.
    @discardableResult
    static func show(over parent: NSWindow?, title: String, placeholder: String, debounce: TimeInterval = 0,
                     initialQuery: String = "", provider: @escaping Provider) -> QuickPalette? {
        current?.close(restoreFocus: false)
        guard let parent else { return nil }
        let p = QuickPalette(parent: parent, title: title, placeholder: placeholder, debounce: debounce, provider: provider)
        current = p
        p.present(initialQuery: initialQuery)
        return p
    }

    private init(parent: NSWindow, title: String, placeholder: String, debounce: TimeInterval, provider: @escaping Provider) {
        self.parent = parent
        self.provider = provider
        self.debounce = debounce
        panel = PalettePanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        buildUI(title: title, placeholder: placeholder)
    }

    private func buildUI(title: String, placeholder: String) {
        panel.isFloatingPanel = true
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = true
        panel.delegate = self
        panel.becomesKeyOnlyIfNeeded = false

        let root = NSView()
        root.wantsLayer = true
        Theme.paint(root, background: Theme.panelBackground)
        root.layer?.cornerRadius = 10
        Theme.paint(root, border: Theme.border)
        root.layer?.borderWidth = 1
        root.layer?.masksToBounds = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = Theme.secondaryText

        hint.font = Theme.smallFont
        hint.textColor = Theme.secondaryText
        hint.alignment = .right

        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 15)
        field.textColor = Theme.text
        field.backgroundColor = Theme.background
        field.drawsBackground = true
        field.isBordered = false
        field.isBezeled = false
        field.focusRingType = .none
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true

        let fieldBox = NSView()
        fieldBox.wantsLayer = true
        Theme.paint(fieldBox, background: Theme.background)
        fieldBox.layer?.cornerRadius = 6
        let glass = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) ?? NSImage())
        glass.contentTintColor = Theme.secondaryText
        for v in [glass, field] { v.translatesAutoresizingMaskIntoConstraints = false; fieldBox.addSubview(v) }

        let col = NSTableColumn(identifier: .init("item"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 24
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.refusesFirstResponder = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        for v in [titleLabel, hint, fieldBox, scroll] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            hint.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            hint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            hint.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),

            fieldBox.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            fieldBox.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            fieldBox.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            fieldBox.heightAnchor.constraint(equalToConstant: 32),
            glass.leadingAnchor.constraint(equalTo: fieldBox.leadingAnchor, constant: 8),
            glass.centerYAnchor.constraint(equalTo: fieldBox.centerYAnchor),
            glass.widthAnchor.constraint(equalToConstant: 16),
            field.leadingAnchor.constraint(equalTo: glass.trailingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: fieldBox.trailingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: fieldBox.centerYAnchor),

            scroll.topAnchor.constraint(equalTo: fieldBox.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
        ])
        panel.contentView = root
    }

    private func present(initialQuery: String) {
        guard let parent else { return }
        let pf = parent.frame
        let w = min(Self.width, pf.width - 40)
        let h = min(Self.height, pf.height - 100)
        // Below the title bar / toolbar, horizontally centered.
        let topInset = pf.height - parent.contentLayoutRect.height + 12
        panel.setFrame(NSRect(x: pf.midX - w / 2, y: pf.maxY - topInset - h, width: w, height: h), display: false)
        parent.addChildWindow(panel, ordered: .above)
        field.stringValue = initialQuery
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        query(immediately: true)
    }

    func setInitialSelection(_ row: Int) { initialSelection = row }

    func close(restoreFocus: Bool = true) {
        guard !closed else { return }
        closed = true
        queryTask?.cancel()
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if restoreFocus { parent?.makeKeyAndOrderFront(nil) }
        if QuickPalette.current === self { QuickPalette.current = nil }
    }

    // MARK: - Querying

    private func query(immediately: Bool) {
        queryTask?.cancel()
        generation += 1
        let gen = generation
        let text = field.stringValue
        let delay = immediately ? 0 : debounce
        queryTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled { return }
            }
            guard let self else { return }
            let result = await self.provider(text)
            guard !Task.isCancelled, gen == self.generation, !self.closed else { return }
            self.setItems(result)
        }
    }

    /// Re-runs the current query (e.g. after the file index refreshed).
    func requery() { query(immediately: true) }

    private func setItems(_ new: [PaletteItem]) {
        let first = items.isEmpty && initialSelection > 0
        items = new
        table.reloadData()
        hint.stringValue = new.isEmpty ? (field.stringValue.isEmpty ? "" : "Nothing found") : "\(new.count) result\(new.count == 1 ? "" : "s")"
        guard !new.isEmpty else { return }
        let row = first ? min(initialSelection, new.count - 1) : 0
        initialSelection = 0
        select(row)
    }

    private func select(_ row: Int) {
        guard !items.isEmpty else { return }
        let r = max(0, min(row, items.count - 1))
        table.selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false)
        table.scrollRowToVisible(r)
    }

    @objc private func openSelected() {
        let row = table.selectedRow
        guard row >= 0, row < items.count else { return }
        let item = items[row]
        close()
        item.open()
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) { query(immediately: debounce == 0) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        let page = max(1, Int(table.visibleRect.height / table.rowHeight) - 1)
        switch sel {
        case #selector(NSResponder.moveDown(_:)): select(table.selectedRow + 1); return true
        case #selector(NSResponder.moveUp(_:)): select(table.selectedRow - 1); return true
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)): select(table.selectedRow + page); return true
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)): select(table.selectedRow - page); return true
        case #selector(NSResponder.insertNewline(_:)): openSelected(); return true
        case #selector(NSResponder.cancelOperation(_:)): close(); return true
        default: return false
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // Clicking elsewhere dismisses the palette (deferred so a double-click can finish).
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.closed, !self.panel.isKeyWindow else { return }
                self.close(restoreFocus: false)
            }
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: PaletteCell.id, owner: nil) as? PaletteCell) ?? PaletteCell()
        cell.configure(items[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { PaletteRowView() }

    // MARK: - Helpers for providers

    /// Attributed text with `highlights` (UTF-16 offsets) emphasized.
    static func highlighted(_ text: String, _ highlights: [Int], font: NSFont, color: NSColor) -> NSAttributedString {
        let s = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let len = s.length
        for o in highlights where o >= 0 && o < len {
            s.addAttributes([.foregroundColor: Theme.keyword, .font: bold,
                             .underlineStyle: NSUnderlineStyle.single.rawValue], range: NSRange(location: o, length: 1))
        }
        return s
    }

    private static var iconCache: [String: NSImage] = [:]

    static func icon(forPath path: String) -> NSImage {
        let ext = (path as NSString).pathExtension.lowercased()
        if let i = iconCache[ext] { return i }
        let type = UTType(filenameExtension: ext) ?? .plainText
        let image = NSWorkspace.shared.icon(for: type)
        image.size = NSSize(width: 16, height: 16)
        iconCache[ext] = image
        return image
    }

    /// Splits a relative path match into (file name, directory) items.
    static func fileItem(relativePath: String, offsets: [Int], open: @escaping @MainActor () -> Void) -> PaletteItem {
        let ns = relativePath as NSString
        let slash = ns.range(of: "/", options: .backwards)
        let nameStart = slash.location == NSNotFound ? 0 : slash.location + 1
        let name = ns.substring(from: nameStart)
        let dir = nameStart > 0 ? ns.substring(to: nameStart - 1) : ""
        return PaletteItem(title: name,
                           titleHighlights: offsets.filter { $0 >= nameStart }.map { $0 - nameStart },
                           detail: dir,
                           detailHighlights: offsets.filter { $0 < nameStart - 1 },
                           icon: icon(forPath: relativePath),
                           open: open)
    }
}

/// Selection drawn in the theme accent instead of the system color.
final class PaletteRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        Theme.selection.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 4, yRadius: 4).fill()
    }
    override var isEmphasized: Bool { get { true } set {} }
}

final class PaletteCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("PaletteCell")
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")
    private let badgeField = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        titleField.lineBreakMode = .byTruncatingTail
        detailField.lineBreakMode = .byTruncatingHead
        badgeField.font = Theme.smallFont
        badgeField.textColor = Theme.secondaryText
        titleField.setContentCompressionResistancePriority(.defaultHigh + 1, for: .horizontal)
        titleField.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        detailField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badgeField.setContentCompressionResistancePriority(.required, for: .horizontal)
        badgeField.setContentHuggingPriority(.required, for: .horizontal)
        for v in [iconView, titleField, detailField, badgeField] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailField.leadingAnchor.constraint(equalTo: titleField.trailingAnchor, constant: 8),
            detailField.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeField.leadingAnchor.constraint(greaterThanOrEqualTo: detailField.trailingAnchor, constant: 8),
            badgeField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            badgeField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ item: PaletteItem) {
        iconView.image = item.icon
        iconView.isHidden = item.icon == nil
        titleField.attributedStringValue = QuickPalette.highlighted(item.title, item.titleHighlights, font: .systemFont(ofSize: 13), color: Theme.text)
        detailField.attributedStringValue = QuickPalette.highlighted(item.detail, item.detailHighlights, font: Theme.smallFont, color: Theme.secondaryText)
        badgeField.stringValue = item.badge
    }
}
