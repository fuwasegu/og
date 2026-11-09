import AppKit
import OgCore

/// Editor tabs + the active editor; navigation history; session restore.
@MainActor
final class EditorAreaController: NSViewController {
    let context: ProjectContext
    private(set) var editors: [EditorController] = []
    private(set) var current: EditorController?
    private let tabBar = TabBarView()
    private let container = NSView()
    private let empty = NSTextField(labelWithString: "")
    private var back: [(URL, Int)] = []
    private var forward: [(URL, Int)] = []
    private(set) var recent: [URL] = []

    init(context: ProjectContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.background.cgColor
        tabBar.onSelect = { [weak self] i in self?.select(index: i) }
        tabBar.onClose = { [weak self] i in self?.closeTab(index: i) }
        empty.stringValue = "Go to File  ⇧⌘O\nFind in Files  ⇧⌘F\nRecent Files  ⌘E\nTerminal  ⌥F12"
        empty.alignment = .center
        empty.textColor = Theme.secondaryText
        empty.font = .systemFont(ofSize: 13)
        empty.maximumNumberOfLines = 0
        for v in [tabBar, container, empty] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: root.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 30),
            container.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        view = root
        refreshTabs()
    }

    func controller(for doc: Document) -> EditorController? { editors.first { $0.document === doc } }

    @discardableResult
    func open(_ url: URL, line: Int? = nil, column: Int? = nil, length: Int = 0) -> EditorController? {
        _ = view
        let key = url.standardizedFileURL
        if let existing = editors.first(where: { $0.document.url == key }) {
            activate(existing)
            if let line { existing.reveal(line: line, column: column ?? 0, length: length) }
            return existing
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: key.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        guard let doc = context.documents.open(key) else {
            NSWorkspace.shared.open(key)
            return nil
        }
        let editor = EditorController(context: context, document: doc)
        doc.onStateChange.append { [weak self] _ in self?.refreshTabs() }
        doc.onChange.append { [weak self] _ in self?.tabBar.needsDisplay = true; self?.refreshTabsSoon() }
        // Insert after the current tab, like GoLand.
        if let cur = current, let i = editors.firstIndex(where: { $0 === cur }) {
            editors.insert(editor, at: i + 1)
        } else {
            editors.append(editor)
        }
        addChild(editor)
        activate(editor)
        if let line { editor.reveal(line: line, column: column ?? 0, length: length) }
        return editor
    }

    private func activate(_ editor: EditorController) {
        if current === editor { editor.focus(); return }
        // Leaving a tab makes it eligible for autosave (ED-2 / D-7).
        if let prev = current {
            _ = prev.dismissTransientUI()
            if prev.document.dirty { context.documents.save(prev.document) }
        }
        current?.view.removeFromSuperview()
        current = editor
        let v = editor.view
        v.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: container.topAnchor),
            v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            v.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        editor.focus()
        editor.selectionDidChange()
        recent.removeAll { $0 == editor.document.url }
        recent.insert(editor.document.url, at: 0)
        if recent.count > 30 { recent.removeLast() }
        refreshTabs()
        context.window?.sidebar.didActivate(editor)
        view.window?.representedURL = editor.document.url
    }

    func select(index: Int) {
        guard index >= 0, index < editors.count else { return }
        activate(editors[index])
    }

    func selectNext(_ delta: Int) {
        guard let cur = current, let i = editors.firstIndex(where: { $0 === cur }), !editors.isEmpty else { return }
        select(index: (i + delta + editors.count) % editors.count)
    }

    func closeCurrent() {
        guard let cur = current, let i = editors.firstIndex(where: { $0 === cur }) else { return }
        closeTab(index: i)
    }

    func closeTab(index: Int) {
        guard index >= 0, index < editors.count else { return }
        let editor = editors[index]
        _ = editor.dismissTransientUI()
        // ED-1/D-6: autosave on close; blocked on conflict or failed save.
        guard context.documents.close(editor.document) else {
            NSSound.beep()
            context.setStatus(editor.document.conflict ? "Resolve the conflict before closing this tab" : "Could not save; retry or discard before closing")
            activate(editor)
            return
        }
        editor.document.storage.removeLayoutManager(editor.textView.layoutManager!)
        editors.remove(at: index)
        editor.view.removeFromSuperview()
        editor.removeFromParent()
        if current === editor {
            current = nil
            if !editors.isEmpty { activate(editors[min(index, editors.count - 1)]) }
        }
        refreshTabs()
    }

    func closeEditors(for url: URL) {
        while let i = editors.firstIndex(where: { $0.document.url.path.hasPrefix(url.standardizedFileURL.path) }) {
            let ed = editors[i]
            ed.document.storage.removeLayoutManager(ed.textView.layoutManager!)
            context.documents.discardForDeletion(ed.document)
            editors.remove(at: i)
            ed.view.removeFromSuperview()
            ed.removeFromParent()
            if current === ed { current = nil }
        }
        if current == nil, let first = editors.first { activate(first) }
        refreshTabs()
    }

    private var refreshPending = false
    private func refreshTabsSoon() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshPending = false
                self?.refreshTabs()
            }
        }
    }

    func refreshTabs() {
        tabBar.tabs = editors.map { e in
            TabBarView.Tab(title: e.document.url.lastPathComponent,
                           tooltip: context.relativePath(e.document.url),
                           dirty: e.document.dirty,
                           problem: e.document.conflict || e.document.saveError != nil,
                           hasErrors: e.diagnostics.contains { $0.severity == .error })
        }
        tabBar.selected = current.flatMap { c in editors.firstIndex { $0 === c } } ?? -1
        empty.isHidden = !editors.isEmpty
    }

    // MARK: - History (Cmd-[ / Cmd-])

    func pushHistory() {
        guard let cur = current else { return }
        back.append((cur.document.url, cur.caretOffset))
        if back.count > 100 { back.removeFirst() }
        forward.removeAll()
    }

    func goBack() {
        guard let (url, offset) = back.popLast() else { return }
        if let cur = current { forward.append((cur.document.url, cur.caretOffset)) }
        jump(url, offset)
    }

    func goForward() {
        guard let (url, offset) = forward.popLast() else { return }
        if let cur = current { back.append((cur.document.url, cur.caretOffset)) }
        jump(url, offset)
    }

    private func jump(_ url: URL, _ offset: Int) {
        guard let ed = open(url) else { return }
        let o = min(offset, ed.document.storage.length)
        let p = TextLines(nsString: ed.document.storage.string as NSString).position(forOffset: o)
        ed.reveal(line: p.line, column: p.character, length: 0)
    }

    // MARK: - Session (WS-3)

    private var sessionKey: String { "og.session.\(context.root.path)" }

    func saveSession() {
        let tabs = editors.map { $0.document.url.path }
        let cur = current?.document.url.path ?? ""
        let carets = Dictionary(uniqueKeysWithValues: editors.map { ($0.document.url.path, $0.caretOffset) })
        UserDefaults.standard.set(["tabs": tabs, "current": cur, "carets": carets], forKey: sessionKey)
    }

    func restoreSession() {
        guard let s = UserDefaults.standard.dictionary(forKey: sessionKey) else { return }
        let tabs = s["tabs"] as? [String] ?? []
        let carets = s["carets"] as? [String: Int] ?? [:]
        for path in tabs where FileManager.default.fileExists(atPath: path) {
            if let ed = open(URL(fileURLWithPath: path)), let o = carets[path] {
                let off = min(o, ed.document.storage.length)
                ed.textView.setSelectedRange(NSRange(location: off, length: 0))
            }
        }
        if let cur = s["current"] as? String, !cur.isEmpty, let ed = open(URL(fileURLWithPath: cur)) {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { ed.textView.scrollRangeToVisible(ed.textView.selectedRange()) }
            }
        }
    }
}

extension DocumentStore {
    /// The file was deleted from the tree: drop the buffer without saving (FT-2).
    func discardForDeletion(_ doc: Document) {
        doc.markSaved(doc.text)
        _ = close(doc)
    }
}

/// Simple tab strip.
@MainActor
final class TabBarView: NSView {
    struct Tab: Equatable { var title: String; var tooltip: String; var dirty: Bool; var problem: Bool; var hasErrors: Bool }
    // Rebuilding the strip is expensive (views + constraints): only when something visible changed.
    var tabs: [Tab] = [] { didSet { if tabs != oldValue { rebuild() } } }
    var selected: Int = -1 { didSet { if selected != oldValue { rebuild() } } }
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    private let scroll = NSScrollView()
    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.sidebarBackground.cgColor
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.alignment = .centerY
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.heightAnchor.constraint(equalTo: scroll.heightAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, t) in tabs.enumerated() {
            let item = TabItemView(tab: t, selected: i == selected)
            item.onSelect = { [weak self] in self?.onSelect?(i) }
            item.onClose = { [weak self] in self?.onClose?(i) }
            stack.addArrangedSubview(item)
            item.heightAnchor.constraint(equalToConstant: 29).isActive = true
        }
        if selected >= 0, selected < stack.arrangedSubviews.count {
            let index = selected
            Task { @MainActor [weak self] in
                guard let self, index < self.stack.arrangedSubviews.count else { return }
                let v = self.stack.arrangedSubviews[index]
                _ = v.scrollToVisible(v.bounds)
            }
        }
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class TabItemView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    private let selectedTab: Bool

    init(tab: TabBarView.Tab, selected: Bool) {
        selectedTab = selected
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = (selected ? Theme.background : Theme.sidebarBackground).cgColor
        toolTip = tab.tooltip
        let icon = NSImageView(image: NSImage(systemSymbolName: tab.title.hasSuffix(".go") ? "chevron.left.forwardslash.chevron.right" : "doc.text", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = tab.title.hasSuffix(".go") ? NSColor(srgbRed: 0.0, green: 0.68, blue: 0.85, alpha: 1) : Theme.secondaryText
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        let label = NSTextField(labelWithString: tab.title)
        label.font = Theme.uiFont
        label.textColor = tab.hasErrors ? Theme.error : (selected ? Theme.text : Theme.secondaryText)
        if tab.problem { label.textColor = Theme.warning }
        let close = NSButton(title: tab.dirty ? "●" : "×", target: nil, action: nil)
        close.isBordered = false
        close.font = .systemFont(ofSize: tab.dirty ? 9 : 13)
        close.contentTintColor = Theme.secondaryText
        close.target = self
        close.action = #selector(closeClicked)
        let stack = NSStackView(views: [icon, label, close])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        if selected {
            let bar = NSView()
            bar.wantsLayer = true
            bar.layer?.backgroundColor = Theme.accent.cgColor
            bar.translatesAutoresizingMaskIntoConstraints = false
            addSubview(bar)
            NSLayoutConstraint.activate([
                bar.leadingAnchor.constraint(equalTo: leadingAnchor),
                bar.trailingAnchor.constraint(equalTo: trailingAnchor),
                bar.bottomAnchor.constraint(equalTo: bottomAnchor),
                bar.heightAnchor.constraint(equalToConstant: 2)
            ])
        }
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { onClose?() } else { onSelect?() }
    }

    override func otherMouseDown(with event: NSEvent) { onClose?() }

    @objc private func closeClicked() { onClose?() }
}
