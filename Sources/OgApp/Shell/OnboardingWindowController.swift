import AppKit
import OgCore

/// First-launch setup: appearance, editor font, Go tools, and the opt-in local AI completion.
/// Shown once (`og.onboarded`); reopen from og ▸ Setup Assistant….
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    static let shared = OnboardingWindowController()
    static var isDone: Bool { UserDefaults.standard.bool(forKey: "og.onboarded") }

    private enum Step: Int, CaseIterable { case welcome, look, tools, ai, done }
    private var step: Step = .welcome
    private let container = NSView()
    private let back = NSButton(title: "Back", target: nil, action: nil)
    private let next = NSButton(title: "Continue", target: nil, action: nil)
    private let dots = NSStackView()
    /// Called when the assistant finishes or is closed.
    var onFinish: (() -> Void)?

    // Appearance
    private let themeButtons = ThemeMode.allCases.map { NSButton(radioButtonWithTitle: $0.title, target: nil, action: nil) }
    private let family = NSPopUpButton()
    private let size = NSPopUpButton()
    private let preview = NSTextView()

    // AI
    private let aiOn = NSButton(checkboxWithTitle: "Turn on inline AI completion", target: nil, action: nil)
    private let backend = NSPopUpButton()
    private let model = NSPopUpButton()
    private let aiNote = NSTextField(wrappingLabelWithString: "")

    private init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.backgroundColor = Theme.background
        super.init(window: w)
        w.delegate = self
        build()
        show(.welcome)
        w.center()
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        show(.welcome)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) { finish(closeWindow: false) }

    /// Headless driver: render a step in an invisible window (no activation) and return its view.
    func debugRender(step n: Int) -> NSView? {
        guard let w = window, let s = Step(rawValue: n) else { return nil }
        w.alphaValue = 0
        w.orderFront(nil)
        show(s)
        w.contentView?.layoutSubtreeIfNeeded()
        return w.contentView
    }

    // MARK: - Layout

    private func build() {
        guard let content = window?.contentView else { return }
        back.bezelStyle = .rounded
        back.target = self
        back.action = #selector(goBack)
        next.bezelStyle = .rounded
        next.keyEquivalent = "\r"
        next.target = self
        next.action = #selector(goNext)
        dots.orientation = .horizontal
        dots.spacing = 6
        let bar = NSStackView(views: [dots, NSView(), back, next])
        bar.orientation = .horizontal
        for v in [container, bar] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: content.topAnchor, constant: 44),
            container.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 44),
            container.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -44),
            container.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -16),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 44),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -22)
        ])

        for (i, b) in themeButtons.enumerated() {
            b.tag = i
            b.target = self
            b.action = #selector(themePicked(_:))
        }
        family.addItem(withTitle: SettingsWindowController.systemMono)
        family.menu?.addItem(.separator())
        for f in Theme.monospacedFamilies() { family.addItem(withTitle: f) }
        family.target = self
        family.action = #selector(fontPicked)
        for s in [11, 12, 13, 14, 15, 16, 18, 20] { size.addItem(withTitle: "\(s) pt") }
        size.target = self
        size.action = #selector(fontPicked)
        preview.isEditable = false
        preview.isSelectable = false
        preview.drawsBackground = true
        preview.textContainerInset = NSSize(width: 12, height: 10)

        aiOn.target = self
        aiOn.action = #selector(aiChanged)
        for b in [ModelBackend.llamaCpp, .mlx] { backend.addItem(withTitle: b.title) }
        backend.target = self
        backend.action = #selector(backendPicked)
        model.target = self
        model.action = #selector(aiChanged)
        aiNote.font = Theme.smallFont
        aiNote.textColor = Theme.secondaryText
    }

    private func show(_ s: Step) {
        step = s
        container.subviews.forEach { $0.removeFromSuperview() }
        let page: NSView
        switch s {
        case .welcome: page = welcomePage()
        case .look: page = lookPage()
        case .tools: page = toolsPage()
        case .ai: page = aiPage()
        case .done: page = donePage()
        }
        page.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: container.topAnchor),
            page.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            page.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor)
        ])
        back.isHidden = s == .welcome
        next.title = s == .done ? "Start Coding" : (s == .welcome ? "Get Started" : "Continue")
        dots.setViews(Step.allCases.map { st in
            let d = NSView()
            d.translatesAutoresizingMaskIntoConstraints = false
            d.widthAnchor.constraint(equalToConstant: st == s ? 18 : 6).isActive = true
            d.heightAnchor.constraint(equalToConstant: 6).isActive = true
            d.layer?.cornerRadius = 3
            Theme.paint(d, background: st == s ? Theme.accent : Theme.border)
            d.layer?.cornerRadius = 3
            return d
        }, in: .leading)
    }

    private func title(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = NSFont.systemFont(ofSize: 24, weight: .semibold)
        t.textColor = Theme.text
        return t
    }

    private func body(_ s: String) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: s)
        t.font = NSFont.systemFont(ofSize: 13)
        t.textColor = Theme.secondaryText
        t.preferredMaxLayoutWidth = 540
        return t
    }

    private func vstack(_ views: [NSView], spacing: CGFloat = 14) -> NSStackView {
        let v = NSStackView(views: views)
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = spacing
        return v
    }

    // MARK: - Pages

    private func welcomePage() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 96).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 96).isActive = true
        return vstack([
            icon,
            title("Welcome to og"),
            body("A native Go IDE for writing code by hand: GoLand-style navigation, refactoring, run and debug, and Git — fast, and nothing but AppKit."),
            body("Let's set a few things up. It takes under a minute, and everything can be changed later in Settings.")
        ], spacing: 16)
    }

    private func lookPage() -> NSView {
        let mode = Theme.mode
        for (i, b) in themeButtons.enumerated() { b.state = ThemeMode.allCases[i] == mode ? .on : .off }
        let radios = NSStackView(views: themeButtons)
        radios.orientation = .horizontal
        radios.spacing = 18
        if let fam = Theme.fontFamily, family.itemTitles.contains(fam) { family.selectItem(withTitle: fam) } else { family.selectItem(at: 0) }
        size.selectItem(withTitle: "\(Int(Theme.fontSize)) pt")
        let fontRow = NSStackView(views: [family, size])
        fontRow.spacing = 8
        updatePreview()
        let scroll = NSScrollView()
        scroll.documentView = preview
        scroll.hasVerticalScroller = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 132).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 552).isActive = true
        preview.frame = NSRect(x: 0, y: 0, width: 552, height: 132)
        Theme.paint(scroll, border: Theme.border)
        scroll.layer?.borderWidth = 1
        scroll.layer?.cornerRadius = 6
        scroll.layer?.masksToBounds = true
        return vstack([
            title("Make it yours"),
            label("Theme"), radios,
            label("Editor font"), fontRow,
            scroll
        ], spacing: 10)
    }

    private func label(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        t.textColor = Theme.text
        return t
    }

    private func updatePreview() {
        let src = """
        // Greet returns a friendly message.
        func Greet(name string) (string, error) {
        \tif name == "" {
        \t\treturn "", errors.New("empty name")
        \t}
        \treturn fmt.Sprintf("Hello, %s! %d", name, 42), nil
        }
        """
        let attr = NSMutableAttributedString(attributedString: Markdown.highlighted(src, font: Theme.editorFont))
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.15
        attr.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: attr.length))
        preview.textStorage?.setAttributedString(attr)
        preview.backgroundColor = Theme.background
    }

    private func toolsPage() -> NSView {
        let tools: [(String, String, String)] = [
            ("go", "Go toolchain", "brew install go"),
            ("gopls", "Language server: completion, navigation, refactoring", "brew install gopls"),
            ("dlv", "Delve debugger", "brew install delve")
        ]
        var rows: [NSView] = [title("Go tools"), body("og uses the standard Go tools from your PATH or Homebrew.")]
        var missing: [String] = []
        for (bin, what, install) in tools {
            let found = ToolLocator.shared.find(bin)
            let mark = NSImageView(image: NSImage(systemSymbolName: found != nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill", accessibilityDescription: nil) ?? NSImage())
            mark.contentTintColor = found != nil ? Theme.gitAdded : Theme.warning
            let name = NSTextField(labelWithString: bin)
            name.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
            name.textColor = Theme.text
            name.widthAnchor.constraint(equalToConstant: 56).isActive = true
            let detail = NSTextField(labelWithString: found.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? what)
            detail.font = Theme.smallFont
            detail.textColor = Theme.secondaryText
            detail.lineBreakMode = .byTruncatingMiddle
            let row = NSStackView(views: [mark, name, detail])
            row.spacing = 8
            rows.append(row)
            if found == nil { missing.append(install) }
        }
        if missing.isEmpty {
            rows.append(body("All set."))
        } else {
            let cmd = missing.map { $0.replacingOccurrences(of: "brew install ", with: "") }.joined(separator: " ")
            let text = "brew install \(cmd)"
            let field = NSTextField(labelWithString: text)
            field.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            field.textColor = Theme.text
            field.isSelectable = true
            let copy = NSButton(title: "Copy", target: self, action: #selector(copyCommand(_:)))
            copy.bezelStyle = .rounded
            copy.identifier = NSUserInterfaceItemIdentifier(text)
            rows.append(body("Install the missing ones in a terminal, then reopen your project:"))
            rows.append(NSStackView(views: [field, copy]))
        }
        return vstack(rows, spacing: 12)
    }

    @objc private func copyCommand(_ sender: NSButton) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sender.identifier?.rawValue ?? "", forType: .string)
        sender.title = "Copied"
    }

    private func aiPage() -> NSView {
        let m = ModelServerManager.shared
        aiOn.state = m.enabled ? .on : .off
        let cfg = m.config
        backend.selectItem(at: cfg.backend == .mlx ? 1 : 0)
        fillModels(selecting: cfg.model)
        refreshAINote()
        let row = { (l: String, v: NSView) -> NSStackView in
            let t = NSTextField(labelWithString: l)
            t.textColor = Theme.secondaryText
            t.alignment = .right
            t.widthAnchor.constraint(equalToConstant: 64).isActive = true
            return NSStackView(views: [t, v])
        }
        return vstack([
            title("AI completion"),
            body("og can suggest the rest of a line as you type, like ghost text. It is off by default: og is built for writing code yourself, and you decide whether a model helps."),
            body("It runs a small coding model on this Mac. og starts and stops the model server itself, binds it to 127.0.0.1, and your code never leaves the machine."),
            aiOn,
            row("Engine", backend),
            row("Model", model),
            aiNote
        ], spacing: 10)
    }

    private func fillModels(selecting id: String) {
        let b: ModelBackend = backend.indexOfSelectedItem == 1 ? .mlx : .llamaCpp
        model.removeAllItems()
        let presets = ModelPreset.presets(for: b)
        for p in presets { model.addItem(withTitle: p.title) }
        if let i = presets.firstIndex(where: { $0.id == id }) { model.selectItem(at: i) } else { model.selectItem(at: 0) }
    }

    private func refreshAINote() {
        let b: ModelBackend = backend.indexOfSelectedItem == 1 ? .mlx : .llamaCpp
        let tool = b == .mlx ? "uvx" : "llama-server"
        let install = b == .mlx ? "brew install uv" : "brew install llama.cpp"
        let found = ToolLocator.shared.find(tool) != nil
        let enabled = aiOn.state == .on
        backend.isEnabled = enabled
        model.isEnabled = enabled
        aiNote.stringValue = found
            ? "\(tool) found. The model (about 1–5 GB) downloads the first time the server starts."
            : "\(tool) was not found. Install it with “\(install)”, then turn this on in Settings."
        aiNote.textColor = found ? Theme.secondaryText : Theme.warning
    }

    @objc private func backendPicked() {
        fillModels(selecting: "")
        refreshAINote()
    }

    @objc private func aiChanged() { refreshAINote() }

    private func applyAI() {
        let m = ModelServerManager.shared
        let b: ModelBackend = backend.indexOfSelectedItem == 1 ? .mlx : .llamaCpp
        let presets = ModelPreset.presets(for: b)
        let preset = presets.indices.contains(model.indexOfSelectedItem) ? presets[model.indexOfSelectedItem] : presets.first
        if aiOn.state == .on, let preset {
            var cfg = m.config
            cfg.backend = b
            cfg.model = preset.id
            m.config = cfg
            if !m.enabled { m.enabled = true }
        } else if m.enabled {
            m.enabled = false
        }
    }

    private func donePage() -> NSView {
        vstack([
            title("You're ready"),
            body("Open a folder with a go.mod or go.work file to start."),
            body("Shortcuts follow GoLand's macOS keymap: ⇧⌘O go to file, ⌘B go to declaration, ⌥↩ quick fixes, ⇧F6 rename, ⌃R run."),
            body("Change any of this later in og ▸ Settings, or run og ▸ Setup Assistant again.")
        ], spacing: 14)
    }

    // MARK: - Actions

    @objc private func themePicked(_ sender: NSButton) {
        Theme.mode = ThemeMode.allCases[sender.tag]
        window?.backgroundColor = Theme.background
        updatePreview()
    }

    @objc private func fontPicked() {
        let fam = family.titleOfSelectedItem == SettingsWindowController.systemMono ? nil : family.titleOfSelectedItem
        let pt = Double(size.titleOfSelectedItem?.split(separator: " ").first ?? "") ?? Double(Theme.fontSize)
        Theme.setFont(family: fam, size: CGFloat(pt))
        updatePreview()
    }

    @objc private func goBack() {
        if step == .ai { applyAI() }
        if let prev = Step(rawValue: step.rawValue - 1) { show(prev) }
    }

    @objc private func goNext() {
        if step == .ai { applyAI() }
        if let n = Step(rawValue: step.rawValue + 1) { show(n) } else { finish(closeWindow: true) }
    }

    private func finish(closeWindow: Bool) {
        UserDefaults.standard.set(true, forKey: "og.onboarded")
        let done = onFinish
        onFinish = nil
        if closeWindow { window?.close() }
        done?()
    }
}
