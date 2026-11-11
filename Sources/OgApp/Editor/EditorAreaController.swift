import AppKit
import OgCore

/// The editor area: one or more panes (split right / down, nested), each with its own tabs.
/// A file shown in several panes is one `Document` (one buffer, one undo stack) with one
/// `EditorController` per pane. Navigation history and session restore live here too.
@MainActor
final class EditorAreaController: NSViewController {
    let context: ProjectContext
    /// Panes in on-screen order (left to right, top to bottom).
    private(set) var panes: [EditorPane] = []
    private(set) var activePane: EditorPane?
    private let root = NSView()
    private var back: [(URL, Int)] = []
    private var forward: [(URL, Int)] = []
    private(set) var recent: [URL] = []

    /// Every editor in every pane.
    var editors: [EditorController] { panes.flatMap(\.editors) }
    /// The selected editor of the active pane.
    var current: EditorController? { activePane?.current }
    var isSplit: Bool { panes.count > 1 }

    init(context: ProjectContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        root.wantsLayer = true
        Theme.paint(root, background: Theme.background)
        view = root
        let pane = makePane()
        setRootContent(pane)
        panes = [pane]
        activePane = pane
        refreshTabs()
    }

    /// The editor for `doc`, preferring the active pane.
    func controller(for doc: Document) -> EditorController? {
        activePane?.editors.first { $0.document === doc } ?? editors.first { $0.document === doc }
    }

    /// Editors showing `doc` in any pane.
    func editors(showing doc: Document) -> [EditorController] { editors.filter { $0.document === doc } }

    private func pane(of editor: EditorController) -> EditorPane? { panes.first { $0.editors.contains { $0 === editor } } }

    // MARK: - Opening

    @discardableResult
    func open(_ url: URL, line: Int? = nil, column: Int? = nil, length: Int = 0) -> EditorController? {
        _ = view
        let key = url.standardizedFileURL
        // Already open: the active pane's tab first, then any pane's (like GoLand).
        if let existing = activePane?.editors.first(where: { $0.document.url == key }) ?? editors.first(where: { $0.document.url == key }) {
            activate(existing)
            if let line { existing.reveal(line: line, column: column ?? 0, length: length) }
            return existing
        }
        guard let pane = activePane, let editor = openEditor(key, in: pane) else { return nil }
        activate(editor)
        if let line { editor.reveal(line: line, column: column ?? 0, length: length) }
        return editor
    }

    /// A new tab for `url` in `pane`, after its selected tab. Nil for folders and unreadable files.
    private func openEditor(_ url: URL, in pane: EditorPane) -> EditorController? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        guard let doc = context.documents.open(url) else {
            NSWorkspace.shared.open(url)
            return nil
        }
        return addEditor(for: doc, to: pane)
    }

    private func addEditor(for doc: Document, to pane: EditorPane) -> EditorController {
        if editors(showing: doc).isEmpty {
            doc.onStateChange.append { [weak self] _ in self?.refreshTabs() }
            doc.onChange.append { [weak self] _ in self?.refreshTabsSoon() }
        }
        let editor = EditorController(context: context, document: doc)
        // Insert after the selected tab, like GoLand.
        if let cur = pane.current, let i = pane.editors.firstIndex(where: { $0 === cur }) {
            pane.editors.insert(editor, at: i + 1)
        } else {
            pane.editors.append(editor)
        }
        addChild(editor)
        return editor
    }

    // MARK: - Activation

    private func activate(_ editor: EditorController, focus: Bool = true) {
        guard let pane = pane(of: editor) else { return }
        if current === editor {
            if focus { editor.focus() }
            return
        }
        // Leaving a tab makes it eligible for autosave (ED-2 / D-7).
        if let prev = current {
            _ = prev.dismissTransientUI()
            if prev.document.dirty { context.documents.save(prev.document) }
        }
        activePane = pane
        if pane.current !== editor { pane.show(editor) }
        if focus { editor.focus() }
        editor.selectionDidChange()
        recent.removeAll { $0 == editor.document.url }
        recent.insert(editor.document.url, at: 0)
        if recent.count > 30 { recent.removeLast() }
        refreshTabs()
        context.window?.sidebar.didActivate(editor)
        view.window?.representedURL = editor.document.url
    }

    /// The user clicked into an editor's text: its pane becomes the active one.
    func editorDidFocus(_ editor: EditorController) {
        if current !== editor { activate(editor, focus: false) }
    }

    func select(index: Int) {
        guard let pane = activePane else { return }
        select(index: index, in: pane)
    }

    private func select(index: Int, in pane: EditorPane) {
        guard index >= 0, index < pane.editors.count else { return }
        activate(pane.editors[index])
    }

    func selectNext(_ delta: Int) {
        guard let pane = activePane, let cur = pane.current, let i = pane.editors.firstIndex(where: { $0 === cur }) else { return }
        select(index: (i + delta + pane.editors.count) % pane.editors.count, in: pane)
    }

    // MARK: - Closing

    func closeCurrent() {
        guard let pane = activePane, let cur = pane.current, let i = pane.editors.firstIndex(where: { $0 === cur }) else { return }
        closeTab(index: i, in: pane)
    }

    func closeTab(index: Int) {
        guard let pane = activePane else { return }
        closeTab(index: index, in: pane)
    }

    private func closeTab(index: Int, in pane: EditorPane) {
        guard index >= 0, index < pane.editors.count else { return }
        let editor = pane.editors[index]
        _ = editor.dismissTransientUI()
        let doc = editor.document
        if editors(showing: doc).count == 1 {
            // ED-1/D-6: closing the last view autosaves; blocked on conflict or failed save.
            guard context.documents.close(doc) else {
                NSSound.beep()
                context.setStatus(doc.conflict ? "Resolve the conflict before closing this tab" : "Could not save; retry or discard before closing")
                activate(editor)
                return
            }
        } else if doc.dirty {
            // Another pane still shows the buffer: leaving this view only autosaves (ED-2).
            context.documents.save(doc)
        }
        removeEditor(editor, from: pane)
        settle(after: pane, closedAt: index)
    }

    /// Closes every tab under `url` (deleted from the tree), in every pane.
    func closeEditors(for url: URL) {
        let prefix = url.standardizedFileURL.path
        var discarded: Set<ObjectIdentifier> = []
        for pane in panes {
            while let i = pane.editors.firstIndex(where: { $0.document.url.path.hasPrefix(prefix) }) {
                let ed = pane.editors[i]
                if discarded.insert(ObjectIdentifier(ed.document)).inserted { context.documents.discardForDeletion(ed.document) }
                removeEditor(ed, from: pane)
                settle(after: pane, closedAt: i, refocus: false)
            }
        }
        if let cur = current { activate(cur, focus: false) }
        refreshTabs()
    }

    /// Detaches an editor from its pane and from the document's storage.
    private func removeEditor(_ editor: EditorController, from pane: EditorPane) {
        let doc = editor.document
        if let lm = editor.textView.layoutManager { doc.storage.removeLayoutManager(lm) }
        pane.editors.removeAll { $0 === editor }
        if pane.current === editor { pane.clear() }
        editor.view.removeFromSuperview()
        editor.removeFromParent()
        // The storage has one delegate: hand it to a remaining view of the same buffer.
        if doc.storage.delegate === editor { doc.storage.delegate = editors(showing: doc).first }
    }

    /// After a tab left `pane`: select a neighbor tab, or drop the pane when it is empty and not the last one.
    private func settle(after pane: EditorPane, closedAt index: Int, refocus: Bool = true) {
        if pane.editors.isEmpty, panes.count > 1 {
            removePane(pane)
        } else if pane.current == nil, !pane.editors.isEmpty {
            let next = pane.editors[min(index, pane.editors.count - 1)]
            if pane === activePane { activate(next, focus: refocus) } else { pane.show(next) }
        }
        refreshTabs()
    }

    // MARK: - Panes

    /// Shows the selected tab of the active pane in a new pane to its right (`vertical`) or below.
    func split(vertical: Bool) {
        guard let pane = activePane, let cur = pane.current else { NSSound.beep(); return }
        let newPane = makePane()
        insert(newPane, beside: pane, vertical: vertical)
        let editor = addEditor(for: cur.document, to: newPane)
        _ = editor.view
        let sel = cur.textView.selectedRange()
        activate(editor)
        editor.textView.setSelectedRange(sel)
        let visible = cur.scrollView.contentView.bounds.origin
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                editor.scrollView.contentView.scroll(to: visible)
                editor.scrollView.reflectScrolledClipView(editor.scrollView.contentView)
            }
        }
    }

    /// Moves the selected tab to the next pane; with one pane, splits to the right first.
    func moveCurrentToNextPane() {
        guard let source = activePane, let editor = source.current else { NSSound.beep(); return }
        guard isSplit else {
            guard source.editors.count > 1 else { NSSound.beep(); return }
            let target = makePane()
            insert(target, beside: source, vertical: true)
            move(editor, from: source, to: target)
            return
        }
        guard let i = panes.firstIndex(where: { $0 === source }) else { return }
        move(editor, from: source, to: panes[(i + 1) % panes.count])
    }

    private func move(_ editor: EditorController, from source: EditorPane, to target: EditorPane) {
        let index = source.editors.firstIndex { $0 === editor } ?? 0
        if let twin = target.editors.first(where: { $0.document === editor.document }) {
            // The target already shows this file: keep that tab, drop this one.
            removeEditor(editor, from: source)
            settle(after: source, closedAt: index, refocus: false)
            activate(twin)
            return
        }
        source.editors.removeAll { $0 === editor }
        source.clear()
        editor.view.removeFromSuperview()
        if let cur = target.current, let j = target.editors.firstIndex(where: { $0 === cur }) {
            target.editors.insert(editor, at: j + 1)
        } else {
            target.editors.append(editor)
        }
        // No active pane while the source settles, so removing it does not activate a third pane.
        activePane = nil
        if source.editors.isEmpty, panes.count > 1 {
            removePane(source)
        } else if !source.editors.isEmpty {
            source.show(source.editors[min(index, source.editors.count - 1)])
        }
        activate(editor)
    }

    func focusNextPane(_ delta: Int) {
        guard isSplit, let pane = activePane, let i = panes.firstIndex(where: { $0 === pane }) else { NSSound.beep(); return }
        let next = panes[(i + delta + panes.count) % panes.count]
        if let ed = next.current { activate(ed) }
    }

    /// Merges every pane's tabs into the active pane and removes the others.
    func unsplit() {
        guard isSplit, let keep = activePane else { return }
        for pane in panes where pane !== keep {
            for ed in pane.editors {
                if keep.editors.contains(where: { $0.document === ed.document }) {
                    removeEditor(ed, from: pane)
                } else {
                    pane.editors.removeAll { $0 === ed }
                    ed.view.removeFromSuperview()
                    keep.editors.append(ed)
                }
            }
            pane.clear()
        }
        detach(keep)
        setRootContent(keep)
        panes = [keep]
        refreshTabs()
        current?.focus()
    }

    private func makePane() -> EditorPane {
        let pane = EditorPane()
        pane.tabBar.onSelect = { [weak self, weak pane] i in
            guard let self, let pane else { return }
            self.select(index: i, in: pane)
        }
        pane.tabBar.onClose = { [weak self, weak pane] i in
            guard let self, let pane else { return }
            self.closeTab(index: i, in: pane)
        }
        pane.tabBar.menuProvider = { [weak self, weak pane] i in
            guard let self, let pane else { return nil }
            return self.tabMenu(index: i, in: pane)
        }
        return pane
    }

    private func makeSplit(vertical: Bool) -> NSSplitView {
        let split = NSSplitView()
        split.isVertical = vertical
        split.dividerStyle = .thin
        return split
    }

    /// Puts `newPane` next to `pane`; nests a split when the orientation differs.
    private func insert(_ newPane: EditorPane, beside pane: EditorPane, vertical: Bool) {
        if let split = pane.superview as? NSSplitView, split.isVertical == vertical,
           let i = split.arrangedSubviews.firstIndex(of: pane) {
            split.insertArrangedSubview(newPane, at: i + 1)
            equalize(split)
        } else {
            let split = makeSplit(vertical: vertical)
            split.frame = pane.frame
            replace(pane, with: split)
            split.addArrangedSubview(pane)
            split.addArrangedSubview(newPane)
            equalize(split)
        }
        panes = orderedPanes()
    }

    private func removePane(_ pane: EditorPane) {
        let parent = pane.superview as? NSSplitView
        let order = panes
        detach(pane)
        if let parent {
            if parent.arrangedSubviews.count == 1, let only = parent.arrangedSubviews.first {
                detach(only)
                only.frame = parent.frame
                replace(parent, with: only)
            } else {
                parent.adjustSubviews()
            }
        }
        panes = orderedPanes()
        if activePane === pane {
            let i = order.firstIndex { $0 === pane } ?? 0
            activePane = panes[max(0, min(i, panes.count) - 1)]
            if let ed = activePane?.current {
                activePane = nil
                activate(ed)
            }
        }
    }

    private func detach(_ v: NSView) {
        if let split = v.superview as? NSSplitView { split.removeArrangedSubview(v) }
        v.removeFromSuperview()
    }

    /// Swaps `old` for `new` at the same place in the split tree (or as the root content).
    private func replace(_ old: NSView, with new: NSView) {
        if let parent = old.superview as? NSSplitView, let i = parent.arrangedSubviews.firstIndex(of: old) {
            detach(old)
            parent.insertArrangedSubview(new, at: i)
        } else {
            old.removeFromSuperview()
            setRootContent(new)
        }
    }

    private func setRootContent(_ v: NSView) {
        root.subviews.forEach { $0.removeFromSuperview() }
        v.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: root.topAnchor),
            v.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            v.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
    }

    /// Gives every child of `split` the same share.
    private func equalize(_ split: NSSplitView) {
        root.layoutSubtreeIfNeeded()
        let n = split.arrangedSubviews.count
        guard n > 1 else { return }
        let total = split.isVertical ? split.bounds.width : split.bounds.height
        let usable = total - split.dividerThickness * CGFloat(n - 1)
        for i in 0..<(n - 1) {
            split.setPosition(usable / CGFloat(n) * CGFloat(i + 1) + split.dividerThickness * CGFloat(i), ofDividerAt: i)
        }
    }

    /// Panes in on-screen order (depth-first through the split tree).
    private func orderedPanes() -> [EditorPane] {
        func walk(_ v: NSView) -> [EditorPane] {
            if let p = v as? EditorPane { return [p] }
            if let s = v as? NSSplitView { return s.arrangedSubviews.flatMap(walk) }
            return []
        }
        return root.subviews.flatMap(walk)
    }

    // MARK: - Tab context menu

    private func tabMenu(index: Int, in pane: EditorPane) -> NSMenu? {
        guard index >= 0, index < pane.editors.count else { return nil }
        let editor = pane.editors[index]
        let menu = NSMenu()
        func add(_ title: String, _ run: @escaping @MainActor () -> Void) {
            menu.addItem(ActionMenuItem(title: title, run: run))
        }
        let focusTab: @MainActor () -> Void = { [weak self, weak editor] in
            if let self, let editor { self.activate(editor) }
        }
        add("Close") { [weak self, weak pane, weak editor] in
            guard let self, let pane, let editor, let i = pane.editors.firstIndex(where: { $0 === editor }) else { return }
            self.closeTab(index: i, in: pane)
        }
        add("Close Other Tabs") { [weak self, weak pane, weak editor] in
            guard let self, let pane, let editor else { return }
            for other in pane.editors where other !== editor {
                if let i = pane.editors.firstIndex(where: { $0 === other }) { self.closeTab(index: i, in: pane) }
            }
        }
        menu.addItem(.separator())
        add("Split Right") { [weak self] in focusTab(); self?.split(vertical: true) }
        add("Split Down") { [weak self] in focusTab(); self?.split(vertical: false) }
        if isSplit || pane.editors.count > 1 {
            add(isSplit ? "Move to Next Pane" : "Move to New Pane") { [weak self] in focusTab(); self?.moveCurrentToNextPane() }
        }
        if isSplit {
            add("Unsplit All") { [weak self] in focusTab(); self?.unsplit() }
        }
        return menu
    }

    // MARK: - Tab strips

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
        for pane in panes { pane.refresh(context: context, active: !isSplit || pane === activePane) }
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
        func encode(_ v: NSView) -> [String: Any]? {
            if let p = v as? EditorPane {
                return ["tabs": p.editors.map { $0.document.url.path },
                        "current": p.current?.document.url.path ?? "",
                        "carets": Dictionary(p.editors.map { ($0.document.url.path, $0.caretOffset) }, uniquingKeysWith: { a, _ in a })]
            }
            if let s = v as? NSSplitView {
                return ["split": s.isVertical ? "right" : "down", "children": s.arrangedSubviews.compactMap(encode)]
            }
            return nil
        }
        guard let layout = root.subviews.first.flatMap(encode) else { return }
        let active = panes.firstIndex { $0 === activePane } ?? 0
        UserDefaults.standard.set(["layout": layout, "active": active], forKey: sessionKey)
    }

    func restoreSession() {
        _ = view
        guard let s = UserDefaults.standard.dictionary(forKey: sessionKey) else { return }
        // Sessions written before panes existed are a single pane.
        let layout = s["layout"] as? [String: Any] ?? s
        if let first = panes.first, layout["split"] != nil {
            let built = build(layout, reusing: first)
            setRootContent(built)
            panes = orderedPanes()
            for split in allSplits(built) { equalize(split) }
        } else if let first = panes.first {
            fill(first, from: layout)
        }
        let active = min(max(s["active"] as? Int ?? 0, 0), panes.count - 1)
        guard let pane = panes.indices.contains(active) ? panes[active] : panes.first else { return }
        for p in panes where p !== pane { if let c = p.current ?? p.editors.first { p.show(c) } }
        if let ed = pane.current ?? pane.editors.first {
            activePane = pane
            pane.clear()
            activate(ed)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { ed.textView.scrollRangeToVisible(ed.textView.selectedRange()) }
            }
        }
        // Panes whose files are all gone collapse away.
        for p in panes where p.editors.isEmpty && panes.count > 1 { removePane(p) }
        refreshTabs()
    }

    private func build(_ node: [String: Any], reusing first: EditorPane?) -> NSView {
        if let dir = node["split"] as? String, let children = node["children"] as? [[String: Any]], !children.isEmpty {
            let split = makeSplit(vertical: dir == "right")
            var reuse = first
            for child in children {
                split.addArrangedSubview(build(child, reusing: reuse))
                reuse = nil
            }
            return split
        }
        let pane = first ?? makePane()
        if first != nil { pane.removeFromSuperview() }
        fill(pane, from: node)
        return pane
    }

    private func fill(_ pane: EditorPane, from node: [String: Any]) {
        let tabs = node["tabs"] as? [String] ?? []
        let carets = node["carets"] as? [String: Int] ?? [:]
        let cur = node["current"] as? String
        for path in tabs where FileManager.default.fileExists(atPath: path) {
            guard let ed = openEditor(URL(fileURLWithPath: path), in: pane) else { continue }
            _ = ed.view
            if let o = carets[path] { ed.textView.setSelectedRange(NSRange(location: min(o, ed.document.storage.length), length: 0)) }
        }
        let selected = pane.editors.first { $0.document.url.path == cur } ?? pane.editors.first
        if let selected { pane.show(selected) }
    }

    private func allSplits(_ v: NSView) -> [NSSplitView] {
        guard let s = v as? NSSplitView else { return [] }
        return [s] + s.arrangedSubviews.flatMap(allSplits)
    }

    // MARK: - Debug driver

    /// "right[a.go* b.go | c.go*]": the split tree with each pane's tabs (`*` marks the selected tab, `>` the active pane).
    var layoutSummary: String {
        func describe(_ v: NSView) -> String {
            if let p = v as? EditorPane {
                let tabs = p.editors.map { $0.document.url.lastPathComponent + ($0 === p.current ? "*" : "") }
                return (p === activePane ? ">" : "") + "[" + tabs.joined(separator: " ") + "]"
            }
            if let s = v as? NSSplitView {
                return (s.isVertical ? "right" : "down") + "(" + s.arrangedSubviews.map(describe).joined(separator: " | ") + ")"
            }
            return "?"
        }
        return root.subviews.map(describe).joined()
    }
}

/// One pane: a tab strip and the selected tab's editor.
@MainActor
final class EditorPane: NSView {
    let tabBar = TabBarView()
    private let container = NSView()
    private let empty = NSTextField(labelWithString: "")
    var editors: [EditorController] = []
    var current: EditorController?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        empty.stringValue = "Go to File  ⇧⌘O\nFind in Files  ⇧⌘F\nRecent Files  ⌘E\nTerminal  ⌥F12"
        empty.alignment = .center
        empty.textColor = Theme.secondaryText
        empty.font = .systemFont(ofSize: 13)
        empty.maximumNumberOfLines = 0
        for v in [tabBar, container, empty] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 30),
            container.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 80)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func show(_ editor: EditorController) {
        if current === editor, editor.view.superview === container { return }
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
    }

    /// No tab shown (the selected one left the pane).
    func clear() {
        current?.view.removeFromSuperview()
        current = nil
    }

    func refresh(context: ProjectContext, active: Bool) {
        tabBar.tabs = editors.map { e in
            TabBarView.Tab(title: e.document.url.lastPathComponent,
                           tooltip: context.relativePath(e.document.url),
                           dirty: e.document.dirty,
                           problem: e.document.conflict || e.document.saveError != nil,
                           hasErrors: e.diagnostics.contains { $0.severity == .error })
        }
        tabBar.selected = current.flatMap { c in editors.firstIndex { $0 === c } } ?? -1
        tabBar.active = active
        empty.isHidden = !editors.isEmpty
    }
}

/// A menu item that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let run: @MainActor () -> Void

    init(title: String, run: @escaping @MainActor () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        run = {}
        super.init(coder: coder)
    }

    @MainActor @objc private func fire() { run() }
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
    /// The strip of the active pane (or the only pane) marks its selected tab with the accent color.
    var active = true { didSet { if active != oldValue { rebuild() } } }
    var onSelect: ((Int) -> Void)?
    /// Context menu of a tab.
    var menuProvider: ((Int) -> NSMenu?)?
    var onClose: ((Int) -> Void)?
    private let scroll = NSScrollView()
    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        Theme.paint(self, background: Theme.sidebarBackground)
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
            let item = TabItemView(tab: t, selected: i == selected, active: active)
            item.onSelect = { [weak self] in self?.onSelect?(i) }
            item.menuProvider = { [weak self] in self?.menuProvider?(i) }
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
    var menuProvider: (() -> NSMenu?)?
    private let selectedTab: Bool

    init(tab: TabBarView.Tab, selected: Bool, active: Bool) {
        selectedTab = selected
        super.init(frame: .zero)
        wantsLayer = true
        Theme.paint(self, background: selected ? Theme.background : Theme.sidebarBackground)
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
            Theme.paint(bar, background: active ? Theme.accent : Theme.secondaryText.withAlphaComponent(0.5))
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

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

    @objc private func closeClicked() { onClose?() }
}
