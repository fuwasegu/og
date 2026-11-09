import AppKit
import OgCore

// STUB — owned by the Git agent. Keep the class name, init(context:), and the public methods.
@MainActor
final class GitPanel: NSViewController {
    let context: ProjectContext

    init(context: ProjectContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let label = NSTextField(labelWithString: "GitPanel")
        label.textColor = .secondaryLabelColor
        let v = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(label)
        NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: v.centerXAnchor), label.centerYAnchor.constraint(equalTo: v.centerYAnchor)])
        view = v
    }

    /// Shows the commit view (changed files with checkboxes + message).
    func focusCommit() {}
    /// Shows a branch popup (checkout / new branch / stash) anchored to a view.
    func showBranchMenu(from view: NSView) {}
}
