import AppKit
import OgCore

/// Bottom "Commit" tool window: changed files with checkboxes, a colored diff preview of the
/// selected file, commit message + Commit, Rollback and Refresh. Also hosts the branch popup.
///
/// Every operation re-checks the real working tree inside `GitService` (spec/design/vcs.fsl DES-2);
/// the cached `context.gitStatus` is only used for display.
@MainActor
final class GitPanel: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSplitViewDelegate {
    let context: ProjectContext

    private struct Row: Equatable {
        let path: String
        let state: GitFileState
    }

    private var rows: [Row] = []
    /// Paths ticked for commit (kept across refreshes while the file stays changed).
    private var checked: Set<String> = []
    /// Every path we have seen, so newly appearing files get the default tick.
    private var known: Set<String> = []
    private var isRepository: Bool?
    private var busy = false { didSet { updateButtons() } }
    private var diffTask: Task<Void, Never>?
    private var diffPath: String?
    private var didPositionDivider = false

    private let table = NSTableView()
    private let diffView = NSTextView()
    private let messageView = CommitMessageView()
    private let placeholder = NSTextField(labelWithString: "Commit message  (⌘↩ to commit)")
    private let commitButton = NSButton(title: "Commit", target: nil, action: nil)
    private let rollbackButton = NSButton()
    private let refreshButton = NSButton()
    private let allCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let summary = NSTextField(labelWithString: "")
    private let branchLabel = NSTextField(labelWithString: "")
    private let split = NSSplitView()
    private let notRepoLabel = NSTextField(labelWithString: "Not a git repository")

    init(context: ProjectContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - View

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.panelBackground.cgColor

        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(makeLeftPane())
        split.addArrangedSubview(makeDiffPane())
        split.setHoldingPriority(.defaultLow + 1, forSubviewAt: 0)
        root.addSubview(split)

        notRepoLabel.font = Theme.uiFont
        notRepoLabel.textColor = Theme.secondaryText
        notRepoLabel.translatesAutoresizingMaskIntoConstraints = false
        notRepoLabel.isHidden = true
        root.addSubview(notRepoLabel)

        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: root.topAnchor),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            notRepoLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            notRepoLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        view = root

        NotificationCenter.default.addObserver(forName: .ogGitStatusChanged, object: context, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.statusChanged() }
        }
        statusChanged()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if !didPositionDivider, split.bounds.width > 100 {
            didPositionDivider = true
            split.setPosition(max(260, split.bounds.width * 0.4), ofDividerAt: 0)
        }
    }

    private func makeLeftPane() -> NSView {
        let pane = NSView()

        // Toolbar
        allCheckbox.target = self
        allCheckbox.action = #selector(toggleAll)
        allCheckbox.toolTip = "Select all"
        allCheckbox.allowsMixedState = true
        configureIconButton(refreshButton, symbol: "arrow.clockwise", tip: "Refresh", action: #selector(refreshClicked))
        configureIconButton(rollbackButton, symbol: "arrow.uturn.backward", tip: "Rollback selected files…", action: #selector(rollbackClicked))
        summary.font = Theme.smallFont
        summary.textColor = Theme.secondaryText
        summary.lineBreakMode = .byTruncatingTail
        branchLabel.font = Theme.smallFont
        branchLabel.textColor = Theme.secondaryText
        branchLabel.lineBreakMode = .byTruncatingMiddle
        branchLabel.alignment = .right
        branchLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let toolbar = NSStackView(views: [allCheckbox, refreshButton, rollbackButton, summary, NSView(), branchLabel])
        toolbar.orientation = .horizontal
        toolbar.spacing = 6
        toolbar.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        // File list
        let col = NSTableColumn(identifier: .init("file"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 20
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = Theme.panelBackground
        table.allowsMultipleSelection = true
        table.style = .plain
        table.focusRingType = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openClicked)
        table.menu = makeContextMenu()
        let tableScroll = NSScrollView()
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.drawsBackground = false
        tableScroll.borderType = .noBorder
        tableScroll.translatesAutoresizingMaskIntoConstraints = false

        // Commit message
        messageView.isRichText = false
        messageView.font = Theme.uiFont
        messageView.textColor = Theme.text
        messageView.insertionPointColor = Theme.text
        messageView.backgroundColor = Theme.background
        messageView.drawsBackground = true
        messageView.isAutomaticQuoteSubstitutionEnabled = false
        messageView.isAutomaticDashSubstitutionEnabled = false
        messageView.textContainerInset = NSSize(width: 4, height: 6)
        messageView.isVerticallyResizable = true
        messageView.autoresizingMask = [.width]
        messageView.textContainer?.widthTracksTextView = true
        messageView.onCommit = { [weak self] in self?.commitClicked() }
        messageView.onChange = { [weak self] in self?.messageChanged() }
        let messageScroll = NSScrollView()
        messageScroll.documentView = messageView
        messageScroll.hasVerticalScroller = true
        messageScroll.borderType = .noBorder
        messageScroll.backgroundColor = Theme.background
        messageScroll.translatesAutoresizingMaskIntoConstraints = false
        placeholder.font = Theme.uiFont
        placeholder.textColor = Theme.secondaryText
        placeholder.translatesAutoresizingMaskIntoConstraints = false

        commitButton.target = self
        commitButton.action = #selector(commitClicked)
        commitButton.bezelStyle = .rounded
        commitButton.keyEquivalent = ""
        commitButton.controlSize = .regular
        commitButton.translatesAutoresizingMaskIntoConstraints = false

        let topBorder = separator()
        let midBorder = separator()
        for v in [toolbar, topBorder, tableScroll, midBorder, messageScroll, commitButton] { pane.addSubview(v) }
        pane.addSubview(placeholder)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: pane.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 28),
            topBorder.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            topBorder.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            topBorder.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            tableScroll.topAnchor.constraint(equalTo: topBorder.bottomAnchor),
            tableScroll.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            tableScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
            midBorder.topAnchor.constraint(equalTo: tableScroll.bottomAnchor),
            midBorder.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            midBorder.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            messageScroll.topAnchor.constraint(equalTo: midBorder.bottomAnchor),
            messageScroll.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            messageScroll.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            messageScroll.heightAnchor.constraint(equalToConstant: 64),
            placeholder.topAnchor.constraint(equalTo: messageScroll.topAnchor, constant: 6),
            placeholder.leadingAnchor.constraint(equalTo: messageScroll.leadingAnchor, constant: 9),
            commitButton.topAnchor.constraint(equalTo: messageScroll.bottomAnchor, constant: 6),
            commitButton.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 8),
            commitButton.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -6),
            pane.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
        return pane
    }

    private func makeDiffPane() -> NSView {
        diffView.isEditable = false
        diffView.isSelectable = true
        diffView.isRichText = true
        diffView.drawsBackground = true
        diffView.backgroundColor = Theme.background
        diffView.textContainerInset = NSSize(width: 6, height: 6)
        diffView.isHorizontallyResizable = true
        diffView.isVerticallyResizable = true
        diffView.autoresizingMask = []
        diffView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        diffView.textContainer?.widthTracksTextView = false
        diffView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let scroll = NSScrollView()
        scroll.documentView = diffView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .noBorder
        scroll.backgroundColor = Theme.background
        showDiffPlaceholder("Select a file to see its changes")
        return scroll
    }

    private func separator() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = Theme.border.cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return v
    }

    private func configureIconButton(_ b: NSButton, symbol: String, tip: String, action: Selector) {
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        b.imagePosition = .imageOnly
        b.isBordered = false
        b.bezelStyle = .recessed
        b.contentTintColor = Theme.text
        b.toolTip = tip
        b.target = self
        b.action = action
        b.setContentHuggingPriority(.required, for: .horizontal)
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open", action: #selector(openClicked), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Rollback…", action: #selector(rollbackClicked), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Refresh", action: #selector(refreshClicked), keyEquivalent: "").target = self
        return menu
    }

    // MARK: - Public API

    /// Shows the commit view (changed files with checkboxes + message).
    func focusCommit() {
        _ = view
        context.refreshGit()
        view.window?.makeFirstResponder(messageView)
    }

    /// Shows a branch popup (checkout / new branch / stash) anchored to a view.
    func showBranchMenu(from anchor: NSView) {
        let git = context.git
        Task { [weak self, weak anchor] in
            guard await git.isRepository() else {
                self?.context.setStatus("Not a git repository")
                return
            }
            let branches = await git.branches()
            let status = await git.status()
            guard let self, let anchor, anchor.window != nil else { return }
            let menu = self.makeBranchMenu(branches: branches, current: status.branch, hasStash: status.hasStash)
            let point = NSPoint(x: 0, y: anchor.isFlipped ? anchor.bounds.height + 2 : -2)
            menu.popUp(positioning: nil, at: point, in: anchor)
        }
    }

    private func makeBranchMenu(branches: [String], current: String?, hasStash: Bool) -> NSMenu {
        let menu = NSMenu(title: "Branches")
        menu.autoenablesItems = false
        let header = NSMenuItem(title: "Local Branches", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if let current, !branches.contains(current) {
            let item = NSMenuItem(title: current, action: nil, keyEquivalent: "")
            item.state = .on
            item.isEnabled = false
            menu.addItem(item)
        }
        for name in branches {
            let item = NSMenuItem(title: name, action: #selector(checkoutItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.state = name == current ? .on : .off
            item.indentationLevel = 1
            item.isEnabled = !busy
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let newBranch = NSMenuItem(title: "New Branch…", action: #selector(newBranchItem), keyEquivalent: "")
        newBranch.target = self
        newBranch.isEnabled = !busy
        menu.addItem(newBranch)
        menu.addItem(.separator())
        let stash = NSMenuItem(title: "Stash Changes", action: #selector(stashItem), keyEquivalent: "")
        stash.target = self
        stash.isEnabled = !busy && !hasStash
        if hasStash { stash.toolTip = "A stash already exists; unstash it first." }
        menu.addItem(stash)
        let unstash = NSMenuItem(title: "Unstash", action: #selector(unstashItem), keyEquivalent: "")
        unstash.target = self
        unstash.isEnabled = !busy && hasStash
        menu.addItem(unstash)
        return menu
    }

    // MARK: - Status

    private func statusChanged() {
        let status = context.gitStatus
        if status.branch != nil {
            isRepository = true
            reload()
        } else {
            let git = context.git
            Task { [weak self] in
                let repo = await git.isRepository()
                guard let self else { return }
                self.isRepository = repo
                self.reload()
            }
        }
    }

    private func reload() {
        let repo = isRepository ?? false
        notRepoLabel.isHidden = repo || isRepository == nil
        split.isHidden = !repo
        let status = context.gitStatus
        branchLabel.stringValue = status.branch.map { "⎇ " + $0 } ?? ""

        let selectedPaths = Set(table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0].path : nil })
        let newRows = status.files
            .filter { $0.value != .ignored }
            .map { Row(path: $0.key, state: $0.value) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let paths = Set(newRows.map(\.path))
        // Default tick: tracked changes yes, untracked (unversioned) files no — like GoLand.
        for row in newRows where !known.contains(row.path) && row.state != .untracked {
            checked.insert(row.path)
        }
        known = paths
        checked.formIntersection(paths)
        if newRows != rows {
            rows = newRows
            table.reloadData()
            let keep = IndexSet(rows.indices.filter { selectedPaths.contains(rows[$0].path) })
            table.selectRowIndexes(keep, byExtendingSelection: false)
        } else {
            refreshCheckboxes()
        }
        updateSummary()
        updateButtons()
        // Keep the diff preview current.
        if let p = diffPath {
            if paths.contains(p) { loadDiff(p) } else { diffPath = nil; showDiffPlaceholder("Select a file to see its changes") }
        } else if rows.isEmpty {
            showDiffPlaceholder(repo ? "No local changes" : "")
        }
    }

    private func refreshCheckboxes() {
        for r in 0..<rows.count {
            (table.view(atColumn: 0, row: r, makeIfNecessary: false) as? GitFileCell)?.checkbox.state = checked.contains(rows[r].path) ? .on : .off
        }
    }

    private func updateSummary() {
        let n = rows.count
        summary.stringValue = n == 0 ? "No changes" : "\(checked.count) of \(n) selected"
        if n == 0 || checked.isEmpty { allCheckbox.state = .off } else if checked.count == n { allCheckbox.state = .on } else { allCheckbox.state = .mixed }
    }

    private func updateButtons() {
        let message = messageView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        commitButton.isEnabled = !busy && !checked.isEmpty && !message.isEmpty
        let count = checked.count
        commitButton.title = count > 1 ? "Commit \(count) Files" : "Commit"
        rollbackButton.isEnabled = !busy && !table.selectedRowIndexes.isEmpty
        refreshButton.isEnabled = !busy
        allCheckbox.isEnabled = !rows.isEmpty
    }

    private func messageChanged() {
        placeholder.isHidden = !messageView.string.isEmpty
        updateButtons()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        let cell = (tableView.makeView(withIdentifier: GitFileCell.identifier, owner: self) as? GitFileCell) ?? GitFileCell()
        let item = rows[row]
        cell.configure(path: item.path, state: item.state, checked: checked.contains(item.path))
        cell.checkbox.target = self
        cell.checkbox.action = #selector(checkboxToggled(_:))
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
        let sel = table.selectedRowIndexes
        guard sel.count == 1, let r = sel.first, r < rows.count else {
            if sel.isEmpty { diffPath = nil; showDiffPlaceholder("Select a file to see its changes") }
            return
        }
        loadDiff(rows[r].path)
    }

    @objc private func checkboxToggled(_ sender: NSButton) {
        let r = table.row(for: sender)
        guard r >= 0, r < rows.count else { return }
        let p = rows[r].path
        if sender.state == .on { checked.insert(p) } else { checked.remove(p) }
        updateSummary()
        updateButtons()
    }

    @objc private func toggleAll() {
        if checked.count == rows.count { checked.removeAll() } else { checked = Set(rows.map(\.path)) }
        refreshCheckboxes()
        updateSummary()
        updateButtons()
    }

    // MARK: - Diff preview

    private func loadDiff(_ path: String) {
        diffPath = path
        diffTask?.cancel()
        let git = context.git
        diffTask = Task { [weak self] in
            let text = await git.diff(relativePath: path)
            guard !Task.isCancelled, let self, self.diffPath == path else { return }
            self.showDiff(text, path: path)
        }
    }

    private func showDiffPlaceholder(_ text: String) {
        diffView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: Theme.uiFont, .foregroundColor: Theme.secondaryText,
        ]))
    }

    private func showDiff(_ text: String, path: String) {
        guard !text.isEmpty else {
            showDiffPlaceholder("No textual changes in \(path)")
            return
        }
        let limit = 400_000
        let body = text.utf8.count > limit ? String(decoding: Array(text.utf8.prefix(limit)), as: UTF8.self) + "\n… diff truncated …\n" : text
        diffView.textStorage?.setAttributedString(Self.colorize(diff: body))
        diffView.scrollToBeginningOfDocument(nil)
    }

    static func colorize(diff: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let font = Theme.editorFont
        let bold = Theme.editorBoldFont
        let addedBG = Theme.gitAdded.withAlphaComponent(0.14)
        let deletedBG = Theme.error.withAlphaComponent(0.12)
        let deletedFG = NSColor(srgbRed: 0.85, green: 0.45, blue: 0.45, alpha: 1)
        var inHeader = true
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.text]
            if line.hasPrefix("diff --git") {
                inHeader = true
                attrs[.font] = bold
                attrs[.foregroundColor] = Theme.secondaryText
            } else if line.hasPrefix("@@") {
                inHeader = false
                attrs[.foregroundColor] = Theme.info
            } else if inHeader {
                attrs[.foregroundColor] = Theme.secondaryText
            } else if line.hasPrefix("+") {
                attrs[.foregroundColor] = Theme.gitAdded
                attrs[.backgroundColor] = addedBG
            } else if line.hasPrefix("-") {
                attrs[.foregroundColor] = deletedFG
                attrs[.backgroundColor] = deletedBG
            } else if line.hasPrefix("\\") {
                attrs[.foregroundColor] = Theme.secondaryText
            }
            out.append(NSAttributedString(string: String(line) + "\n", attributes: attrs))
        }
        return out
    }

    // MARK: - Actions

    @objc private func refreshClicked() {
        context.refreshGit()
        if let p = diffPath { loadDiff(p) }
    }

    @objc private func openClicked() {
        let r = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard r >= 0, r < rows.count, rows[r].state != .deleted else { return }
        context.open(context.root.appendingPathComponent(rows[r].path))
    }

    @objc func commitClicked() {
        guard !busy else { return }
        let message = messageView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let paths = rows.map(\.path).filter { checked.contains($0) }
        guard !paths.isEmpty else {
            showError("Nothing to commit", "Select at least one changed file.")
            return
        }
        guard !message.isEmpty else {
            showError("Commit message is empty", "Enter a commit message.")
            view.window?.makeFirstResponder(messageView)
            return
        }
        // ASSUME-2: autosave everything first so git sees what the editor shows.
        guard context.saveAll() else {
            showError("Cannot commit", "Some files could not be saved. Resolve the save problems first.")
            return
        }
        busy = true
        let git = context.git
        Task { [weak self] in
            do {
                try await git.commit(paths: paths, message: message)
                guard let self else { return }
                self.messageView.string = ""
                self.messageChanged()
                self.context.setStatus(paths.count == 1 ? "Committed \(paths[0])" : "Committed \(paths.count) files")
            } catch {
                self?.showError("Commit failed", error.localizedDescription)
            }
            self?.busy = false
            self?.context.refreshGit()
        }
    }

    @objc private func rollbackClicked() {
        guard !busy else { return }
        var indexes = table.selectedRowIndexes
        if table.clickedRow >= 0, !indexes.contains(table.clickedRow) { indexes = IndexSet(integer: table.clickedRow) }
        let targets = indexes.compactMap { $0 < rows.count ? rows[$0] : nil }
        guard !targets.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = targets.count == 1 ? "Rollback \(targets[0].path)?" : "Rollback \(targets.count) files?"
        alert.informativeText = "All local changes to the selected files will be discarded. Added files are unstaged and kept on disk."
        alert.addButton(withTitle: "Rollback")
        alert.addButton(withTitle: "Cancel")
        runAlert(alert) { [weak self] ok in
            guard ok, let self else { return }
            self.performRollback(targets.map(\.path))
        }
    }

    private func performRollback(_ paths: [String]) {
        busy = true
        // Drop pending autosaves of these files so they cannot overwrite the restored content (DES-4).
        for p in paths {
            if let doc = context.documents.document(for: url(p)) { doc.markSaved(doc.text) }
        }
        let git = context.git
        Task { [weak self] in
            var failures: [String] = []
            for p in paths {
                do { try await git.rollback(relativePath: p) } catch { failures.append(error.localizedDescription) }
            }
            guard let self else { return }
            for p in paths { self.reloadFromDisk(self.url(p)) }
            self.busy = false
            self.context.refreshGit()
            if !failures.isEmpty {
                self.showError("Rollback failed", failures.joined(separator: "\n\n"))
            } else {
                self.context.setStatus(paths.count == 1 ? "Rolled back \(paths[0])" : "Rolled back \(paths.count) files")
            }
        }
    }

    // MARK: - Branch menu actions

    @objc private func checkoutItem(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        runOperation("Checkout failed", success: "Checked out \(name)") { git in
            try await git.checkout(branch: name)
        }
    }

    @objc private func newBranchItem() {
        let alert = NSAlert()
        alert.messageText = "New Branch"
        alert.informativeText = "Create a branch from the current HEAD and switch to it. Local changes are kept."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "feature/name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        runAlert(alert) { [weak self] ok in
            guard ok, let self else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            self.runOperation("Could not create branch", success: "Switched to new branch \(name)", saveFirst: false) { git in
                try await git.createBranch(name)
            }
        }
    }

    @objc private func stashItem() {
        runOperation("Stash failed", success: "Changes stashed") { git in try await git.stash() }
    }

    @objc private func unstashItem() {
        runOperation("Unstash failed", success: "Stash restored") { git in try await git.stashPop() }
    }

    /// Saves all files (ASSUME-2), runs a working-tree-changing git operation, then reloads open
    /// documents from disk and refreshes the status. Git's message is shown on failure.
    private func runOperation(_ failureTitle: String, success: String, saveFirst: Bool = true,
                              _ body: @escaping @MainActor (GitService) async throws -> Void) {
        guard !busy else { return }
        if saveFirst, !context.saveAll() {
            showError(failureTitle, "Some files could not be saved. Resolve the save problems first.")
            return
        }
        busy = true
        let git = context.git
        Task { [weak self] in
            do {
                try await body(git)
                self?.context.setStatus(success)
            } catch {
                self?.showError(failureTitle, error.localizedDescription)
            }
            guard let self else { return }
            self.busy = false
            let open = self.context.documents.documents.keys.map(\.path)
            if !open.isEmpty { self.context.documents.filesChanged(open) }
            self.context.refreshGit()
        }
    }

    // MARK: - Helpers

    private func url(_ relativePath: String) -> URL {
        context.root.appendingPathComponent(relativePath).standardizedFileURL
    }

    private func reloadFromDisk(_ url: URL) {
        guard let doc = context.documents.document(for: url),
              let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return }
        if text != doc.text {
            if let editor = context.editorController(for: doc) {
                editor.reloadPreservingSelection(text)
            } else {
                doc.replaceAll(with: text)
            }
        }
        doc.markSaved(text)
    }

    private var hostWindow: NSWindow? { view.window ?? context.window?.window }

    private func runAlert(_ alert: NSAlert, _ completion: @escaping @MainActor (Bool) -> Void) {
        if let window = hostWindow {
            alert.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { completion(response == .alertFirstButtonReturn) }
            }
        } else {
            completion(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    private func showError(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        runAlert(alert) { _ in }
    }

    // MARK: - NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, 220)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, splitView.bounds.width - 200)
    }
}

/// One changed file: [x] name  dir  STATUS
@MainActor
final class GitFileCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("GitFileCell")
    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let name = NSTextField(labelWithString: "")
    private let dir = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        name.font = Theme.uiFont
        name.lineBreakMode = .byTruncatingMiddle
        dir.font = Theme.smallFont
        dir.textColor = Theme.secondaryText
        dir.lineBreakMode = .byTruncatingHead
        badge.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        badge.alignment = .right
        name.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        dir.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .horizontal)
        let stack = NSStackView(views: [checkbox, name, dir, NSView(), badge])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        textField = name
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(path: String, state: GitFileState, checked: Bool) {
        let ns = path as NSString
        let parent = ns.deletingLastPathComponent
        dir.stringValue = parent
        dir.isHidden = parent.isEmpty
        let color = Self.color(for: state)
        var attrs: [NSAttributedString.Key: Any] = [.font: Theme.uiFont, .foregroundColor: color]
        if state == .deleted { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        name.attributedStringValue = NSAttributedString(string: ns.lastPathComponent, attributes: attrs)
        badge.textColor = color
        badge.stringValue = Self.letter(for: state)
        checkbox.state = checked ? .on : .off
        toolTip = "\(path) — \(state.rawValue)"
    }

    static func color(for state: GitFileState) -> NSColor {
        switch state {
        case .modified, .renamed: return Theme.gitModified
        case .added: return Theme.gitAdded
        case .deleted: return Theme.gitDeleted
        case .untracked: return Theme.gitUntracked
        case .conflicted: return Theme.error
        case .ignored: return Theme.secondaryText
        }
    }

    static func letter(for state: GitFileState) -> String {
        switch state {
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .untracked: return "U"
        case .conflicted: return "C"
        case .ignored: return "I"
        }
    }
}

/// Commit message editor: ⌘↩ commits; reports edits.
@MainActor
final class CommitMessageView: NSTextView {
    var onCommit: (() -> Void)?
    var onChange: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.keyCode == 36 || event.keyCode == 76 {  // Return / keypad Enter
            onCommit?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func didChangeText() {
        super.didChangeText()
        onChange?()
    }
}
