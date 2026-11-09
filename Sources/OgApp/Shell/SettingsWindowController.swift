import AppKit
import OgCore

/// Preferences: editor font, session, and the app-owned local AI server (spec/req/model_server.fsl).
@MainActor
final class SettingsWindowController: NSWindowController, NSComboBoxDelegate {
    static let shared = SettingsWindowController()
    private let fontSize = NSStepper()
    private let fontLabel = NSTextField(labelWithString: "")
    private let fontFamily = NSPopUpButton()
    private let themePopup = NSPopUpButton()
    private let fontPreview = NSTextField(labelWithString: "")
    private let reopen = NSButton(checkboxWithTitle: "Reopen the last project on launch", target: nil, action: nil)

    private let aiEnabled = NSButton(checkboxWithTitle: "Enable inline AI completion (runs a local model server; code never leaves this Mac)", target: nil, action: nil)
    private let backend = NSPopUpButton()
    private let model = NSComboBox()
    private let custom = NSTextField()
    private let customRow = NSStackView()
    private let status = NSTextField(labelWithString: "")
    private let actionButton = NSButton(title: "Restart", target: nil, action: nil)
    private let logView = NSTextView()

    private init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Settings"
        super.init(window: w)
        build()
        load()
        w.center()
        NotificationCenter.default.addObserver(forName: .ogModelServerChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStatus() }
        }
    }

    required init?(coder: NSCoder) { nil }

    private func build() {
        fontSize.minValue = 9
        fontSize.maxValue = 32
        fontSize.increment = 1
        fontSize.target = self
        fontSize.action = #selector(fontChanged)
        reopen.target = self
        reopen.action = #selector(reopenChanged)
        for m in ThemeMode.allCases { themePopup.addItem(withTitle: m.title) }
        themePopup.target = self
        themePopup.action = #selector(themeChanged)
        fontFamily.addItem(withTitle: Self.systemMono)
        fontFamily.menu?.addItem(.separator())
        for f in Theme.monospacedFamilies() { fontFamily.addItem(withTitle: f) }
        fontFamily.target = self
        fontFamily.action = #selector(familyChanged)
        fontPreview.stringValue = "func main() { fmt.Println(\"0O 1lI {}[]() := != <-\") }"

        aiEnabled.target = self
        aiEnabled.action = #selector(enabledChanged)
        for b in ModelBackend.allCases { backend.addItem(withTitle: b.title) }
        backend.target = self
        backend.action = #selector(backendChanged)
        model.isEditable = true
        model.completes = false
        model.delegate = self
        model.target = self
        model.action = #selector(modelChanged)
        model.placeholderString = "preset, Hugging Face repo, or path"
        custom.placeholderString = "e.g. /path/to/server --port {port}"
        custom.target = self
        custom.action = #selector(customChanged)
        actionButton.target = self
        actionButton.action = #selector(actionClicked)
        status.font = Theme.uiFont
        logView.isEditable = false
        logView.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        logView.backgroundColor = Theme.background
        logView.textColor = Theme.secondaryText
        logView.isVerticallyResizable = true
        logView.autoresizingMask = [.width]
        let logScroll = NSScrollView()
        logScroll.documentView = logView
        logScroll.hasVerticalScroller = true
        logScroll.heightAnchor.constraint(equalToConstant: 180).isActive = true

        func row(_ label: String, _ v: NSView) -> NSStackView {
            let l = NSTextField(labelWithString: label)
            l.alignment = .right
            l.widthAnchor.constraint(equalToConstant: 80).isActive = true
            return NSStackView(views: [l, v])
        }
        model.widthAnchor.constraint(equalToConstant: 420).isActive = true
        custom.widthAnchor.constraint(equalToConstant: 420).isActive = true
        customRow.setViews([NSTextField(labelWithString: "Command"), custom], in: .leading)
        let hint = NSTextField(wrappingLabelWithString: "llama.cpp: install with `brew install llama.cpp` (or mise). MLX: needs `uv` (`brew install uv`); the model is downloaded on first start. og binds the server to 127.0.0.1 on a free port and stops it when you quit.")
        hint.font = Theme.smallFont
        hint.textColor = .secondaryLabelColor

        let statusRow = NSStackView(views: [status, NSView(), actionButton])
        let stack = NSStackView(views: [
            row("Theme", themePopup), row("Font", fontFamily), NSStackView(views: [fontLabel, fontSize]), fontPreview,
            reopen, NSBox(),
            aiEnabled, row("Backend", backend), row("Model", model), customRow, hint, statusRow, logScroll
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        statusRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        logScroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        window?.contentView = stack
    }

    private func load() {
        fontSize.doubleValue = Double(Theme.fontSize)
        fontLabel.stringValue = "Editor font size: \(Int(Theme.fontSize))"
        themePopup.selectItem(at: ThemeMode.allCases.firstIndex(of: Theme.mode) ?? 0)
        if let fam = Theme.fontFamily, fontFamily.itemTitles.contains(fam) { fontFamily.selectItem(withTitle: fam) } else { fontFamily.selectItem(at: 0) }
        fontPreview.font = Theme.editorFont
        reopen.state = ((UserDefaults.standard.object(forKey: "og.reopenLast") as? Bool) ?? true) ? .on : .off
        let m = ModelServerManager.shared
        aiEnabled.state = m.enabled ? .on : .off
        let cfg = m.config
        backend.selectItem(at: ModelBackend.allCases.firstIndex(of: cfg.backend) ?? 0)
        fillModels(for: cfg.backend)
        model.stringValue = ModelPreset.all.first { $0.id == cfg.model }?.title ?? cfg.model
        custom.stringValue = cfg.customCommand
        updateRows()
        refreshStatus()
    }

    private func fillModels(for b: ModelBackend) {
        model.removeAllItems()
        model.addItems(withObjectValues: ModelPreset.presets(for: b).map(\.title))
    }

    private func updateRows() {
        let b = ModelBackend.allCases[max(0, backend.indexOfSelectedItem)]
        customRow.isHidden = b != .custom
        model.isEnabled = b != .custom
    }

    private func refreshStatus() {
        let m = ModelServerManager.shared
        switch m.phase {
        case .off: status.stringValue = "Server: off"; status.textColor = .secondaryLabelColor; actionButton.title = "Start"
        case .starting(let d): status.stringValue = "Server: \(d)"; status.textColor = .systemOrange; actionButton.title = "Restart"
        case .ready: status.stringValue = "Server: ready on 127.0.0.1:\(m.port ?? 0)"; status.textColor = .systemGreen; actionButton.title = "Restart"
        case .failed(let why): status.stringValue = "Server failed: \(why)"; status.textColor = .systemRed; actionButton.title = "Retry"
        }
        actionButton.isEnabled = m.enabled
        logView.string = m.log.suffix(200).joined(separator: "\n")
        logView.scrollToEndOfDocument(nil)
    }

    // MARK: - Actions

    private func save(_ change: (inout ModelServerConfig) -> Void) {
        var cfg = ModelServerManager.shared.config
        change(&cfg)
        ModelServerManager.shared.config = cfg
    }

    @objc private func enabledChanged() {
        ModelServerManager.shared.enabled = aiEnabled.state == .on
        refreshStatus()
    }

    @objc private func backendChanged() {
        let b = ModelBackend.allCases[max(0, backend.indexOfSelectedItem)]
        fillModels(for: b)
        let first = ModelPreset.presets(for: b).first
        model.stringValue = first?.title ?? ""
        updateRows()
        save { $0.backend = b; $0.model = first?.id ?? "" }
    }

    @objc private func modelChanged() {
        let text = model.stringValue.trimmingCharacters(in: .whitespaces)
        let id = ModelPreset.all.first { $0.title == text }?.id ?? text
        guard !id.isEmpty else { return }
        save { $0.model = id }
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.modelChanged() }
        }
    }

    @objc private func customChanged() {
        save { $0.customCommand = custom.stringValue }
    }

    @objc private func actionClicked() {
        let m = ModelServerManager.shared
        switch m.phase {
        case .failed: m.retry()
        case .off: m.enabled = true
        default: m.restart()
        }
    }

    static let systemMono = "System Monospaced (SF Mono)"

    @objc private func fontChanged() {
        Theme.setFont(family: Theme.fontFamily, size: CGFloat(fontSize.doubleValue))
        fontLabel.stringValue = "Editor font size: \(Int(Theme.fontSize))"
        fontPreview.font = Theme.editorFont
    }

    @objc private func familyChanged() {
        let title = fontFamily.titleOfSelectedItem
        Theme.setFont(family: title == Self.systemMono ? nil : title, size: Theme.fontSize)
        fontPreview.font = Theme.editorFont
    }

    @objc private func themeChanged() {
        Theme.mode = ThemeMode.allCases[max(0, themePopup.indexOfSelectedItem)]
    }

    @objc private func reopenChanged() {
        UserDefaults.standard.set(reopen.state == .on, forKey: "og.reopenLast")
    }
}
