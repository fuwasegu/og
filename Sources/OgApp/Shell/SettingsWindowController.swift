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

    // Offline Go Docs (FR-19, FR-20, FR-23, FR-24, FR-29, Q-4, L-9)
    private let docsEnabled = NSButton(checkboxWithTitle: "Enable offline Go Docs lookup (local-only; independent of inline AI completion)", target: nil, action: nil)
    private let docsBatchPolicy = NSPopUpButton()
    private let docsVersionCombo = NSComboBox()
    private let docsInstallButton = NSButton(title: "Add / Update Pack", target: nil, action: nil)
    private let docsImportGorootButton = NSButton(title: "Import GOROOT…", target: nil, action: nil)
    private let docsDeleteButton = NSButton(title: "Delete Pack", target: nil, action: nil)
    private let docsCancelButton = NSButton(title: "Cancel Batch", target: nil, action: nil)
    private let docsLicenseButton = NSButton(title: "BSD License…", target: nil, action: nil)
    private let docsPacksLabel = NSTextField(wrappingLabelWithString: "")
    private let docsProgressBar = NSProgressIndicator()
    private let docsProgressLabel = NSTextField(labelWithString: "")

    private init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 680), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Settings"
        super.init(window: w)
        build()
        load()
        w.center()
        NotificationCenter.default.addObserver(forName: .ogModelServerChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStatus() }
        }
        NotificationCenter.default.addObserver(forName: .ogDocsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDocs() }
        }
        NotificationCenter.default.addObserver(forName: .ogDocsBatchProgressChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDocs() }
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

        // Offline Go Docs controls (FR-19, FR-20, FR-23, FR-24, FR-29, L-9)
        docsEnabled.target = self
        docsEnabled.action = #selector(docsEnabledChanged)
        for p in DocsBatchRunPolicy.allCases { docsBatchPolicy.addItem(withTitle: p.title) }
        docsBatchPolicy.target = self
        docsBatchPolicy.action = #selector(docsPolicyChanged)
        docsVersionCombo.isEditable = true
        docsVersionCombo.completes = false
        docsVersionCombo.placeholderString = "go1.23"
        docsVersionCombo.widthAnchor.constraint(equalToConstant: 96).isActive = true
        docsInstallButton.target = self
        docsInstallButton.action = #selector(docsInstallClicked)
        docsImportGorootButton.target = self
        docsImportGorootButton.action = #selector(docsImportGorootClicked)
        docsDeleteButton.target = self
        docsDeleteButton.action = #selector(docsDeleteClicked)
        docsCancelButton.target = self
        docsCancelButton.action = #selector(docsCancelClicked)
        docsLicenseButton.target = self
        docsLicenseButton.action = #selector(docsLicenseClicked)
        docsPacksLabel.font = Theme.smallFont
        docsPacksLabel.textColor = Theme.secondaryText
        docsProgressBar.isIndeterminate = false
        docsProgressBar.minValue = 0
        docsProgressBar.maxValue = 1
        docsProgressBar.controlSize = .small
        docsProgressLabel.font = Theme.smallFont
        docsProgressLabel.textColor = Theme.secondaryText
        let docsButtons = NSStackView(views: [docsVersionCombo, docsInstallButton, docsImportGorootButton, docsDeleteButton, docsCancelButton, docsLicenseButton])
        docsButtons.orientation = .horizontal
        docsButtons.spacing = 6

        let stack = NSStackView(views: [
            row("Theme", themePopup), row("Font", fontFamily), NSStackView(views: [fontLabel, fontSize]), fontPreview,
            reopen, NSBox(),
            aiEnabled, row("Backend", backend), row("Model", model), customRow, hint, statusRow, logScroll,
            NSBox(),
            docsEnabled, row("Indexing", docsBatchPolicy), docsButtons, docsPacksLabel, docsProgressBar, docsProgressLabel
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        statusRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        logScroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        docsProgressBar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        docsPacksLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        let scroll = NSScrollView()
        scroll.documentView = stack
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        window?.contentView = scroll
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
        refreshDocs()
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

    // MARK: - Offline Go Docs Actions (FR-19, FR-20, FR-23, FR-24, FR-29)

    private func refreshDocs() {
        let d = DocsManager.shared
        docsEnabled.state = d.enabled ? .on : .off
        docsBatchPolicy.selectItem(at: DocsBatchRunPolicy.allCases.firstIndex(of: d.batchPolicy) ?? 0)

        let packs = d.installedPacks
        // L-9: populate combo dynamically from installed packs, cached toolchain version, and bundled default.
        var versions: [String] = []
        for p in packs where !versions.contains(p.goVersion) { versions.append(p.goVersion) }
        if let detected = d.detectedToolchainVersion?.minorKey, !versions.contains(detected) {
            versions.append(detected)
        }
        if !versions.contains(BundledGoCorpus.defaultVersion) {
            versions.append(BundledGoCorpus.defaultVersion)
        }
        let currentSelection = docsVersionCombo.stringValue.trimmingCharacters(in: .whitespaces)
        docsVersionCombo.removeAllItems()
        docsVersionCombo.addItems(withObjectValues: versions.sorted(by: >).map { "go\($0)" })
        if currentSelection.isEmpty {
            docsVersionCombo.stringValue = "go\(BundledGoCorpus.defaultVersion)"
        }

        if packs.isEmpty {
            docsPacksLabel.stringValue = "Installed packs: none (enabling installs bundled go\(BundledGoCorpus.defaultVersion) core pack offline)"
        } else {
            let lines = packs.map { p in
                let kb = max(1, p.sizeBytes / 1024)
                let mode = p.status == .ready ? "ready (FTS + semantic)" : "FTS-only"
                return "• go\(p.goVersion): \(p.chunkCount) chunks, \(kb) KB [\(mode)]"
            }
            docsPacksLabel.stringValue = "Installed packs:\n" + lines.joined(separator: "\n")
        }

        if let p = d.activeProgress {
            docsProgressBar.doubleValue = p.fractionCompleted
            let estKB = max(1, p.estimatedBytes / 1024)
            let isRunning = p.phase == .extracting || p.phase == .buildingFTS || p.phase == .embedding || p.phase == .activating
            docsCancelButton.isEnabled = isRunning
            docsProgressLabel.stringValue = "Batch go\(p.goVersion): \(p.phase.rawValue) (\(p.processedChunks)/\(p.totalChunks) chunks, est. \(estKB) KB, reused \(p.reusedVectors))"
        } else if let err = d.lastError {
            docsProgressBar.doubleValue = 0
            docsCancelButton.isEnabled = false
            docsProgressLabel.stringValue = "Docs error: \(err)"
        } else {
            docsProgressBar.doubleValue = 0
            docsCancelButton.isEnabled = false
            docsProgressLabel.stringValue = "Batch: idle"
        }
    }

    private var knownDocsVersions: Set<String> {
        let d = DocsManager.shared
        var versions = Set(d.installedPacks.map(\.goVersion))
        if let detected = d.detectedToolchainVersion?.minorKey {
            versions.insert(detected)
        }
        versions.insert(BundledGoCorpus.defaultVersion)
        return versions
    }

    private func parsedSelectedDocsVersion() -> String? {
        let raw = docsVersionCombo.stringValue.trimmingCharacters(in: .whitespaces)
        return GoVersion(parsing: raw)?.minorKey
    }

    private func showDocsAlert(message: String, info: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = info
        alert.addButton(withTitle: "OK")
        if let w = window { alert.beginSheetModal(for: w, completionHandler: nil) } else { alert.runModal() }
    }

    @objc private func docsEnabledChanged() {
        DocsManager.shared.enabled = docsEnabled.state == .on
        refreshDocs()
    }

    @objc private func docsPolicyChanged() {
        DocsManager.shared.batchPolicy = DocsBatchRunPolicy.allCases[max(0, docsBatchPolicy.indexOfSelectedItem)]
    }

    @objc private func docsInstallClicked() {
        guard let ver = parsedSelectedDocsVersion() else {
            showDocsAlert(
                message: "Invalid Go Version",
                info: "Enter a valid Go version such as go\(BundledGoCorpus.defaultVersion)."
            )
            return
        }
        // R-3: require explicit confirmation before creating a bundled-excerpt pack for an unverified version.
        if !knownDocsVersions.contains(ver) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Create pack for unverified Go version go\(ver)?"
            alert.informativeText = "go\(ver) was not detected among installed packs or your local Go toolchain. Bundled excerpts are curated for go\(BundledGoCorpus.defaultVersion); for an accurate pack of another Go version, use \"Import GOROOT…\" instead. Continue anyway?"
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Create Pack")
            let proceed: (NSApplication.ModalResponse) -> Void = { response in
                if response == .alertSecondButtonReturn {
                    DocsManager.shared.startBundledPackIngestion(goVersion: ver)
                }
            }
            if let w = window {
                alert.beginSheetModal(for: w, completionHandler: proceed)
            } else {
                proceed(alert.runModal())
            }
            return
        }
        DocsManager.shared.startBundledPackIngestion(goVersion: ver)
    }

    @objc private func docsImportGorootClicked() {
        guard let ver = parsedSelectedDocsVersion() else {
            showDocsAlert(
                message: "Invalid Go Version",
                info: "Enter the Go version matching the GOROOT you are importing (e.g. go\(BundledGoCorpus.defaultVersion))."
            )
            return
        }
        Task { @MainActor [weak self] in
            let detected = await GoVersionResolver.detectGorootAsync()
            guard self != nil else { return }
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.message = "Choose a local GOROOT directory (containing src/) for go\(ver)"
            if let detected { panel.directoryURL = detected }
            if panel.runModal() == .OK, let url = panel.url {
                DocsManager.shared.startGorootIngestion(goroot: url, goVersion: ver)
            }
        }
    }

    @objc private func docsDeleteClicked() {
        guard let ver = parsedSelectedDocsVersion() else { return }
        DocsManager.shared.deletePack(goVersion: ver)
    }

    @objc private func docsCancelClicked() {
        DocsManager.shared.cancelActiveBatch()
    }

    @objc private func docsLicenseClicked() {
        let alert = NSAlert()
        alert.messageText = "Go Documentation License (BSD-3-Clause)"
        alert.informativeText = DocsLicense.goBSD3Clause
        alert.addButton(withTitle: "OK")
        if let w = window { alert.beginSheetModal(for: w, completionHandler: nil) } else { alert.runModal() }
    }
}
