import AppKit

enum BottomTab: Int, CaseIterable {
    case terminal, run, debug, problems, git, find

    var title: String {
        switch self {
        case .terminal: return "Terminal"
        case .run: return "Run"
        case .debug: return "Debug"
        case .problems: return "Problems"
        case .git: return "Commit"
        case .find: return "Find"
        }
    }
}

/// Bottom tool window with tabs. Each tab hosts a panel view controller.
@MainActor
final class BottomPanelController: NSViewController {
    let context: ProjectContext
    let terminalPanel: TerminalPanel
    let runPanel: RunPanel
    let debugPanel: DebugPanel
    let problemsPanel: ProblemsPanel
    let gitPanel: GitPanel
    let findPanel: FindPanel
    private let tabBar = NSStackView()
    private let container = NSView()
    private var buttons: [BottomTab: NSButton] = [:]
    private(set) var selected: BottomTab = .terminal
    /// Called when the user asks to hide the panel.
    var onHide: (() -> Void)?

    init(context: ProjectContext) {
        self.context = context
        terminalPanel = TerminalPanel(context: context)
        runPanel = RunPanel(context: context)
        debugPanel = DebugPanel(context: context)
        problemsPanel = ProblemsPanel(context: context)
        gitPanel = GitPanel(context: context)
        findPanel = FindPanel(context: context)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    func panel(_ tab: BottomTab) -> NSViewController {
        switch tab {
        case .terminal: return terminalPanel
        case .run: return runPanel
        case .debug: return debugPanel
        case .problems: return problemsPanel
        case .git: return gitPanel
        case .find: return findPanel
        }
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.panelBackground.cgColor

        tabBar.orientation = .horizontal
        tabBar.spacing = 2
        tabBar.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        for tab in BottomTab.allCases {
            let b = NSButton(title: tab.title, target: self, action: #selector(tabClicked(_:)))
            b.tag = tab.rawValue
            b.isBordered = false
            b.font = Theme.smallFont
            b.focusRingType = .none
            buttons[tab] = b
            tabBar.addArrangedSubview(b)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tabBar.addArrangedSubview(spacer)
        let hide = NSButton(image: NSImage(systemSymbolName: "minus", accessibilityDescription: "Hide") ?? NSImage(), target: self, action: #selector(hideClicked))
        hide.bezelStyle = .recessed
        hide.isBordered = false
        tabBar.addArrangedSubview(hide)

        let separator = NSBox()
        separator.boxType = .separator

        for v in [tabBar, separator, container] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: root.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 28),
            separator.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.topAnchor.constraint(equalTo: separator.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        view = root
        for tab in BottomTab.allCases { addChild(panel(tab)) }
        show(.terminal)
    }

    func show(_ tab: BottomTab) {
        _ = view
        selected = tab
        container.subviews.forEach { $0.removeFromSuperview() }
        let v = panel(tab).view
        v.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: container.topAnchor),
            v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            v.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        for (t, b) in buttons {
            let on = t == tab
            b.attributedTitle = NSAttributedString(string: "  \(t.title)  ", attributes: [
                .font: on ? NSFont.systemFont(ofSize: 11, weight: .semibold) : Theme.smallFont,
                .foregroundColor: on ? Theme.text : Theme.secondaryText,
                .underlineStyle: on ? NSUnderlineStyle.thick.rawValue : 0,
                .underlineColor: Theme.accent
            ])
        }
        window?.ensureBottomPanelVisible()
    }

    private var window: ProjectWindowController? { context.window }

    @objc private func tabClicked(_ sender: NSButton) {
        if let tab = BottomTab(rawValue: sender.tag) { show(tab) }
    }

    @objc private func hideClicked() { onHide?() }
}
