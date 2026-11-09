import AppKit
import OgCore
@preconcurrency import SwiftTerm

/// Integrated terminal: tabs of the user's login shell (`$SHELL -l`) in a pseudo-terminal.
///
/// The first tab is created lazily when the panel is first shown. A shell that
/// exits closes its tab; closing a tab terminates its shell.
@MainActor
final class TerminalPanel: NSViewController {
    let context: ProjectContext

    private final class Tab {
        let terminal: LocalProcessTerminalView
        let header: TabHeaderView
        var shellTitle: String?
        var directory: URL
        init(terminal: LocalProcessTerminalView, header: TabHeaderView, directory: URL) {
            self.terminal = terminal
            self.header = header
            self.directory = directory
        }
    }

    private var tabs: [Tab] = []
    private var active: Tab?
    private let tabStrip = NSStackView()
    private let content = FocusForwardingView()
    private let emptyLabel = NSTextField(labelWithString: "No terminal open. Click + to start a shell.")

    init(context: ProjectContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.background.cgColor

        tabStrip.orientation = .horizontal
        tabStrip.spacing = 2
        tabStrip.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        let plus = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New Terminal") ?? NSImage(),
                            target: self, action: #selector(plusClicked))
        plus.isBordered = false
        plus.bezelStyle = .recessed
        plus.toolTip = "New Terminal Tab"
        plus.contentTintColor = Theme.secondaryText
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        tabStrip.addArrangedSubview(plus)
        tabStrip.addArrangedSubview(spacer)

        let strip = NSView()
        strip.wantsLayer = true
        strip.layer?.backgroundColor = Theme.panelBackground.cgColor
        tabStrip.translatesAutoresizingMaskIntoConstraints = false
        strip.addSubview(tabStrip)

        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.background.cgColor
        content.focusTarget = { [weak self] in self?.active?.terminal }
        emptyLabel.textColor = Theme.secondaryText
        emptyLabel.font = Theme.uiFont
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(emptyLabel)

        // `content` must be the first subview: the window controller focuses
        // `view.subviews.first` for ⌥F12 and FocusForwardingView passes it on.
        for v in [content, strip] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: root.topAnchor),
            strip.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            strip.heightAnchor.constraint(equalToConstant: 26),
            tabStrip.topAnchor.constraint(equalTo: strip.topAnchor),
            tabStrip.bottomAnchor.constraint(equalTo: strip.bottomAnchor),
            tabStrip.leadingAnchor.constraint(equalTo: strip.leadingAnchor),
            tabStrip.trailingAnchor.constraint(equalTo: strip.trailingAnchor),
            content.topAnchor.constraint(equalTo: strip.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if tabs.isEmpty { newTab() }
    }

    @objc private func plusClicked() { newTab() }

    // MARK: - Public API

    /// Opens a new terminal tab in the project root.
    func newTab() { newTab(in: context.root) }

    /// Opens a new terminal tab whose shell starts in `directory`.
    func newTab(in directory: URL) {
        _ = view
        let term = LocalProcessTerminalView(frame: content.bounds, font: Theme.editorFont, options: TerminalOptions(scrollback: 10_000))
        term.autoresizingMask = [.width, .height]
        style(term)
        term.processDelegate = self

        let header = TabHeaderView()
        let tab = Tab(terminal: term, header: header, directory: directory)
        header.onSelect = { [weak self, weak tab] in if let tab { self?.activate(tab) } }
        header.onClose = { [weak self, weak tab] in if let tab { self?.close(tab) } }
        tabs.append(tab)
        tabStrip.insertArrangedSubview(header, at: tabs.count - 1)
        content.addSubview(term)
        updateTitle(tab)
        activate(tab)

        let shell = TerminalPanel.loginShell
        term.startProcess(executable: shell, args: ["-l"], environment: TerminalPanel.environment(),
                          execName: "-" + (shell as NSString).lastPathComponent, currentDirectory: directory.path)
    }

    /// Runs a shell command in the active terminal tab (creating one if needed).
    func run(command: String) {
        if active == nil { newTab() }
        guard let tab = active else { return }
        tab.terminal.send(txt: command + "\r")
        focus()
    }

    /// Makes the active terminal the first responder.
    func focus() {
        guard let term = active?.terminal else { return }
        view.window?.makeFirstResponder(term)
    }

    /// Terminates every shell (call when the project window closes).
    func terminateAll() {
        for tab in tabs { tab.terminal.terminate() }
    }

    // MARK: - Tabs

    private func activate(_ tab: Tab) {
        active = tab
        for t in tabs {
            t.terminal.isHidden = t !== tab
            t.header.isActive = t === tab
        }
        emptyLabel.isHidden = true
        tab.terminal.frame = content.bounds
        view.window?.makeFirstResponder(tab.terminal)
    }

    private func close(_ tab: Tab, terminate: Bool = true) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        tab.terminal.processDelegate = nil
        if terminate { tab.terminal.terminate() }
        tab.terminal.removeFromSuperview()
        tab.header.removeFromSuperview()
        tabs.remove(at: index)
        if active === tab {
            active = nil
            if !tabs.isEmpty { activate(tabs[min(index, tabs.count - 1)]) }
        }
        emptyLabel.isHidden = !tabs.isEmpty
    }

    private func tab(for source: TerminalView) -> Tab? {
        tabs.first { $0.terminal === source }
    }

    private func updateTitle(_ tab: Tab) {
        let shell = (TerminalPanel.loginShell as NSString).lastPathComponent
        let title: String
        if let t = tab.shellTitle, !t.isEmpty {
            title = t
        } else {
            title = "\(shell) — \(TerminalPanel.displayPath(tab.directory, root: context.root))"
        }
        tab.header.title = title
    }

    static func displayPath(_ url: URL, root: URL) -> String {
        let p = url.standardizedFileURL.path
        if p == root.path { return root.lastPathComponent }
        if p.hasPrefix(root.path + "/") { return root.lastPathComponent + "/" + String(p.dropFirst(root.path.count + 1)) }
        let home = NSHomeDirectory()
        if p == home { return "~" }
        if p.hasPrefix(home + "/") { return "~/" + String(p.dropFirst(home.count + 1)) }
        return p
    }

    // MARK: - Shell & appearance

    static var loginShell: String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        return FileManager.default.isExecutableFile(atPath: shell) ? shell : "/bin/zsh"
    }

    static func environment() -> [String] {
        var env = ToolLocator.shared.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "og"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        // Inherited values describing the parent terminal would be wrong here.
        for key in ["TERM_SESSION_ID", "ITERM_SESSION_ID", "TERM_PROGRAM_VERSION", "OLDPWD"] { env[key] = nil }
        return env.map { "\($0.key)=\($0.value)" }.sorted()
    }

    private func style(_ term: LocalProcessTerminalView) {
        term.nativeBackgroundColor = Theme.background
        term.nativeForegroundColor = Theme.text
        term.caretColor = Theme.text
        term.selectedTextBackgroundColor = Theme.selection
        term.installColors(ANSIPalette.base.map { c in
            let rgb = c.usingColorSpace(.sRGB) ?? c
            return SwiftTerm.Color(red: UInt16(rgb.redComponent * 65535),
                                   green: UInt16(rgb.greenComponent * 65535),
                                   blue: UInt16(rgb.blueComponent * 65535))
        })
        term.optionAsMetaKey = true
    }
}

extension TerminalPanel: @preconcurrency LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        guard let tab = tab(for: source) else { return }
        tab.shellTitle = title
        updateTitle(tab)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let tab = tab(for: source), let directory else { return }
        // OSC 7 sends `file://host/path`.
        if let url = URL(string: directory), url.isFileURL {
            tab.directory = url
        } else if directory.hasPrefix("/") {
            tab.directory = URL(fileURLWithPath: directory)
        }
        updateTitle(tab)
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        // Defer: SwiftTerm is still inside its own callback.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let tab = self.tab(for: source) else { return }
                self.close(tab, terminate: false)
            }
        }
    }
}

/// Accepts first responder and hands it to the active terminal.
@MainActor
private final class FocusForwardingView: NSView {
    var focusTarget: (() -> NSView?)?
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let target = self.focusTarget?() else { return }
                self.window?.makeFirstResponder(target)
            }
        }
        return true
    }
}

/// A tab in the terminal tab strip: title + close button.
@MainActor
private final class TabHeaderView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()

    var title: String = "" {
        didSet { label.stringValue = title; toolTip = title }
    }
    var isActive = false {
        didSet {
            layer?.backgroundColor = (isActive ? Theme.background : NSColor.clear).cgColor
            label.textColor = isActive ? Theme.text : Theme.secondaryText
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        label.font = Theme.smallFont
        label.textColor = Theme.secondaryText
        label.lineBreakMode = .byTruncatingHead
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.isBordered = false
        closeButton.bezelStyle = .recessed
        closeButton.contentTintColor = Theme.secondaryText
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = "Close Tab"
        for v in [label, closeButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            widthAnchor.constraint(lessThanOrEqualToConstant: 240),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 4),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 14),
            closeButton.heightAnchor.constraint(equalToConstant: 14)
        ])
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) { onSelect?() }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { onClose?() } // middle click closes
    }

    @objc private func closeClicked() { onClose?() }
}
