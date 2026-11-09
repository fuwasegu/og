import AppKit
import OgCore

/// The Run tool window: toolbar, `go test -json` result tree, and console.
///
/// DES-2: every launch opens a new `RunGeneration`. Rerun and Stop kill the live
/// process group and close its generation at once; any output or exit event that
/// arrives later from an older generation is dropped, so the view only ever
/// shows the latest run.
@MainActor
final class RunPanel: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let context: ProjectContext

    private let rerunButton = NSButton()
    private let stopButton = NSButton()
    private let titleLabel = NSTextField(labelWithString: "No run yet")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let split = NSSplitView()
    private let outline = NSOutlineView()
    private let treeScroll = NSScrollView()
    private let console = ConsoleView(frame: .zero)

    private var generation = RunGeneration()
    private var process: RunProcess?
    private var lastRequest: RunRequest?
    private var command: RunCommand?
    private var parser: GoTestEventParser?
    private var module: (root: URL, path: String)?
    private var startedAt = Date()
    private var reloadScheduled = false
    private lazy var treeMinWidth: NSLayoutConstraint = {
        let c = treeScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 200)
        c.priority = .init(750)
        return c
    }()
    private lazy var treeIdealWidth: NSLayoutConstraint = {
        let c = treeScroll.widthAnchor.constraint(equalToConstant: 320)
        c.priority = .init(255)
        return c
    }()

    /// Outline items; `id == nil` is the "Test Results" root. Cached for stable identity.
    final class Item: NSObject {
        let id: GoTestNodeID?
        init(_ id: GoTestNodeID?) { self.id = id }
    }
    private let rootItem = Item(nil)
    private var items: [GoTestNodeID: Item] = [:]

    init(context: ProjectContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - View

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        Theme.paint(root, background: Theme.panelBackground)

        configure(rerunButton, symbol: "arrow.clockwise", tip: "Rerun (⌘R)", action: #selector(rerunClicked))
        configure(stopButton, symbol: "stop.fill", tip: "Stop", action: #selector(stopClicked))
        stopButton.contentTintColor = Theme.error
        titleLabel.font = Theme.uiFont
        titleLabel.textColor = Theme.text
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summaryLabel.font = Theme.smallFont
        summaryLabel.textColor = Theme.secondaryText
        summaryLabel.alignment = .right
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let toolbar = NSStackView(views: [rerunButton, stopButton, titleLabel, spacer, summaryLabel])
        toolbar.orientation = .horizontal
        toolbar.spacing = 6
        toolbar.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 10)

        let col = NSTableColumn(identifier: .init("test"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.rowHeight = 20
        outline.indentationPerLevel = 14
        outline.backgroundColor = Theme.panelBackground
        outline.style = .sourceList
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(openSelectedTest)
        treeScroll.documentView = outline
        treeScroll.hasVerticalScroller = true
        treeScroll.autohidesScrollers = true
        treeScroll.drawsBackground = true
        treeScroll.backgroundColor = Theme.panelBackground

        console.resolveLink = { [weak self] link in self?.resolve(link) }
        console.openLink = { [weak self] url, line, col in
            self?.context.open(url, line: max(0, line - 1), column: col.map { max(0, $0 - 1) })
        }

        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(treeScroll)
        split.addArrangedSubview(console)
        split.setHoldingPriority(.init(260), forSubviewAt: 0)
        split.setHoldingPriority(.init(250), forSubviewAt: 1)
        treeScroll.isHidden = true

        let separator = NSBox()
        separator.boxType = .separator
        for v in [toolbar, separator, split] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 28),
            separator.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.topAnchor.constraint(equalTo: separator.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        view = root
        updateControls()
    }

    private func configure(_ b: NSButton, symbol: String, tip: String, action: Selector) {
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        b.imagePosition = .imageOnly
        b.bezelStyle = .recessed
        b.isBordered = false
        b.toolTip = tip
        b.target = self
        b.action = action
        b.widthAnchor.constraint(equalToConstant: 22).isActive = true
    }

    @objc private func rerunClicked() { rerun() }
    @objc private func stopClicked() { stop() }

    // MARK: - Public API

    /// Starts a run / test / bench; shows output and the test tree.
    func run(_ request: RunRequest) {
        _ = view
        killCurrent()
        lastRequest = request
        let gen = generation.begin()
        let cmd = RunCommand(request)
        command = cmd
        module = GoTestLocator.findModule(from: cmd.directory)
        parser = cmd.isTestJSON ? GoTestEventParser() : nil
        items.removeAll()
        startedAt = Date()
        console.clear()
        setTreeVisible(cmd.isTestJSON)
        outline.reloadData()
        titleLabel.stringValue = request.title
        console.appendNote("$ \(cmd.displayString)    (in \(context.relativePath(cmd.directory)))")
        do {
            let proc = try RunProcess(command: cmd, queue: .main)
            process = proc
            try proc.start { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event, generation: gen) }
            }
        } catch {
            process = nil
            generation.close()
            console.appendNote(String(describing: error), color: Theme.error)
            context.setStatus("\(request.title): \(error)")
        }
        updateControls()
    }

    /// Re-runs the last request.
    func rerun() {
        guard let request = lastRequest else { return }
        context.saveAll()
        run(request)
    }

    func stop() {
        guard generation.isOpen else { return }
        killCurrent()
        if var p = parser {
            for o in p.finish() { appendTestOutput(o) }
            parser = p
        }
        console.appendNote("Process stopped", color: Theme.warning)
        reloadTree()
        updateControls()
        context.setStatus("\(lastRequest?.title ?? "Run") stopped")
    }

    var isRunning: Bool { generation.isOpen }

    // MARK: - Process events

    /// Kills the live process (if any) and closes its generation (DES-2).
    private func killCurrent() {
        process?.stop()
        process = nil
        generation.close()
    }

    private func handle(_ event: RunProcess.Event, generation gen: Int) {
        guard generation.accepts(gen) else { return } // stale generation (DES-2)
        switch event {
        case .output(.stdout, let text):
            if var p = parser {
                let outs = p.consume(text)
                parser = p
                for o in outs { appendTestOutput(o) }
                scheduleTreeReload()
            } else {
                console.append(text)
            }
        case .output(.stderr, let text):
            console.append(text, color: Theme.error)
        case .exit(let code):
            finish(exitCode: code)
        }
    }

    private func appendTestOutput(_ o: GoTestEventParser.Output) {
        currentPackage = o.package
        let isFailureFrame = o.text.hasPrefix("--- FAIL") || o.text.hasPrefix("FAIL")
        let isPassFrame = o.text.hasPrefix("--- PASS") || o.text.hasPrefix("ok  ") || o.text == "PASS\n"
        console.append(o.text, color: isFailureFrame ? Theme.error : isPassFrame ? Theme.gitAdded : nil)
    }

    /// Package of the output being appended; used to resolve relative file links.
    private var currentPackage: String?

    private func finish(exitCode: Int32) {
        process = nil
        generation.close()
        if var p = parser {
            for o in p.finish() { appendTestOutput(o) }
            parser = p
        }
        let elapsed = GoTestNode.formatElapsed(Date().timeIntervalSince(startedAt))
        console.appendNote("\nProcess finished with exit code \(exitCode) (\(elapsed))",
                           color: exitCode == 0 ? Theme.secondaryText : Theme.error)
        reloadTree()
        updateControls()
        let title = lastRequest?.title ?? "Run"
        if let report = parser?.report {
            let s = report.summary
            if s.failed > 0 || s.failedPackages > 0 || exitCode != 0 {
                context.setStatus("\(title): tests failed — \(summaryText(s))")
            } else {
                context.setStatus("\(title): tests passed — \(summaryText(s))")
            }
            revealFailures()
        } else {
            context.setStatus("\(title) finished with exit code \(exitCode)")
        }
    }

    private func updateControls() {
        let running = generation.isOpen
        stopButton.isEnabled = running
        stopButton.contentTintColor = running ? Theme.error : Theme.secondaryText.withAlphaComponent(0.5)
        rerunButton.isEnabled = lastRequest != nil
        if let report = parser?.report {
            let s = report.summary
            summaryLabel.attributedStringValue = summaryAttributed(s, running: running)
        } else if running {
            summaryLabel.stringValue = "Running…"
            summaryLabel.textColor = Theme.secondaryText
        } else if lastRequest != nil {
            summaryLabel.stringValue = ""
        }
    }

    private func summaryText(_ s: GoTestReport.Summary) -> String {
        var parts: [String] = []
        if s.failed > 0 { parts.append("\(s.failed) failed") }
        parts.append("\(s.passed) passed")
        if s.skipped > 0 { parts.append("\(s.skipped) skipped") }
        if s.interrupted > 0 { parts.append("\(s.interrupted) interrupted") }
        if s.failedPackages > 0 { parts.append("\(s.failedPackages) package\(s.failedPackages == 1 ? "" : "s") failed to build/run") }
        return parts.joined(separator: ", ")
    }

    private func summaryAttributed(_ s: GoTestReport.Summary, running: Bool) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func add(_ text: String, _ color: NSColor) {
            if out.length > 0 { out.append(NSAttributedString(string: "   ")) }
            out.append(NSAttributedString(string: text, attributes: [.foregroundColor: color, .font: Theme.smallFont]))
        }
        if running { add("Running… \(s.total) tests", Theme.secondaryText) }
        if s.failed > 0 || s.failedPackages > 0 { add("✗ \(s.failed + s.failedPackages) failed", Theme.error) }
        add("✓ \(s.passed) passed", Theme.gitAdded)
        if s.skipped > 0 { add("\(s.skipped) skipped", Theme.secondaryText) }
        if s.interrupted > 0 { add("\(s.interrupted) interrupted", Theme.warning) }
        return out
    }

    // MARK: - Links & locations

    private func directory(forPackage importPath: String?) -> URL? {
        guard let importPath, let module else { return nil }
        return GoTestLocator.directory(forImportPath: importPath, modulePath: module.path, moduleRoot: module.root)
    }

    private func resolve(_ link: ConsoleFileLink) -> URL? {
        var dirs: [URL] = []
        if let d = directory(forPackage: currentPackage) { dirs.append(d) }
        if let d = command?.directory { dirs.append(d) }
        if let m = module?.root { dirs.append(m) }
        dirs.append(context.root)
        return link.resolve(in: dirs)
    }

    @objc private func openSelectedTest() {
        guard let item = outline.item(atRow: outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow) as? Item,
              let id = item.id, !id.isPackage else { return }
        let dir = directory(forPackage: id.package) ?? command?.directory ?? context.root
        if let loc = GoTestLocator.locate(test: id.test, in: dir) {
            context.open(loc.url, line: loc.line)
        } else {
            context.setStatus("Cannot find func \(id.topLevelTest) in \(context.relativePath(dir))")
        }
    }

    // MARK: - Tree

    private func setTreeVisible(_ visible: Bool) {
        guard treeScroll.isHidden == visible else { return }
        treeScroll.isHidden = !visible
        treeMinWidth.isActive = visible
        treeIdealWidth.isActive = visible
        split.adjustSubviews()
    }

    private func scheduleTreeReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reloadScheduled = false
                self.reloadTree()
                self.updateControls()
            }
        }
    }

    private func reloadTree() {
        guard parser != nil else { return }
        let selected = (outline.item(atRow: outline.selectedRow) as? Item)
        outline.reloadData()
        outline.expandItem(rootItem)
        for pkg in visiblePackages { outline.expandItem(item(for: pkg)) }
        if let selected {
            let row = outline.row(forItem: selected)
            if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false) }
        }
    }

    /// Expands the path to every failed test after a run.
    private func revealFailures() {
        guard let report = parser?.report else { return }
        func walk(_ id: GoTestNodeID) {
            guard let node = report[id], node.status == .failed else { return }
            outline.expandItem(item(for: id))
            node.children.forEach(walk)
        }
        visiblePackages.forEach(walk)
    }

    /// Packages, minus `[no test files]` ones.
    private var visiblePackages: [GoTestNodeID] {
        guard let report = parser?.report else { return [] }
        return report.packages.filter { id in
            guard let n = report[id] else { return false }
            return !(n.children.isEmpty && n.status == .skipped)
        }
    }

    /// `example.com/demo/sub` → `demo/sub` (module-relative, like GoLand).
    private func packageDisplayName(_ importPath: String) -> String {
        guard let module, importPath == module.path || importPath.hasPrefix(module.path + "/") else { return importPath }
        let last = module.path.split(separator: "/").last.map(String.init) ?? module.path
        return last + importPath.dropFirst(module.path.count)
    }

    private func item(for id: GoTestNodeID) -> Item {
        if let i = items[id] { return i }
        let i = Item(id)
        items[id] = i
        return i
    }

    private func children(of item: Item?) -> [GoTestNodeID] {
        guard let report = parser?.report, let item else { return [] }
        guard let id = item.id else { return visiblePackages }
        return report.children(of: id)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard parser != nil else { return 0 }
        guard let item = item as? Item else { return 1 }
        return children(of: item).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item = item as? Item else { return rootItem }
        let kids = children(of: item)
        return index < kids.count ? self.item(for: kids[index]) : rootItem
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let item = item as? Item else { return false }
        return !children(of: item).isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? Item, let report = parser?.report else { return nil }
        let cell = (outlineView.makeView(withIdentifier: TestCell.identifier, owner: self) as? TestCell) ?? TestCell()
        if let id = item.id, let node = report[id] {
            cell.toolTip = node.isPackage ? node.name : id.test
            cell.configure(name: node.isPackage ? packageDisplayName(node.name) : node.name, status: node.status,
                           duration: node.isPackage || node.status != .running ? node.elapsed.map(GoTestNode.formatElapsed) : nil,
                           isPackage: node.isPackage)
        } else {
            let s = report.summary
            let status: GoTestStatus = generation.isOpen ? .running
                : (s.failed > 0 || s.failedPackages > 0) ? .failed
                : s.interrupted > 0 ? .interrupted
                : s.total == 0 ? .skipped : .passed
            cell.configure(name: "Test Results", status: status, duration: nil, isPackage: true)
        }
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let item = outline.item(atRow: outline.selectedRow) as? Item,
              let id = item.id, let node = parser?.report[id] else {
            console.showLog()
            return
        }
        currentPackage = id.package
        console.show(text: node.output.isEmpty ? "(no output)\n" : node.output)
    }
}

/// One row of the test tree: status icon, name, duration.
@MainActor
private final class TestCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("og.testCell")
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let duration = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = TestCell.identifier
        name.font = Theme.uiFont
        name.lineBreakMode = .byTruncatingTail
        duration.font = Theme.smallFont
        duration.textColor = Theme.secondaryText
        duration.alignment = .right
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        duration.setContentCompressionResistancePriority(.required, for: .horizontal)
        for v in [icon, name, duration] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        textField = name
        imageView = icon
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            duration.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 6),
            duration.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            duration.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(name text: String, status: GoTestStatus, duration d: String?, isPackage: Bool) {
        name.stringValue = text
        name.textColor = isPackage ? Theme.text : (status == .skipped ? Theme.secondaryText : Theme.text)
        duration.stringValue = d ?? ""
        let (symbol, color): (String, NSColor) = {
            switch status {
            case .passed: return ("checkmark.circle.fill", Theme.gitAdded)
            case .failed: return ("xmark.circle.fill", Theme.error)
            case .skipped: return ("minus.circle", Theme.secondaryText)
            case .running: return ("clock", Theme.info)
            case .interrupted: return ("exclamationmark.circle", Theme.warning)
            }
        }()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: status.rawValue)
        icon.contentTintColor = color
    }
}
