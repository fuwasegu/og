import AppKit
import OgCore

/// Preferences: font size, local AI completion, session behavior.
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()
    private let fontSize = NSStepper()
    private let fontLabel = NSTextField(labelWithString: "")
    private let aiEnabled = NSButton(checkboxWithTitle: "Enable inline completion from a local llama-server (FIM)", target: nil, action: nil)
    private let aiEndpoint = NSTextField()
    private let aiStatus = NSTextField(labelWithString: "")
    private let reopen = NSButton(checkboxWithTitle: "Reopen the last project on launch", target: nil, action: nil)

    private init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 260), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Settings"
        super.init(window: w)
        build()
        w.center()
    }

    required init?(coder: NSCoder) { nil }

    private func build() {
        fontSize.minValue = 9
        fontSize.maxValue = 32
        fontSize.increment = 1
        fontSize.doubleValue = Double(Theme.fontSize)
        fontSize.target = self
        fontSize.action = #selector(fontChanged)
        fontLabel.stringValue = "Editor font size: \(Int(Theme.fontSize))"
        aiEnabled.state = EditorController.aiEnabled ? .on : .off
        aiEnabled.target = self
        aiEnabled.action = #selector(aiChanged)
        aiEndpoint.stringValue = EditorController.aiEndpoint
        aiEndpoint.placeholderString = "http://127.0.0.1:8080"
        aiEndpoint.target = self
        aiEndpoint.action = #selector(aiChanged)
        aiStatus.font = Theme.smallFont
        aiStatus.textColor = .secondaryLabelColor
        aiStatus.stringValue = "Only loopback addresses are accepted; code never leaves this Mac."
        reopen.state = ((UserDefaults.standard.object(forKey: "og.reopenLast") as? Bool) ?? true) ? .on : .off
        reopen.target = self
        reopen.action = #selector(reopenChanged)

        let fontRow = NSStackView(views: [fontLabel, fontSize])
        let endpointRow = NSStackView(views: [NSTextField(labelWithString: "Endpoint:"), aiEndpoint])
        aiEndpoint.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let stack = NSStackView(views: [fontRow, reopen, NSBox(), aiEnabled, endpointRow, aiStatus])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        window?.contentView = stack
    }

    @objc private func fontChanged() {
        AppDelegate.shared?.activeProject?.ogZoomReset(nil)
        Theme.fontSize = CGFloat(fontSize.doubleValue)
        UserDefaults.standard.set(fontSize.doubleValue, forKey: "og.fontSize")
        fontLabel.stringValue = "Editor font size: \(Int(Theme.fontSize))"
        if let p = AppDelegate.shared?.activeProject { for e in p.editorArea.editors { e.applyFontChange() } }
    }

    @objc private func aiChanged() {
        let text = aiEndpoint.stringValue.trimmingCharacters(in: .whitespaces)
        if let url = URL(string: text), LocalCompletionClient.isLoopback(url) {
            EditorController.aiEndpoint = text
            aiStatus.stringValue = "Only loopback addresses are accepted; code never leaves this Mac."
            aiStatus.textColor = .secondaryLabelColor
        } else {
            // spec completion.fsl DES-1: non-loopback endpoints are rejected.
            aiStatus.stringValue = "Rejected: the endpoint must be 127.0.0.1, ::1 or localhost."
            aiStatus.textColor = .systemRed
            aiEndpoint.stringValue = EditorController.aiEndpoint
        }
        EditorController.aiEnabled = aiEnabled.state == .on
    }

    @objc private func reopenChanged() {
        UserDefaults.standard.set(reopen.state == .on, forKey: "og.reopenLast")
    }
}
