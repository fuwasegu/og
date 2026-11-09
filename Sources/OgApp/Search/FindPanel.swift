import AppKit
import OgCore

// STUB — owned by the Search agent. Keep the class name, init(context:), and the public methods.
@MainActor
final class FindPanel: NSViewController {
    let context: ProjectContext

    init(context: ProjectContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let label = NSTextField(labelWithString: "FindPanel")
        label.textColor = .secondaryLabelColor
        let v = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(label)
        NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: v.centerXAnchor), label.centerYAnchor.constraint(equalTo: v.centerYAnchor)])
        view = v
    }

    /// Find in files (Cmd-Shift-F); prefills the query.
    func findInFiles(_ query: String) {}
    /// Shows a list of locations (Find Usages / multiple implementations) grouped by file.
    func showResults(title: String, locations: [LSPLocation]) {}
}
