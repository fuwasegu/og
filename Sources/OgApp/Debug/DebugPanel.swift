import AppKit
import OgCore

/// Debug tool window: toolbar, frames, variables, console + evaluate (spec/design/run_debug.fsl).
///
/// - DES-2: every session gets a generation; events from an older (stopped / restarted) session are dropped.
/// - DES-3: breakpoints are re-sent to delve whenever the gutter changes; `DAPSession` continues
///   silently when delve stops at a breakpoint that was removed meanwhile.
/// - DES-4: while stepping, inspection is disabled; frames / variables are fetched only in a confirmed stop.
@MainActor
final class DebugPanel: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    NSOutlineViewDataSource, NSOutlineViewDelegate {

    private enum UIState: Equatable { case idle, starting, running, paused, stepping, finished }

    let context: ProjectContext
    private var session: DAPSession?
    private var generation = 0
    private var lastRequest: RunRequest?
    private var state: UIState = .idle
    private var eventTask: Task<Void, Never>?
    /// Local stop epoch; inspection results tagged with an older value are discarded.
    private var epoch = 0
    private var frames: [DAPStackFrame] = []
    private var selectedFrame: DAPStackFrame?
    private var roots: [DebugVarNode] = []

    // Views (created eagerly so events can arrive before the tab is first shown).
    private let toolbar = NSStackView()
    private var buttons: [String: NSButton] = [:]
    private let statusLabel = NSTextField(labelWithString: "Not debugging")
    private let framesTable = NSTableView()
    private let variablesOutline = NSOutlineView()
    private let console = DebugConsole()
    private let evaluateField = NSTextField()
    private let split = NSSplitView()
    private var didSetDividers = false

    init(context: ProjectContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
        configureViews()
        NotificationCenter.default.addObserver(self, selector: #selector(breakpointsChanged(_:)),
                                               name: .ogBreakpointsChanged, object: context)
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Public API

    /// Starts a delve DAP session for the request using context.breakpoints.
    func startDebugging(_ request: RunRequest) {
        if session != nil { endSession(message: "Debug session stopped (restarting)") }
        generation += 1
        let gen = generation
        lastRequest = request
        frames = []
        selectedFrame = nil
        roots = []
        framesTable.reloadData()
        variablesOutline.reloadData()
        console.clear()
        console.line("Debugging \(request.title) — \(context.relativePath(request.packageDir).isEmpty ? request.packageDir.lastPathComponent : context.relativePath(request.packageDir))")

        let (stream, sink) = AsyncStream<DAPEvent>.makeStream()
        let s = DAPSession(request: request) { event in
            sink.yield(event)
            if case .terminated = event { sink.finish() }
        }
        session = s
        state = .starting
        updateUI()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.handle(event, generation: gen)
            }
        }
        let breakpoints = currentBreakpoints()
        Task { [weak self] in
            do {
                try await s.start(breakpoints: breakpoints)
            } catch {
                guard let self, gen == self.generation else { return }
                self.launchFailed(error)
            }
        }
        context.setStatus("Debugging \(request.title)…")
    }

    var isDebugging: Bool { session != nil }

    func resume() {
        guard state == .paused, let s = session else { return }
        state = .running
        leaveStop(clearInspection: true)
        perform { try await s.resume() }
    }

    func stepOver() { step { try await $0.stepOver() } }
    func stepInto() { step { try await $0.stepIn() } }
    func stepOut() { step { try await $0.stepOut() } }

    func stop() {
        guard session != nil else { return }
        endSession(message: "Debug session stopped")
    }

    func restart() {
        guard let request = lastRequest else { return }
        context.saveAll()
        startDebugging(request)
    }

    // MARK: - Session events

    private func handle(_ event: DAPEvent, generation gen: Int) {
        guard gen == generation, session != nil else { return }   // DES-2
        switch event {
        case .output(let category, let text):
            switch category {
            case "stderr": console.append(text, color: Theme.error)
            case "stdout": console.append(text, color: Theme.text)
            default: console.append(text, color: Theme.secondaryText)
            }
        case .started:
            if state == .starting { state = .running }
        case .stopped(let stop):
            showStop(stop)
        case .continued:
            if state == .paused { state = .running; leaveStop(clearInspection: true) }
        case .autoContinued(let path, let line):
            console.line("Skipped removed breakpoint at \((path as NSString).lastPathComponent):\(line)")
        case .exited(let code):
            console.line("Process finished with exit code \(code)", color: code == 0 ? Theme.secondaryText : Theme.warning)
        case .terminated:
            finishSession()
        }
        updateUI()
    }

    private func showStop(_ stop: DAPStop) {
        state = .paused
        epoch += 1
        frames = stop.frames
        framesTable.reloadData()
        roots = []
        variablesOutline.reloadData()
        let top = stop.topFrameWithSource
        if let top, let index = frames.firstIndex(of: top) {
            framesTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            framesTable.scrollRowToVisible(index)
        }
        selectFrame(top ?? frames.first, navigate: false)
        if let top, let path = top.path {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            context.open(url, line: top.line0)
            context.debugStop = (url, top.line0)
            context.setStatus("Paused at \(url.lastPathComponent):\(top.line) (\(stop.reason))")
        } else {
            context.debugStop = nil
            context.setStatus("Paused (\(stop.reason))")
        }
        if let description = stop.description, stop.reason == "exception" || stop.reason == "panic" {
            console.line(description, color: Theme.error)
        }
        context.showPanel(.debug)
    }

    /// Leaves the paused state: the execution point is no longer valid.
    private func leaveStop(clearInspection: Bool) {
        epoch += 1
        context.debugStop = nil
        if clearInspection {
            frames = []
            selectedFrame = nil
            roots = []
            framesTable.reloadData()
            variablesOutline.reloadData()
        }
        updateUI()
    }

    private func step(_ action: @escaping @Sendable (DAPSession) async throws -> Void) {
        guard state == .paused, let s = session else { return }
        state = .stepping   // DES-4: stay "stepping" until delve reports the next stop
        epoch += 1          // in-flight variable fetches are now stale
        updateUI()
        perform { try await action(s) }
    }

    private func perform(_ body: @escaping @Sendable () async throws -> Void) {
        let gen = generation
        Task { [weak self] in
            do {
                try await body()
            } catch {
                guard let self, gen == self.generation, self.session != nil else { return }
                self.console.line("Debugger: \(error.localizedDescription)", color: Theme.error)
            }
        }
    }

    private func launchFailed(_ error: Error) {
        let message = error.localizedDescription
        console.line(message, color: Theme.error)
        let lower = message.lowercased()
        let authorization = ["authoriz", "permission", "not permitted", "devtoolssecurity", "debugserver", "operation not allowed"]
        if authorization.contains(where: { lower.contains($0) }) || lower.contains("failed to launch") {
            if !authorization.contains(where: { lower.contains($0) }) {
                console.line("The program could not be launched (build error, or debugging is not authorized).")
            }
            console.line("Allow debugging: run `sudo DevToolsSecurity -enable` once, or approve the Developer Tools prompt.",
                         color: Theme.warning)
        }
        context.setStatus("Debug: \(message)")
        finishSession()
        updateUI()
    }

    /// User stop / restart: bump the generation (drop late events), kill the session.
    private func endSession(message: String) {
        guard let s = session else { return }
        generation += 1
        Task { await s.stop() }
        console.line(message)
        finishSession()
        updateUI()
    }

    private func finishSession() {
        guard session != nil else { return }
        session = nil
        state = .finished
        epoch += 1
        frames = []
        selectedFrame = nil
        roots = []
        framesTable.reloadData()
        variablesOutline.reloadData()
        context.debugStop = nil
        context.setStatus("Debug session ended")
    }

    // MARK: - Breakpoints (DES-3)

    private func currentBreakpoints() -> [String: Set<Int>] {
        var out: [String: Set<Int>] = [:]
        for (url, lines) in context.breakpoints.lines where !lines.isEmpty {
            out[url.standardizedFileURL.path] = lines
        }
        return out
    }

    @objc private func breakpointsChanged(_ note: Notification) {
        guard let s = session else { return }
        let breakpoints = currentBreakpoints()
        Task { await s.setBreakpoints(breakpoints) }
    }

    // MARK: - Inspection (DES-4)

    private func selectFrame(_ frame: DAPStackFrame?, navigate: Bool) {
        selectedFrame = frame
        roots = []
        variablesOutline.reloadData()
        guard let frame, state == .paused, let s = session else { return }
        if navigate, let path = frame.path {
            context.open(URL(fileURLWithPath: path).standardizedFileURL, line: frame.line0)
        }
        let tag = epoch
        let gen = generation
        Task { [weak self] in
            let scopes = (try? await s.scopes(frameID: frame.id)) ?? []
            guard let self, gen == self.generation, tag == self.epoch, self.selectedFrame == frame else { return }
            self.roots = scopes.map { DebugVarNode($0, epoch: tag) }
            self.variablesOutline.reloadData()
            if let first = self.roots.first(where: { !$0.isScope || $0.reference > 0 }) {
                self.variablesOutline.expandItem(first)
            }
        }
    }

    private func loadChildren(of node: DebugVarNode) {
        guard !node.loading, node.children == nil, node.reference > 0,
              node.epoch == epoch, state == .paused, let s = session else { return }
        node.loading = true
        let gen = generation
        let ref = node.reference
        Task { [weak self] in
            let vars = (try? await s.variables(reference: ref)) ?? []
            node.loading = false
            guard let self, gen == self.generation, node.epoch == self.epoch else { return }
            node.children = vars.map { DebugVarNode($0, epoch: node.epoch) }
            self.variablesOutline.reloadItem(node, reloadChildren: true)
            self.variablesOutline.expandItem(node)
        }
    }

    @objc private func evaluate(_ sender: Any?) {
        let expression = evaluateField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.isEmpty else { return }
        guard state == .paused, let s = session else {
            console.line("Evaluate is available while paused", color: Theme.warning)
            return
        }
        console.line("> \(expression)", color: Theme.info)
        let frameID = selectedFrame?.id
        let tag = epoch
        let gen = generation
        Task { [weak self] in
            do {
                let result = try await s.evaluate(expression, frameID: frameID)
                guard let self, gen == self.generation else { return }
                self.console.line(result.type.isEmpty ? result.result : "\(result.result)  {\(result.type)}", color: Theme.text)
                if result.variablesReference > 0, tag == self.epoch {
                    let node = DebugVarNode(name: expression, value: result.result, type: result.type,
                                            reference: result.variablesReference, epoch: tag)
                    self.roots.insert(node, at: 0)
                    self.variablesOutline.reloadData()
                }
            } catch {
                guard let self, gen == self.generation else { return }
                self.console.line(error.localizedDescription, color: Theme.error)
            }
        }
    }

    // MARK: - Frames table

    func numberOfRows(in tableView: NSTableView) -> Int { frames.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: .init("frame"), owner: nil) as? DebugCell) ?? {
            let c = DebugCell()
            c.identifier = .init("frame")
            return c
        }()
        let frame = frames[row]
        let text = NSMutableAttributedString(string: frame.name, attributes: [
            .font: Theme.uiFont, .foregroundColor: frame.path == nil ? Theme.secondaryText : Theme.text,
        ])
        if let path = frame.path {
            text.append(NSAttributedString(string: "  \((path as NSString).lastPathComponent):\(frame.line)", attributes: [
                .font: Theme.smallFont, .foregroundColor: Theme.secondaryText,
            ]))
        }
        cell.label.attributedStringValue = text
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = framesTable.selectedRow
        guard row >= 0, row < frames.count, frames[row] != selectedFrame else { return }
        selectFrame(frames[row], navigate: true)
    }

    // MARK: - Variables outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? DebugVarNode else { return roots.count }
        if let children = node.children { return children.count }
        loadChildren(of: node)
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? DebugVarNode else { return roots[index] }
        return node.children?[index] ?? node
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        ((item as? DebugVarNode)?.reference ?? 0) > 0
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? DebugVarNode else { return nil }
        let cell = (outlineView.makeView(withIdentifier: .init("var"), owner: nil) as? DebugCell) ?? {
            let c = DebugCell()
            c.identifier = .init("var")
            return c
        }()
        cell.label.attributedStringValue = node.attributed
        cell.toolTip = node.isScope ? nil : "\(node.name) = \(node.value)"
        return cell
    }

    // MARK: - Toolbar state

    private func updateUI() {
        let live = session != nil
        let paused = state == .paused
        buttons["resume"]?.isEnabled = paused
        buttons["over"]?.isEnabled = paused
        buttons["into"]?.isEnabled = paused
        buttons["out"]?.isEnabled = paused
        buttons["stop"]?.isEnabled = live
        buttons["restart"]?.isEnabled = lastRequest != nil
        evaluateField.isEnabled = paused
        switch state {
        case .idle: statusLabel.stringValue = "Not debugging"
        case .starting: statusLabel.stringValue = "Starting…"
        case .running: statusLabel.stringValue = "Running"
        case .stepping: statusLabel.stringValue = "Stepping…"
        case .finished: statusLabel.stringValue = "Finished"
        case .paused:
            if let top = frames.first(where: { $0.path != nil }), let path = top.path {
                statusLabel.stringValue = "Paused at \((path as NSString).lastPathComponent):\(top.line)"
            } else {
                statusLabel.stringValue = "Paused"
            }
        }
    }

    // MARK: - Layout

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.panelBackground.cgColor

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        split.translatesAutoresizingMaskIntoConstraints = false
        let rule = NSBox()
        rule.boxType = .custom
        rule.borderWidth = 0
        rule.fillColor = Theme.border
        rule.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(toolbar)
        root.addSubview(rule)
        root.addSubview(split)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 28),
            rule.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            rule.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            split.topAnchor.constraint(equalTo: rule.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        updateUI()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !didSetDividers, split.bounds.width > 300 else { return }
        didSetDividers = true
        let w = split.bounds.width
        split.setPosition(min(260, w * 0.25), ofDividerAt: 0)
        split.setPosition(min(260, w * 0.25) + w * 0.35, ofDividerAt: 1)
    }

    private func configureViews() {
        toolbar.orientation = .horizontal
        toolbar.spacing = 2
        toolbar.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 8)
        let items: [(String, String, String, Selector, NSColor)] = [
            ("resume", "play.fill", "Resume Program", #selector(resumeClicked), Theme.gitAdded),
            ("over", "arrow.uturn.forward", "Step Over", #selector(stepOverClicked), Theme.info),
            ("into", "arrow.down.to.line", "Step Into", #selector(stepIntoClicked), Theme.info),
            ("out", "arrow.up.to.line", "Step Out", #selector(stepOutClicked), Theme.info),
            ("stop", "stop.fill", "Stop", #selector(stopClicked), Theme.error),
            ("restart", "arrow.clockwise", "Restart", #selector(restartClicked), Theme.text),
        ]
        for (key, symbol, tip, action, color) in items {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage()
            let b = NSButton(image: image, target: self, action: action)
            b.isBordered = false
            b.bezelStyle = .regularSquare
            b.imageScaling = .scaleProportionallyDown
            b.contentTintColor = color
            b.toolTip = tip
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 24).isActive = true
            b.heightAnchor.constraint(equalToConstant: 22).isActive = true
            buttons[key] = b
            toolbar.addArrangedSubview(b)
            if key == "out" || key == "stop" { toolbar.setCustomSpacing(10, after: b) }
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        toolbar.addArrangedSubview(spacer)
        statusLabel.font = Theme.smallFont
        statusLabel.textColor = Theme.secondaryText
        toolbar.addArrangedSubview(statusLabel)

        // Frames
        let frameCol = NSTableColumn(identifier: .init("frame"))
        frameCol.resizingMask = .autoresizingMask
        framesTable.addTableColumn(frameCol)
        framesTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        framesTable.headerView = nil
        framesTable.rowHeight = 20
        framesTable.backgroundColor = Theme.panelBackground
        framesTable.style = .plain
        framesTable.dataSource = self
        framesTable.delegate = self

        // Variables
        let varCol = NSTableColumn(identifier: .init("var"))
        varCol.resizingMask = .autoresizingMask
        variablesOutline.addTableColumn(varCol)
        variablesOutline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        variablesOutline.outlineTableColumn = varCol
        variablesOutline.headerView = nil
        variablesOutline.rowHeight = 20
        variablesOutline.indentationPerLevel = 14
        variablesOutline.backgroundColor = Theme.panelBackground
        variablesOutline.style = .plain
        variablesOutline.dataSource = self
        variablesOutline.delegate = self

        // Evaluate
        evaluateField.placeholderAttributedString = NSAttributedString(string: "Evaluate expression (↩)", attributes: [
            .font: Theme.editorFont, .foregroundColor: Theme.secondaryText,
        ])
        evaluateField.font = Theme.editorFont
        evaluateField.textColor = Theme.text
        evaluateField.backgroundColor = Theme.background
        evaluateField.drawsBackground = true
        evaluateField.isBordered = false
        evaluateField.focusRingType = .none
        evaluateField.target = self
        evaluateField.action = #selector(evaluate(_:))
        evaluateField.cell?.sendsActionOnEndEditing = false

        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(pane(title: "Frames", content: scroll(framesTable)))
        split.addArrangedSubview(pane(title: "Variables", content: scroll(variablesOutline)))
        let consolePane = NSView()
        let fieldBox = NSView()
        fieldBox.wantsLayer = true
        fieldBox.layer?.backgroundColor = Theme.background.cgColor
        for v in [console.scroll, fieldBox] {
            v.translatesAutoresizingMaskIntoConstraints = false
            consolePane.addSubview(v)
        }
        evaluateField.translatesAutoresizingMaskIntoConstraints = false
        fieldBox.addSubview(evaluateField)
        NSLayoutConstraint.activate([
            console.scroll.topAnchor.constraint(equalTo: consolePane.topAnchor),
            console.scroll.leadingAnchor.constraint(equalTo: consolePane.leadingAnchor),
            console.scroll.trailingAnchor.constraint(equalTo: consolePane.trailingAnchor),
            console.scroll.bottomAnchor.constraint(equalTo: fieldBox.topAnchor, constant: -1),
            fieldBox.leadingAnchor.constraint(equalTo: consolePane.leadingAnchor),
            fieldBox.trailingAnchor.constraint(equalTo: consolePane.trailingAnchor),
            fieldBox.bottomAnchor.constraint(equalTo: consolePane.bottomAnchor),
            fieldBox.heightAnchor.constraint(equalToConstant: 24),
            evaluateField.leadingAnchor.constraint(equalTo: fieldBox.leadingAnchor, constant: 6),
            evaluateField.trailingAnchor.constraint(equalTo: fieldBox.trailingAnchor, constant: -6),
            evaluateField.centerYAnchor.constraint(equalTo: fieldBox.centerYAnchor),
        ])
        split.addArrangedSubview(pane(title: "Console", content: consolePane))
        split.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
        split.setHoldingPriority(NSLayoutConstraint.Priority(250), forSubviewAt: 1)
        split.setHoldingPriority(NSLayoutConstraint.Priority(240), forSubviewAt: 2)
    }

    private func scroll(_ documentView: NSView) -> NSScrollView {
        let s = NSScrollView()
        s.documentView = documentView
        s.hasVerticalScroller = true
        s.drawsBackground = false
        s.borderType = .noBorder
        return s
    }

    private func pane(title: String, content: NSView) -> NSView {
        let pane = NSView()
        let header = NSTextField(labelWithString: title)
        header.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        header.textColor = Theme.secondaryText
        for v in [header, content] {
            v.translatesAutoresizingMaskIntoConstraints = false
            pane.addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: pane.topAnchor, constant: 4),
            header.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 8),
            content.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 3),
            content.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
            pane.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])
        return pane
    }

    @objc private func resumeClicked() { resume() }
    @objc private func stepOverClicked() { stepOver() }
    @objc private func stepIntoClicked() { stepInto() }
    @objc private func stepOutClicked() { stepOut() }
    @objc private func stopClicked() { stop() }
    @objc private func restartClicked() { restart() }
}
