import AppKit
import OgCore

/// Left tool window: Project tree and file Structure.
@MainActor
final class SidebarController: NSViewController {
    let context: ProjectContext
    let tree: FileTreeController
    let structure: StructureController
    private let segmented = NSSegmentedControl(labels: ["Project", "Structure"], trackingMode: .selectOne, target: nil, action: nil)
    private let container = NSView()

    init(context: ProjectContext) {
        self.context = context
        tree = FileTreeController(context: context)
        structure = StructureController(context: context)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.sidebarBackground.cgColor
        segmented.selectedSegment = 0
        segmented.target = self
        segmented.action = #selector(switchView)
        segmented.controlSize = .small
        segmented.segmentStyle = .texturedRounded
        for v in [segmented, container] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            segmented.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            segmented.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            container.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 6),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
        ])
        view = root
        addChild(tree)
        addChild(structure)
        show(tree)
    }

    private func show(_ vc: NSViewController) {
        container.subviews.forEach { $0.removeFromSuperview() }
        let v = vc.view
        v.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: container.topAnchor),
            v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            v.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    @objc private func switchView() {
        if segmented.selectedSegment == 0 { show(tree) } else { show(structure); structure.reload() }
    }

    func showStructure() {
        segmented.selectedSegment = 1
        switchView()
    }

    func didActivate(_ editor: EditorController) {
        tree.reveal(editor.document.url)
        structure.editorChanged(editor)
    }
}

/// File system node for the outline view.
@MainActor
final class FileNode: NSObject {
    let url: URL
    let isDirectory: Bool
    weak var parent: FileNode?
    private var loaded: [FileNode]?

    init(url: URL, isDirectory: Bool, parent: FileNode?) {
        self.url = url
        self.isDirectory = isDirectory
        self.parent = parent
    }

    static let hidden: Set<String> = [".git", ".DS_Store", ".idea", ".build", ".swiftpm", "node_modules"]

    var children: [FileNode] {
        if let loaded { return loaded }
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
        let nodes = items.filter { !Self.hidden.contains($0.lastPathComponent) }.map { u -> FileNode in
            let dir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return FileNode(url: u.standardizedFileURL, isDirectory: dir, parent: self)
        }.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
        }
        loaded = nodes
        return nodes
    }

    func invalidate() { loaded = nil }
    var isLoaded: Bool { loaded != nil }
    var cachedChildren: [FileNode] { loaded ?? [] }
}

@MainActor
final class FileTreeController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    let context: ProjectContext
    private let outline = NSOutlineView()
    private var root: FileNode!
    private var reloadTimer: Timer?
    private var pendingDirs = Set<URL>()

    init(context: ProjectContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
        root = FileNode(url: context.root, isDirectory: true, parent: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let col = NSTableColumn(identifier: .init("name"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.rowHeight = 22
        outline.indentationPerLevel = 14
        outline.backgroundColor = Theme.sidebarBackground
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked)
        outline.action = #selector(clicked)
        outline.style = .sourceList
        outline.autosaveExpandedItems = false
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        view = scroll
        outline.reloadData()
        outline.expandItem(nil)
        NotificationCenter.default.addObserver(forName: .ogFilesChanged, object: context, queue: .main) { [weak self] n in
            let info = n.userInfo as? [String: any Sendable] ?? [:]
            MainActor.assumeIsolated {
                let paths = info["paths"] as? [String] ?? []
                self?.filesChanged(paths)
            }
        }
        NotificationCenter.default.addObserver(forName: .ogGitStatusChanged, object: context, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.outline.reloadData() }
        }
        NotificationCenter.default.addObserver(forName: .ogDiagnosticsChanged, object: context, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.outline.needsDisplay = true }
        }
    }

    // MARK: - Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? FileNode ?? root).children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? FileNode ?? root).children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isDirectory ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let cell = NSTableCellView()
        let icon = NSImageView()
        let ext = node.url.pathExtension
        if node.isDirectory {
            icon.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
            icon.contentTintColor = NSColor(srgbRed: 0.55, green: 0.62, blue: 0.72, alpha: 1)
        } else if ext == "go" {
            icon.image = NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right", accessibilityDescription: nil)
            icon.contentTintColor = NSColor(srgbRed: 0.0, green: 0.68, blue: 0.85, alpha: 1)
        } else if node.url.lastPathComponent == "go.mod" || node.url.lastPathComponent == "go.sum" || node.url.lastPathComponent == "go.work" {
            icon.image = NSImage(systemSymbolName: "shippingbox", accessibilityDescription: nil)
            icon.contentTintColor = Theme.type
        } else {
            icon.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
            icon.contentTintColor = Theme.secondaryText
        }
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        let label = NSTextField(labelWithString: node.url.lastPathComponent)
        label.font = Theme.uiFont
        label.lineBreakMode = .byTruncatingTail
        label.textColor = color(for: node)
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        cell.textField = label
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16),
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    private func color(for node: FileNode) -> NSColor {
        let rel = context.relativePath(node.url)
        if !node.isDirectory, context.diagnostics[node.url.lspURI]?.contains(where: { $0.severity == .error }) == true { return Theme.error }
        if let state = context.gitStatus.files[rel] {
            switch state {
            case .modified, .renamed: return Theme.gitModified
            case .added: return Theme.gitAdded
            case .untracked: return Theme.gitUntracked
            case .conflicted: return Theme.error
            case .deleted, .ignored: return Theme.gitDeleted
            }
        }
        if node.isDirectory, context.gitStatus.files.keys.contains(where: { $0.hasPrefix(rel + "/") }) { return Theme.gitModified }
        return Theme.text
    }

    // MARK: - Actions

    @objc private func clicked() {
        guard let node = outline.item(atRow: outline.clickedRow) as? FileNode, !node.isDirectory else { return }
        context.open(node.url)
    }

    @objc private func doubleClicked() {
        guard let node = outline.item(atRow: outline.clickedRow) as? FileNode else { return }
        if node.isDirectory {
            if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
        } else {
            context.open(node.url)
        }
    }

    func reveal(_ url: URL) {
        let target = url.standardizedFileURL
        var chain: [URL] = []
        var u = target.deletingLastPathComponent()
        while u.path.count >= context.root.path.count, u.path != context.root.path {
            chain.insert(u, at: 0)
            u = u.deletingLastPathComponent()
        }
        var node: FileNode = root
        for dir in chain {
            guard let next = node.children.first(where: { $0.url == dir }) else { return }
            outline.expandItem(next)
            node = next
        }
        guard let leaf = node.children.first(where: { $0.url == target }) else { return }
        let row = outline.row(forItem: leaf)
        if row >= 0 {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        }
    }

    var selectedDirectory: URL {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        guard let node = outline.item(atRow: row) as? FileNode else { return context.root }
        return node.isDirectory ? node.url : node.url.deletingLastPathComponent()
    }

    private func filesChanged(_ paths: [String]) {
        for p in paths { pendingDirs.insert(URL(fileURLWithPath: p).deletingLastPathComponent().standardizedFileURL) }
        reloadTimer?.invalidate()
        reloadTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyPendingReloads() }
        }
    }

    private func applyPendingReloads() {
        let dirs = pendingDirs
        pendingDirs.removeAll()
        let expanded = expandedURLs()
        for dir in dirs {
            if dir == context.root { root.invalidate(); outline.reloadData(); restoreExpanded(expanded); return }
            if let node = findLoaded(dir, in: root) {
                node.invalidate()
                outline.reloadItem(node, reloadChildren: true)
            }
        }
        restoreExpanded(expanded)
    }

    private func expandedURLs() -> Set<URL> {
        var out = Set<URL>()
        for row in 0..<outline.numberOfRows {
            if let n = outline.item(atRow: row) as? FileNode, outline.isItemExpanded(n) { out.insert(n.url) }
        }
        return out
    }

    private func restoreExpanded(_ urls: Set<URL>) {
        var row = 0
        while row < outline.numberOfRows {
            if let n = outline.item(atRow: row) as? FileNode, urls.contains(n.url), !outline.isItemExpanded(n) { outline.expandItem(n) }
            row += 1
        }
    }

    private func findLoaded(_ url: URL, in node: FileNode) -> FileNode? {
        if node.url == url { return node }
        guard node.isLoaded, url.path.hasPrefix(node.url.path) else { return nil }
        for c in node.cachedChildren where c.isDirectory {
            if let f = findLoaded(url, in: c) { return f }
        }
        return nil
    }

    // MARK: - Context menu (FT-2)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let add: (String, Selector) -> Void = { title, sel in
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            i.target = self
            menu.addItem(i)
        }
        add("New Go File…", #selector(newFile))
        add("New Directory…", #selector(newDirectory))
        menu.addItem(.separator())
        add("Rename…", #selector(renameItem))
        add("Delete", #selector(deleteItem))
        menu.addItem(.separator())
        add("Run Tests in Directory", #selector(runTests))
        add("Open in Terminal", #selector(openInTerminal))
        add("Reveal in Finder", #selector(revealInFinder))
        add("Copy Path", #selector(copyPath))
    }

    private var clickedNode: FileNode? { outline.item(atRow: outline.clickedRow) as? FileNode }

    @objc func newFile() {
        let dir = selectedDirectory
        guard let name = prompt("New Go file", placeholder: "name.go") else { return }
        let fileName = name.contains(".") ? name : name + ".go"
        let url = dir.appendingPathComponent(fileName)
        guard !FileManager.default.fileExists(atPath: url.path) else { context.setStatus("\(fileName) already exists"); return }
        let pkg = Self.packageName(for: dir)
        let content = fileName.hasSuffix(".go") ? "package \(pkg)\n\n" : ""
        do {
            try Data(content.utf8).write(to: url, options: .atomic)
            context.open(url, line: 2, column: 0)
            filesChanged([url.path])
        } catch {
            context.setStatus(error.localizedDescription)
        }
    }

    static func packageName(for dir: URL) -> String {
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(atPath: dir.path) {
            for f in files where f.hasSuffix(".go") && !f.hasSuffix("_test.go") {
                if let text = try? String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8) {
                    for line in text.split(separator: "\n", maxSplits: 50) where line.hasPrefix("package ") {
                        return String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces)
                    }
                }
            }
        }
        if fm.fileExists(atPath: dir.appendingPathComponent("go.mod").path) { return "main" }
        let n = dir.lastPathComponent.lowercased().filter { $0.isLetter || $0.isNumber }
        return n.isEmpty ? "main" : n
    }

    @objc private func newDirectory() {
        let dir = selectedDirectory
        guard let name = prompt("New directory", placeholder: "name") else { return }
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent(name), withIntermediateDirectories: true)
        filesChanged([dir.appendingPathComponent(name).path])
    }

    @objc private func renameItem() {
        guard let node = clickedNode else { return }
        guard let name = prompt("Rename", placeholder: node.url.lastPathComponent, initial: node.url.lastPathComponent), name != node.url.lastPathComponent else { return }
        let dest = node.url.deletingLastPathComponent().appendingPathComponent(name)
        // ASSUME-4: an open tab follows the file; save it first.
        if let doc = context.documents.document(for: node.url) { context.documents.save(doc) }
        do {
            try FileManager.default.moveItem(at: node.url, to: dest)
            let wasOpen = context.documents.document(for: node.url) != nil
            context.window?.editorArea.closeEditors(for: node.url)
            if wasOpen && !node.isDirectory { context.open(dest) }
            filesChanged([node.url.path, dest.path])
        } catch {
            context.setStatus(error.localizedDescription)
        }
    }

    @objc private func deleteItem() {
        guard let node = clickedNode else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \(node.url.lastPathComponent)?"
        alert.informativeText = "The item will be moved to the Trash."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        context.window?.editorArea.closeEditors(for: node.url)
        do {
            try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
            filesChanged([node.url.path])
        } catch {
            context.setStatus(error.localizedDescription)
        }
    }

    @objc private func runTests() { context.run(.test(packageDir: selectedDirectory, name: nil)) }

    @objc private func openInTerminal() {
        let panel = context.window?.bottomPanel.terminalPanel
        panel?.newTab()
        panel?.run(command: "cd " + Self.shellQuote(selectedDirectory.path))
        context.showPanel(.terminal)
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    @objc private func revealInFinder() {
        let url = clickedNode?.url ?? context.root
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func copyPath() {
        let url = clickedNode?.url ?? context.root
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    private func prompt(_ title: String, placeholder: String, initial: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = placeholder
        field.stringValue = initial
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let v = field.stringValue.trimmingCharacters(in: .whitespaces)
        return v.isEmpty || v.contains("/") ? nil : v
    }
}

/// Document symbols of the active file.
@MainActor
final class StructureController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let context: ProjectContext
    private let outline = NSOutlineView()
    private var symbols: [SymbolNode] = []
    private weak var editor: EditorController?
    private var task: Task<Void, Never>?

    final class SymbolNode: NSObject {
        let symbol: LSPSymbol
        let children: [SymbolNode]
        init(_ s: LSPSymbol) { symbol = s; children = s.children.map(SymbolNode.init) }
    }

    init(context: ProjectContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let col = NSTableColumn(identifier: .init("s"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.rowHeight = 22
        outline.backgroundColor = Theme.sidebarBackground
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked)
        outline.style = .sourceList
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        view = scroll
        NotificationCenter.default.addObserver(forName: .ogDocumentSaved, object: context, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func editorChanged(_ editor: EditorController) {
        self.editor = editor
        if isViewLoaded, view.window != nil { reload() }
    }

    func reload() {
        guard let editor, editor.document.isGo else { symbols = []; if isViewLoaded { outline.reloadData() }; return }
        let uri = editor.document.uri
        context.documents.syncToGopls(editor.document)
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            let syms = await self.context.gopls.documentSymbols(uri: uri)
            guard !Task.isCancelled else { return }
            self.symbols = syms.map(SymbolNode.init)
            self.outline.reloadData()
            self.outline.expandItem(nil, expandChildren: true)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SymbolNode)?.children.count ?? symbols.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SymbolNode)?.children[index] ?? symbols[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? SymbolNode)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SymbolNode else { return nil }
        let kind = NSTextField(labelWithString: node.symbol.kindLabel)
        kind.font = Theme.smallFont
        kind.textColor = node.symbol.kind == 12 || node.symbol.kind == 6 ? Theme.function : Theme.type
        let name = NSTextField(labelWithString: node.symbol.name)
        name.font = Theme.uiFont
        name.textColor = Theme.text
        let detail = NSTextField(labelWithString: node.symbol.detail ?? "")
        detail.font = Theme.smallFont
        detail.textColor = Theme.secondaryText
        detail.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [kind, name, detail])
        stack.spacing = 6
        return stack
    }

    @objc private func clicked() {
        guard let node = outline.item(atRow: outline.clickedRow) as? SymbolNode, let editor else { return }
        let r = node.symbol.selectionRange
        editor.reveal(line: r.start.line, column: r.start.character, length: 0)
        editor.focus()
    }
}
