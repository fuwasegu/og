import AppKit
import OgCore

/// A node in the variables outline. Children are fetched lazily via `variablesReference`.
@MainActor
final class DebugVarNode: NSObject {
    let name: String
    let value: String
    let type: String
    let reference: Int
    /// Stop epoch this node belongs to; stale nodes never fetch (DES-4).
    let epoch: Int
    let isScope: Bool
    var children: [DebugVarNode]?
    var loading = false

    init(name: String, value: String, type: String, reference: Int, epoch: Int, isScope: Bool = false) {
        self.name = name
        self.value = value
        self.type = type
        self.reference = reference
        self.epoch = epoch
        self.isScope = isScope
    }

    convenience init(_ v: DAPVariable, epoch: Int) {
        self.init(name: v.name, value: v.value, type: v.type, reference: v.variablesReference, epoch: epoch)
    }

    convenience init(_ s: DAPScope, epoch: Int) {
        self.init(name: s.name, value: "", type: "", reference: s.variablesReference, epoch: epoch, isScope: true)
    }

    var attributed: NSAttributedString {
        let out = NSMutableAttributedString()
        let font = Theme.editorFont
        if isScope {
            out.append(NSAttributedString(string: name, attributes: [.font: Theme.uiFont, .foregroundColor: Theme.text]))
            return out
        }
        out.append(NSAttributedString(string: name, attributes: [.font: font, .foregroundColor: Theme.function]))
        out.append(NSAttributedString(string: " = ", attributes: [.font: font, .foregroundColor: Theme.secondaryText]))
        if !type.isEmpty {
            out.append(NSAttributedString(string: "{\(type)} ", attributes: [.font: font, .foregroundColor: Theme.secondaryText]))
        }
        let color = value.hasPrefix("\"") ? Theme.string : (Double(value) != nil ? Theme.number : Theme.text)
        out.append(NSAttributedString(string: value, attributes: [.font: font, .foregroundColor: color]))
        return out
    }
}

/// Single-label cell used by the frames table and the variables outline.
@MainActor
final class DebugCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }
}

/// Read-only console for program output.
@MainActor
final class DebugConsole {
    let scroll = NSScrollView()
    let textView = NSTextView()
    private static let maxLength = 2_000_000

    init() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = true
        textView.backgroundColor = Theme.background
        textView.textColor = Theme.text
        textView.font = Theme.editorFont
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.background
        scroll.borderType = .noBorder
    }

    func clear() { textView.textStorage?.setAttributedString(NSAttributedString()) }

    func append(_ text: String, color: NSColor = Theme.text) {
        guard let storage = textView.textStorage, !text.isEmpty else { return }
        let atBottom = scroll.documentVisibleRect.maxY >= textView.bounds.maxY - 4
        storage.append(NSAttributedString(string: text, attributes: [.font: Theme.editorFont, .foregroundColor: color]))
        if storage.length > DebugConsole.maxLength {
            storage.deleteCharacters(in: NSRange(location: 0, length: storage.length - DebugConsole.maxLength / 2))
        }
        if atBottom { textView.scrollToEndOfDocument(nil) }
    }

    /// Appends `text` on its own line(s).
    func line(_ text: String, color: NSColor = Theme.secondaryText) {
        let ns = (textView.textStorage?.string ?? "") as NSString
        let prefix = ns.length == 0 || ns.character(at: ns.length - 1) == 10 ? "" : "\n"
        append(prefix + text + "\n", color: color)
    }
}
