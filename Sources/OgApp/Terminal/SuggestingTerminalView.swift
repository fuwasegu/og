import AppKit
import OgCore
@preconcurrency import SwiftTerm

/// A shell terminal that shows the rest of a likely command in faint text after the cursor
/// (`go mod tidy`, `go run .`, the project's own history). → accepts it.
///
/// og never touches the shell's line itself: the hint is an overlay, and accepting it just types
/// the remaining characters. It hides whenever og cannot be sure what is on the line.
@MainActor
final class SuggestingTerminalView: LocalProcessTerminalView {
    /// Most-recent-first command history for this project.
    var history: () -> [String] = { [] }
    var onSubmit: (String) -> Void = { _ in }

    private var tracker = TerminalLineTracker()
    private let ghost = NSTextField(labelWithString: "")
    private var suggestion: String?
    private var refreshQueued = false

    override init(frame: CGRect, font: NSFont?, options: TerminalOptions) {
        super.init(frame: frame, font: font, options: options)
        ghost.isHidden = true
        ghost.drawsBackground = false
        ghost.isBordered = false
        ghost.lineBreakMode = .byClipping
        addSubview(ghost)
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Bytes to the shell

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if let rest = suggestion, Self.isRightArrow(data) {
            let bytes = ArraySlice(Array(rest.utf8))
            _ = tracker.feed(bytes)
            hideGhost()
            super.send(source: source, data: bytes)
            return
        }
        if let cmd = tracker.feed(data) { onSubmit(cmd) }
        hideGhost()
        super.send(source: source, data: data)
        queueRefresh()
    }

    // MARK: - Bytes from the shell

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        queueRefresh()
    }

    private func queueRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        // After the shell echoed the keystroke: coalesce a burst of output into one check.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshQueued = false
                self?.refreshGhost()
            }
        }
    }

    private func refreshGhost() {
        guard let typed = tracker.line, !typed.isEmpty,
              let rest = TerminalSuggestions.completion(for: typed, history: history()),
              lineMatches(typed) else { hideGhost(); return }
        suggestion = rest
        ghost.font = font
        ghost.textColor = Theme.secondaryText.withAlphaComponent(0.75)
        ghost.stringValue = rest
        ghost.sizeToFit()
        let caret = caretFrame
        ghost.frame.origin = CGPoint(x: caret.minX, y: caret.minY + (caret.height - ghost.frame.height) / 2)
        ghost.isHidden = false
    }

    /// The screen agrees with what og thinks was typed: the text before the cursor ends with it,
    /// nothing follows the cursor (a shell's own suggestion, e.g. zsh-autosuggestions, wins), and
    /// no full-screen program is running.
    private func lineMatches(_ typed: String) -> Bool {
        let t = getTerminal()
        guard !t.isCurrentBufferAlternate else { return false }
        let cur = t.getCursorLocation()
        guard let line = t.getLine(row: cur.y)?.translateToString() else { return false }
        let chars = Array(line)
        guard cur.x <= chars.count else { return false }
        let before = String(chars[..<cur.x])
        let after = String(chars[cur.x...])
        return before.hasSuffix(typed) && after.allSatisfy { $0 == " " || $0 == "\0" }
    }

    private func hideGhost() {
        suggestion = nil
        ghost.isHidden = true
    }

    private static func isRightArrow(_ d: ArraySlice<UInt8>) -> Bool {
        Array(d) == [0x1b, 0x5b, 0x43] || Array(d) == [0x1b, 0x4f, 0x43]
    }

    // MARK: - Headless driver

    var debugGhost: String? { ghost.isHidden ? nil : ghost.stringValue }
}
