import AppKit
import OgCore

// STUB — owned by the Debug agent. Keep the class name, init(context:), and the public methods.
@MainActor
final class DebugPanel: NSViewController {
    let context: ProjectContext

    init(context: ProjectContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let label = NSTextField(labelWithString: "DebugPanel")
        label.textColor = .secondaryLabelColor
        let v = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(label)
        NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: v.centerXAnchor), label.centerYAnchor.constraint(equalTo: v.centerYAnchor)])
        view = v
    }

    /// Starts a delve DAP session for the request using context.breakpoints.
    func startDebugging(_ request: RunRequest) {}
    var isDebugging: Bool { false }
    func resume() {}
    func stepOver() {}
    func stepInto() {}
    func stepOut() {}
    func stop() {}
}
