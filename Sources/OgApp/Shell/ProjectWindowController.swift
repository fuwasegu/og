import AppKit
import OgCore

/// One project window: sidebar | editor area / bottom panel, plus a status bar.
@MainActor
final class ProjectWindowController: NSWindowController, NSWindowDelegate, NSSplitViewDelegate {
    let context: ProjectContext
    let sidebar: SidebarController
    let editorArea: EditorAreaController
    let bottomPanel: BottomPanelController
    let statusBar = StatusBarView()
    private let mainSplit = NSSplitView()
    private let editorSplit = NSSplitView()
    private var bottomHeight: CGFloat = 260
    private var sidebarWidth: CGFloat = 260

    init(context: ProjectContext) {
        self.context = context
        sidebar = SidebarController(context: context)
        editorArea = EditorAreaController(context: context)
        bottomPanel = BottomPanelController(context: context)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = context.root.lastPathComponent
        window.subtitle = (context.root.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        window.titlebarAppearsTransparent = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.background
        window.minSize = NSSize(width: 800, height: 500)
        window.setFrameAutosaveName("og.project.\(context.root.path)")
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        context.window = self
        buildLayout()
        if window.frame.origin == .zero { window.center() }
    }

    required init?(coder: NSCoder) { nil }

    private func buildLayout() {
        guard let window else { return }
        let content = NSView()

        mainSplit.isVertical = true
        mainSplit.dividerStyle = .thin
        mainSplit.delegate = self
        mainSplit.autosaveName = "og.mainSplit"

        editorSplit.isVertical = false
        editorSplit.dividerStyle = .thin
        editorSplit.delegate = self

        editorSplit.addArrangedSubview(editorArea.view)
        editorSplit.addArrangedSubview(bottomPanel.view)
        editorSplit.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        editorSplit.setHoldingPriority(.defaultHigh, forSubviewAt: 1)

        mainSplit.addArrangedSubview(sidebar.view)
        mainSplit.addArrangedSubview(editorSplit)
        mainSplit.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        mainSplit.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        bottomPanel.onHide = { [weak self] in self?.toggleBottomPanel() }

        for v in [mainSplit, statusBar] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            mainSplit.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor),
            mainSplit.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            mainSplit.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            mainSplit.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 24)
        ])
        window.contentView = content
        statusBar.context = context

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.mainSplit.setPosition(self.sidebarWidth, ofDividerAt: 0)
            self.editorSplit.setPosition(max(200, self.editorSplit.bounds.height - self.bottomHeight), ofDividerAt: 0)
        }
    }

    // MARK: - Panels

    var isBottomPanelVisible: Bool { !editorSplit.isSubviewCollapsed(bottomPanel.view) && bottomPanel.view.frame.height > 1 }

    func ensureBottomPanelVisible() {
        guard !isBottomPanelVisible else { return }
        toggleBottomPanel()
    }

    func toggleBottomPanel() {
        if isBottomPanelVisible {
            bottomHeight = bottomPanel.view.frame.height
            editorSplit.setPosition(editorSplit.bounds.height, ofDividerAt: 0)
        } else {
            editorSplit.setPosition(max(150, editorSplit.bounds.height - max(bottomHeight, 180)), ofDividerAt: 0)
        }
    }

    func toggleSidebar() {
        if mainSplit.isSubviewCollapsed(sidebar.view) || sidebar.view.frame.width < 1 {
            mainSplit.setPosition(max(sidebarWidth, 180), ofDividerAt: 0)
        } else {
            sidebarWidth = sidebar.view.frame.width
            mainSplit.setPosition(0, ofDividerAt: 0)
        }
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        subview === bottomPanel.view || subview === sidebar.view
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        splitView === mainSplit ? 0 : 120
    }

    // MARK: - Window

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // D-6 / ASSUME-3: block close while a file is in conflict or cannot be saved.
        context.documents.autosaveAll()
        let blocked = context.documents.documents.values.filter { $0.conflict || $0.dirty }
        if let doc = blocked.first {
            let alert = NSAlert()
            alert.messageText = doc.conflict
                ? "\(doc.url.lastPathComponent) changed on disk while you were editing it."
                : "\(doc.url.lastPathComponent) could not be saved."
            alert.informativeText = doc.conflict
                ? "Resolve the conflict before closing the project."
                : (doc.saveError ?? "") + "\nSave it again or discard your changes before closing."
            alert.addButton(withTitle: "Show File")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: sender) { [weak self] response in
                if response == .alertFirstButtonReturn { self?.context.open(doc.url) }
            }
            return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        editorArea.saveSession()
        context.shutdown()
        AppDelegate.shared?.projectClosed(self)
    }

    func windowDidResignKey(_ notification: Notification) {
        context.documents.autosaveAll()
    }
}

/// Bottom status bar: gopls state, messages, git branch, caret position.
@MainActor
final class StatusBarView: NSView {
    weak var context: ProjectContext? {
        didSet { observe() }
    }
    private let gopls = NSTextField(labelWithString: "")
    private let message = NSTextField(labelWithString: "")
    private let branch = NSButton(title: "", target: nil, action: nil)
    private let position = NSTextField(labelWithString: "")
    private var messageTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.panelBackground.cgColor
        for f in [gopls, message, position] {
            f.font = Theme.smallFont
            f.textColor = Theme.secondaryText
            f.lineBreakMode = .byTruncatingTail
        }
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        branch.bezelStyle = .recessed
        branch.isBordered = false
        branch.font = Theme.smallFont
        branch.contentTintColor = Theme.secondaryText
        branch.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)
        branch.imagePosition = .imageLeading
        branch.target = self
        branch.action = #selector(branchClicked)
        let stack = NSStackView(views: [gopls, message, NSView(), branch, position])
        stack.orientation = .horizontal
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        let top = NSBox()
        top.boxType = .separator
        top.translatesAutoresizingMaskIntoConstraints = false
        addSubview(top)
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: topAnchor),
            top.leadingAnchor.constraint(equalTo: leadingAnchor),
            top.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    private func observe() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: .ogGoplsStatusChanged, object: context, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        nc.addObserver(forName: .ogGitStatusChanged, object: context, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    func refresh() {
        guard let context else { return }
        gopls.stringValue = context.goplsStatus.label
        if case .ready = context.goplsStatus { gopls.textColor = Theme.secondaryText } else { gopls.textColor = Theme.warning }
        branch.title = context.gitStatus.branch ?? ""
        branch.isHidden = context.gitStatus.branch == nil
    }

    func setMessage(_ text: String) {
        message.stringValue = text
        messageTimer?.invalidate()
        messageTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.message.stringValue = "" }
        }
    }

    func setPosition(line: Int, column: Int, selection: Int) {
        position.stringValue = selection > 0 ? "\(line):\(column) (\(selection) chars)" : "\(line):\(column)"
    }

    @objc private func branchClicked() {
        context?.window?.bottomPanel.gitPanel.showBranchMenu(from: branch)
    }
}
