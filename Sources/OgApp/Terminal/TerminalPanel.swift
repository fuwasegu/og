import AppKit
import OgCore

// STUB — owned by the Terminal agent. Keep the class name, init(context:), and the public methods.
@MainActor
final class TerminalPanel: NSViewController {
    let context: ProjectContext

    init(context: ProjectContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let label = NSTextField(labelWithString: "TerminalPanel")
        label.textColor = .secondaryLabelColor
        let v = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(label)
        NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: v.centerXAnchor), label.centerYAnchor.constraint(equalTo: v.centerYAnchor)])
        view = v
    }

    /// Opens a new terminal tab in the project root.
    func newTab() {}
    /// Runs a shell command in the active terminal tab.
    func run(command: String) {}
}
