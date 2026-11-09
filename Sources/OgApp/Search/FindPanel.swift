import AppKit
import OgCore

/// Bottom "Find" tool window: Find in Files / Replace in Files, and LSP location lists
/// (Find Usages, multiple implementations) grouped by file.
@MainActor
final class FindPanel: NSViewController, NSSearchFieldDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let context: ProjectContext

    final class FileNode: NSObject {
        let url: URL
        let relativePath: String
        var hits: [HitNode] = []
        init(url: URL, relativePath: String) { self.url = url; self.relativePath = relativePath }
    }

    final class HitNode: NSObject {
        let hit: SearchHit
        init(_ hit: SearchHit) { self.hit = hit }
    }

    private let queryField = NSSearchField()
    private let replaceField = NSTextField()
    private let maskField = NSTextField()
    private let caseButton = NSButton()
    private let wordButton = NSButton()
    private let regexButton = NSButton()
    private let replaceAllButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private let outline = ResultsOutlineView()
    private var files: [FileNode] = []
    private var searchTask: Task<Void, Never>?
    private var debounceTimer: Timer?
    private var generation = 0
    /// Title of the location list currently shown (nil = find-in-files results).
    private var locationsTitle: String?

    static let resultLimit = 5000

    init(context: ProjectContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Public entry points

    /// Find in files (Cmd-Shift-F); prefills the query.
    func findInFiles(_ query: String) {
        _ = view
        if !query.isEmpty { queryField.stringValue = query }
        locationsTitle = nil
        view.window?.makeFirstResponder(queryField)
        queryField.currentEditor()?.selectAll(nil)
        if !queryField.stringValue.isEmpty { runSearch() }
        // The panel may only become visible after this call; focus again on the next turn.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let w = self.view.window else { return }
                if w.firstResponder !== self.queryField.currentEditor() {
                    w.makeFirstResponder(self.queryField)
                    self.queryField.currentEditor()?.selectAll(nil)
                }
            }
        }
    }

    /// Shows a list of locations (Find Usages / multiple implementations) grouped by file.
    func showResults(title: String, locations: [LSPLocation]) {
        _ = view
        searchTask?.cancel()
        debounceTimer?.invalidate()
        generation += 1
        locationsTitle = title
        var texts: [String: TextLines] = [:]
        var byURL: [URL: FileNode] = [:]
        var order: [FileNode] = []
        let sorted = locations.sorted {
            ($0.uri, $0.range.start.line, $0.range.start.character) < ($1.uri, $1.range.start.line, $1.range.start.character)
        }
        var seen = Set<LSPLocation>()
        for loc in sorted where seen.insert(loc).inserted {
            guard let url = loc.url?.standardizedFileURL else { continue }
            if texts[loc.uri] == nil {
                let text = context.documents.document(for: url)?.text
                    ?? TextSearch.readText(url)?.text
                    ?? ""
                texts[loc.uri] = TextLines(text)
            }
            guard let lines = texts[loc.uri] else { continue }
            let line = loc.range.start.line
            let lineText = line < lines.lineCount ? lines.lineText(line) : ""
            let lineLen = (lineText as NSString).length
            let col = min(loc.range.start.character, lineLen)
            let len = loc.range.end.line == line ? max(0, loc.range.end.character - col) : max(0, lineLen - col)
            var hit = SearchHit(url: url, line: line, column: col, length: len, lineText: lineText)
            if lineLen > TextSearch.maxPreviewLength {
                let start = max(0, col - 120)
                let end = min(lineLen, col + len + 300)
                hit.lineText = (lineText as NSString).substring(with: NSRange(location: start, length: end - start))
                hit.lineTextOffset = start
            }
            let node: FileNode
            if let n = byURL[url] {
                node = n
            } else {
                node = FileNode(url: url, relativePath: context.relativePath(url))
                byURL[url] = node
                order.append(node)
            }
            node.hits.append(HitNode(hit))
        }
        files = order.sorted { $0.relativePath < $1.relativePath }
        reloadOutline()
        let count = files.reduce(0) { $0 + $1.hits.count }
        setStatus("\(title): \(count) result\(count == 1 ? "" : "s") in \(files.count) file\(files.count == 1 ? "" : "s")")
        context.showPanel(.find)
    }

    // MARK: - View

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        Theme.paint(root, background: Theme.panelBackground)

        queryField.placeholderString = "Find in files"
        queryField.font = Theme.editorFont.withSize(12)
        queryField.delegate = self
        queryField.sendsSearchStringImmediately = false
        queryField.sendsWholeSearchString = true
        queryField.target = self
        queryField.action = #selector(querySubmitted)
        (queryField.cell as? NSSearchFieldCell)?.cancelButtonCell = nil

        configureToggle(caseButton, title: "Cc", tip: "Match Case", key: "og.find.case")
        configureToggle(wordButton, title: "W", tip: "Words", key: "og.find.words")
        configureToggle(regexButton, title: ".*", tip: "Regex", key: "og.find.regex")

        maskField.placeholderString = "File mask: *.go, !*_test.go"
        maskField.font = Theme.smallFont
        maskField.delegate = self
        maskField.stringValue = UserDefaults.standard.string(forKey: "og.find.mask") ?? ""
        maskField.toolTip = "Comma-separated file masks; prefix with ! to exclude. Empty = all files."

        replaceField.placeholderString = "Replace with"
        replaceField.font = Theme.editorFont.withSize(12)
        replaceField.toolTip = "For regex searches, $1… refer to capture groups."

        replaceAllButton.title = "Replace All"
        replaceAllButton.bezelStyle = .rounded
        replaceAllButton.controlSize = .small
        replaceAllButton.font = Theme.smallFont
        replaceAllButton.target = self
        replaceAllButton.action = #selector(replaceAll)

        statusLabel.font = Theme.smallFont
        statusLabel.textColor = Theme.secondaryText
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let col = NSTableColumn(identifier: .init("r"))
        col.resizingMask = .autoresizingMask
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.rowHeight = 20
        outline.backgroundColor = Theme.panelBackground
        outline.style = .plain
        outline.indentationPerLevel = 14
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(openClicked)
        outline.onEnter = { [weak self] in self?.openSelected() }
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let toggles = NSStackView(views: [caseButton, wordButton, regexButton])
        toggles.spacing = 2
        for v in [queryField, toggles, maskField, statusLabel, replaceField, replaceAllButton, scroll] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            queryField.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            queryField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            queryField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            queryField.widthAnchor.constraint(equalTo: root.widthAnchor, multiplier: 0.4).withPriority(.defaultHigh),
            toggles.leadingAnchor.constraint(equalTo: queryField.trailingAnchor, constant: 6),
            toggles.centerYAnchor.constraint(equalTo: queryField.centerYAnchor),
            maskField.leadingAnchor.constraint(equalTo: toggles.trailingAnchor, constant: 8),
            maskField.centerYAnchor.constraint(equalTo: queryField.centerYAnchor),
            maskField.widthAnchor.constraint(equalToConstant: 170),
            statusLabel.leadingAnchor.constraint(equalTo: maskField.trailingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -8),
            statusLabel.centerYAnchor.constraint(equalTo: queryField.centerYAnchor),

            replaceField.topAnchor.constraint(equalTo: queryField.bottomAnchor, constant: 4),
            replaceField.leadingAnchor.constraint(equalTo: queryField.leadingAnchor),
            replaceField.trailingAnchor.constraint(equalTo: queryField.trailingAnchor),
            replaceAllButton.leadingAnchor.constraint(equalTo: replaceField.trailingAnchor, constant: 6),
            replaceAllButton.centerYAnchor.constraint(equalTo: replaceField.centerYAnchor),

            scroll.topAnchor.constraint(equalTo: replaceField.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    private func configureToggle(_ b: NSButton, title: String, tip: String, key: String) {
        b.title = title
        b.toolTip = tip
        b.setButtonType(.pushOnPushOff)
        b.bezelStyle = .recessed
        b.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        b.focusRingType = .none
        b.identifier = NSUserInterfaceItemIdentifier(key)
        b.state = UserDefaults.standard.bool(forKey: key) ? .on : .off
        b.target = self
        b.action = #selector(toggleChanged(_:))
    }

    // MARK: - Searching

    private var options: SearchOptions {
        var o = SearchOptions()
        o.caseSensitive = caseButton.state == .on
        o.wholeWord = wordButton.state == .on
        o.regex = regexButton.state == .on
        let mask = maskField.stringValue.trimmingCharacters(in: .whitespaces)
        o.fileGlob = mask.isEmpty ? nil : mask
        return o
    }

    @objc private func toggleChanged(_ sender: NSButton) {
        if let key = sender.identifier?.rawValue { UserDefaults.standard.set(sender.state == .on, forKey: key) }
        runSearch()
    }

    @objc private func querySubmitted() { runSearch() }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === maskField {
            UserDefaults.standard.set(maskField.stringValue, forKey: "og.find.mask")
        }
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.runSearch() }
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) {
            if control === maskField || control === queryField { runSearch(); return true }
        }
        if sel == #selector(NSResponder.moveDown(_:)), control === queryField, !files.isEmpty {
            view.window?.makeFirstResponder(outline)
            if outline.selectedRow < 0 { outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
            return true
        }
        return false
    }

    private func runSearch() {
        debounceTimer?.invalidate()
        searchTask?.cancel()
        generation += 1
        let gen = generation
        locationsTitle = nil
        let query = queryField.stringValue
        let opts = options
        guard !query.isEmpty else {
            files = []
            reloadOutline()
            setStatus("")
            return
        }
        if let err = TextSearch.validate(query, options: opts) {
            setStatus(err, error: true)
            return
        }
        // Search what the user sees: flush unsaved buffers first (autosave model).
        context.saveAll()
        setStatus("Searching…")
        let index = context.index
        let started = Date()
        searchTask = Task { [weak self] in
            await index.refresh()
            let hits = await index.search(query, options: opts, limit: Self.resultLimit)
            guard let self, !Task.isCancelled, gen == self.generation else { return }
            self.show(hits)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let more = hits.count >= Self.resultLimit ? "+ (truncated)" : ""
            self.setStatus("\(hits.count)\(more) match\(hits.count == 1 ? "" : "es") in \(self.files.count) file\(self.files.count == 1 ? "" : "s") · \(ms) ms")
        }
    }

    private func show(_ hits: [SearchHit]) {
        var nodes: [FileNode] = []
        for h in hits {
            if let last = nodes.last, last.url == h.url {
                last.hits.append(HitNode(h))
            } else {
                let n = FileNode(url: h.url, relativePath: context.relativePath(h.url))
                n.hits.append(HitNode(h))
                nodes.append(n)
            }
        }
        files = nodes
        reloadOutline()
    }

    private func reloadOutline() {
        outline.reloadData()
        // Expanding thousands of files at once is slow; expand the first few hundred.
        for f in files.prefix(300) { outline.expandItem(f) }
        if outline.numberOfRows > 0 { outline.scrollRowToVisible(0) }
    }

    private func setStatus(_ text: String, error: Bool = false) {
        statusLabel.stringValue = text
        statusLabel.textColor = error ? Theme.error : Theme.secondaryText
    }

    // MARK: - Replace

    @objc private func replaceAll() {
        let query = queryField.stringValue
        let opts = options
        let replacement = replaceField.stringValue
        guard !query.isEmpty else { return }
        if let err = TextSearch.validate(query, options: opts) { setStatus(err, error: true); return }
        guard context.saveAll() else {
            setStatus("Some files could not be saved; resolve that before replacing.", error: true)
            return
        }
        setStatus("Preparing replacement…")
        let index = context.index
        Task { [weak self] in
            let plans = await index.planReplace(query, options: opts, replacement: replacement)
            guard let self else { return }
            guard !plans.isEmpty else { self.setStatus("No matches to replace"); return }
            let total = plans.reduce(0) { $0 + $1.count }
            let alert = NSAlert()
            alert.messageText = "Replace \(total) occurrence\(total == 1 ? "" : "s") in \(plans.count) file\(plans.count == 1 ? "" : "s")?"
            alert.informativeText = "“\(query)” → “\(replacement)”. Files are rewritten on disk; open editors are reloaded (this cannot be undone with Undo)."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            let apply: @MainActor (NSApplication.ModalResponse) -> Void = { [weak self] resp in
                guard resp == .alertFirstButtonReturn else { self?.setStatus("Replace cancelled"); return }
                self?.apply(plans)
            }
            if let w = self.view.window {
                alert.beginSheetModal(for: w) { resp in MainActor.assumeIsolated { apply(resp) } }
            } else {
                apply(alert.runModal())
            }
        }
    }

    /// Writes each planned file atomically and refreshes its open buffer. Runs synchronously on
    /// the main actor so no keystroke can interleave between the check and the write.
    private func apply(_ plans: [ReplacePlan]) {
        var replaced = 0, filesDone = 0
        var skipped: [String] = []
        for plan in plans {
            let doc = context.documents.document(for: plan.url)
            // Skip files that changed after planning (buffer edited or disk rewritten).
            if let doc, doc.text != plan.original { skipped.append(plan.url.lastPathComponent); continue }
            if doc == nil, TextSearch.readText(plan.url)?.text != plan.original { skipped.append(plan.url.lastPathComponent); continue }
            do {
                try Data(plan.replaced.utf8).write(to: plan.url, options: .atomic)
            } catch {
                skipped.append(plan.url.lastPathComponent)
                continue
            }
            if let doc {
                if let editor = context.editorController(for: doc) {
                    editor.reloadPreservingSelection(plan.replaced)
                } else {
                    doc.replaceAll(with: plan.replaced)
                }
                doc.markSaved(plan.replaced)
            }
            replaced += plan.count
            filesDone += 1
        }
        var msg = "Replaced \(replaced) occurrence\(replaced == 1 ? "" : "s") in \(filesDone) file\(filesDone == 1 ? "" : "s")"
        if !skipped.isEmpty { msg += "; skipped \(skipped.count) changed/unwritable: " + skipped.prefix(5).joined(separator: ", ") }
        context.setStatus(msg)
        // Show what is left (normally nothing, or the replacement text itself).
        runSearch()
        setStatus(msg, error: !skipped.isEmpty)
    }

    // MARK: - Opening

    @objc private func openClicked() {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        open(row: row)
    }

    private func openSelected() { open(row: outline.selectedRow) }

    private func open(row: Int) {
        guard row >= 0 else { return }
        let item = outline.item(atRow: row)
        if let h = item as? HitNode {
            context.open(h.hit.url, line: h.hit.line, column: h.hit.column, length: h.hit.length)
        } else if let f = item as? FileNode {
            if let first = f.hits.first?.hit {
                context.open(f.url, line: first.line, column: first.column, length: first.length)
            } else {
                context.open(f.url)
            }
        }
    }

    // MARK: - Outline data source / delegate

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return files.count }
        return (item as? FileNode)?.hits.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let f = item as? FileNode { return f.hits[index] }
        return files[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is FileNode }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let f = item as? FileNode { return fileCell(f) }
        if let h = item as? HitNode { return hitCell(h.hit) }
        return nil
    }

    private func fileCell(_ f: FileNode) -> NSView {
        let ns = f.relativePath as NSString
        let name = ns.lastPathComponent
        let dir = ns.deletingLastPathComponent
        let s = NSMutableAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: Theme.text])
        if !dir.isEmpty {
            s.append(NSAttributedString(string: "  " + dir, attributes: [.font: Theme.smallFont, .foregroundColor: Theme.secondaryText]))
        }
        s.append(NSAttributedString(string: "  \(f.hits.count)", attributes: [.font: Theme.smallFont, .foregroundColor: Theme.secondaryText]))
        let label = NSTextField(labelWithAttributedString: s)
        label.lineBreakMode = .byTruncatingTail
        let icon = NSImageView(image: QuickPalette.icon(forPath: f.relativePath))
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 4
        return stack
    }

    private func hitCell(_ hit: SearchHit) -> NSView {
        let font = Theme.editorFont.withSize(max(10, Theme.fontSize - 1))
        let s = NSMutableAttributedString(string: String(format: "%4d  ", hit.line + 1),
                                          attributes: [.font: font, .foregroundColor: Theme.lineNumber])
        s.append(Self.preview(hit, font: font))
        let label = NSTextField(labelWithAttributedString: s)
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    /// Line preview with leading whitespace trimmed, clipped around the match, match highlighted.
    static func preview(_ hit: SearchHit, font: NSFont) -> NSAttributedString {
        let line = hit.lineText as NSString
        var start = 0
        while start < line.length, let c = Unicode.Scalar(line.character(at: start)), c == " " || c == "\t" { start += 1 }
        var matchStart = hit.column - hit.lineTextOffset
        matchStart = max(0, min(matchStart, line.length))
        let matchLen = max(0, min(hit.length, line.length - matchStart))
        var prefix = ""
        if hit.lineTextOffset > 0 { prefix = "…" }
        // Keep the match visible on long lines.
        if matchStart - start > 80 { start = matchStart - 40; prefix = "…" }
        start = min(start, matchStart)
        let end = min(line.length, max(matchStart + matchLen + 200, start + 240))
        let visible = line.substring(with: NSRange(location: start, length: end - start))
        let out = NSMutableAttributedString(string: prefix + visible.replacingOccurrences(of: "\t", with: " "),
                                            attributes: [.font: font, .foregroundColor: Theme.text])
        let hl = NSRange(location: (prefix as NSString).length + matchStart - start, length: matchLen)
        if NSMaxRange(hl) <= out.length, hl.length > 0 {
            out.addAttributes([.backgroundColor: Theme.selection, .foregroundColor: NSColor.white], range: hl)
        }
        if end < line.length { out.append(NSAttributedString(string: "…", attributes: [.font: font, .foregroundColor: Theme.secondaryText])) }
        return out
    }
}

/// Outline that opens the selection on Return.
final class ResultsOutlineView: NSOutlineView {
    var onEnter: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onEnter?(); return }
        super.keyDown(with: event)
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ p: NSLayoutConstraint.Priority) -> NSLayoutConstraint { priority = p; return self }
}
