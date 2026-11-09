import AppKit
import OgCore

// STUB — owned by the Run agent. Keep the class name, init(context:), and the public methods.
@MainActor
final class RunPanel: NSViewController {
    let context: ProjectContext

    init(context: ProjectContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let label = NSTextField(labelWithString: "RunPanel")
        label.textColor = .secondaryLabelColor
        let v = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(label)
        NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: v.centerXAnchor), label.centerYAnchor.constraint(equalTo: v.centerYAnchor)])
        view = v
    }

    /// Starts a run / test / bench; shows output and the test tree.
    func run(_ request: RunRequest) {}
    /// Re-runs the last request.
    func rerun() {}
    func stop() {}
}
