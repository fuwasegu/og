import AppKit
import CoreText
import Darwin
import Foundation
import SwiftUI

/// Represents a single character cell in the terminal grid.
public struct TerminalCell: Sendable, Equatable {
    public var scalar: Character
    public var foreground: TerminalColor
    public var background: TerminalColor
    public var isBold: Bool
    public var isDim: Bool

    public static let empty = TerminalCell(
        scalar: " ",
        foreground: .defaultForeground,
        background: .defaultBackground,
        isBold: false,
        isDim: false
    )
}

public enum TerminalColor: Sendable, Equatable {
    case defaultForeground
    case defaultBackground
    case ansi(UInt8)
    case rgb(UInt8, UInt8, UInt8)

    public func nsColor(isBackground: Bool) -> NSColor {
        switch self {
        case .defaultForeground:
            return NSColor(calibratedWhite: 0.92, alpha: 1.0)
        case .defaultBackground:
            return isBackground
                ? .clear
                : NSColor(calibratedWhite: 0.08, alpha: 1.0)
        case .ansi(let code):
            return Self.ansiPalette(code)
        case .rgb(let r, let g, let b):
            return NSColor(
                calibratedRed: CGFloat(r) / 255.0,
                green: CGFloat(g) / 255.0,
                blue: CGFloat(b) / 255.0,
                alpha: 1.0
            )
        }
    }

    private static func ansiPalette(_ code: UInt8) -> NSColor {
        switch code {
        case 0: return NSColor(calibratedRed: 0.15, green: 0.16, blue: 0.20, alpha: 1.0)
        case 1: return NSColor(calibratedRed: 0.96, green: 0.38, blue: 0.44, alpha: 1.0)
        case 2: return NSColor(calibratedRed: 0.42, green: 0.88, blue: 0.58, alpha: 1.0)
        case 3: return NSColor(calibratedRed: 0.96, green: 0.80, blue: 0.38, alpha: 1.0)
        case 4: return NSColor(calibratedRed: 0.38, green: 0.68, blue: 0.98, alpha: 1.0)
        case 5: return NSColor(calibratedRed: 0.82, green: 0.56, blue: 0.98, alpha: 1.0)
        case 6: return NSColor(calibratedRed: 0.32, green: 0.86, blue: 0.92, alpha: 1.0)
        case 7: return NSColor(calibratedWhite: 0.86, alpha: 1.0)
        case 8: return NSColor(calibratedWhite: 0.48, alpha: 1.0)
        case 9: return NSColor(calibratedRed: 1.00, green: 0.50, blue: 0.55, alpha: 1.0)
        case 10: return NSColor(calibratedRed: 0.55, green: 0.95, blue: 0.68, alpha: 1.0)
        case 11: return NSColor(calibratedRed: 1.00, green: 0.88, blue: 0.50, alpha: 1.0)
        case 12: return NSColor(calibratedRed: 0.52, green: 0.78, blue: 1.00, alpha: 1.0)
        case 13: return NSColor(calibratedRed: 0.90, green: 0.68, blue: 1.00, alpha: 1.0)
        case 14: return NSColor(calibratedRed: 0.48, green: 0.94, blue: 0.98, alpha: 1.0)
        case 15: return NSColor(calibratedWhite: 0.98, alpha: 1.0)
        default:
            if code >= 16 && code <= 231 {
                let idx = Int(code - 16)
                let r = CGFloat((idx / 36) % 6) / 5.0
                let g = CGFloat((idx / 6) % 6) / 5.0
                let b = CGFloat(idx % 6) / 5.0
                return NSColor(calibratedRed: r, green: g, blue: b, alpha: 1.0)
            } else if code >= 232 {
                let gray = CGFloat(code - 232) / 23.0
                return NSColor(calibratedWhite: gray, alpha: 1.0)
            }
            return NSColor(calibratedWhite: 0.90, alpha: 1.0)
        }
    }
}

/// High-speed VT100/ANSI screen buffer with scrollback history.
public struct TerminalScreenBuffer: Sendable {
    public private(set) var cols: Int
    public private(set) var rows: Int
    public let maxScrollbackLines: Int

    public private(set) var scrollback: [[TerminalCell]] = []
    public private(set) var grid: [[TerminalCell]]
    public private(set) var cursorRow: Int = 0
    public private(set) var cursorCol: Int = 0
    public private(set) var version: UInt64 = 1

    private var currentFG: TerminalColor = .defaultForeground
    private var currentBG: TerminalColor = .defaultBackground
    private var currentBold: Bool = false
    private var currentDim: Bool = false

    private enum EscapeState: Sendable {
        case ground
        case escape
        case csi(String)
        case osc(String)
    }

    private var parseState: EscapeState = .ground

    public init(cols: Int = 110, rows: Int = 14, maxScrollbackLines: Int = 2000) {
        let safeCols = max(20, cols)
        let safeRows = max(4, rows)
        self.cols = safeCols
        self.rows = safeRows
        self.maxScrollbackLines = maxScrollbackLines
        self.grid = Array(
            repeating: Array(repeating: .empty, count: safeCols),
            count: safeRows
        )
    }

    public mutating func resize(cols newCols: Int, rows newRows: Int) {
        let safeCols = max(20, newCols)
        let safeRows = max(4, newRows)
        guard safeCols != cols || safeRows != rows else { return }

        var newGrid = Array(
            repeating: Array(repeating: TerminalCell.empty, count: safeCols),
            count: safeRows
        )
        let copyRows = min(rows, safeRows)
        let copyCols = min(cols, safeCols)
        for r in 0..<copyRows {
            for c in 0..<copyCols {
                newGrid[r][c] = grid[r][c]
            }
        }
        self.cols = safeCols
        self.rows = safeRows
        self.grid = newGrid
        self.cursorRow = min(cursorRow, safeRows - 1)
        self.cursorCol = min(cursorCol, safeCols - 1)
        self.version &+= 1
    }

    public mutating func clearScreen() {
        grid = Array(
            repeating: Array(repeating: .empty, count: cols),
            count: rows
        )
        cursorRow = 0
        cursorCol = 0
        version &+= 1
    }

    public mutating func feed(_ text: String) {
        for ch in text {
            processCharacter(ch)
        }
        version &+= 1
    }

    private mutating func processCharacter(_ ch: Character) {
        switch parseState {
        case .ground:
            if ch == "\u{1B}" {
                parseState = .escape
            } else if ch == "\r\n" {
                cursorCol = 0
                lineFeed()
            } else if ch == "\r" {
                cursorCol = 0
            } else if ch == "\n" {
                cursorCol = 0
                lineFeed()
            } else if ch == "\u{08}" || ch == "\u{7F}" {
                if cursorCol > 0 {
                    cursorCol -= 1
                }
            } else if ch == "\t" {
                let nextStop = ((cursorCol / 4) + 1) * 4
                cursorCol = min(cols - 1, nextStop)
            } else if ch >= " " {
                putGraphicCharacter(ch)
            }

        case .escape:
            if ch == "[" {
                parseState = .csi("")
            } else if ch == "]" {
                parseState = .osc("")
            } else {
                parseState = .ground
            }

        case .csi(var params):
            if ch.isNumber || ch == ";" || ch == "?" {
                params.append(ch)
                parseState = .csi(params)
            } else {
                handleCSISequence(params: params, finalByte: ch)
                parseState = .ground
            }

        case .osc(var content):
            if ch == "\u{07}" || (ch == "\\" && content.last == "\u{1B}") {
                parseState = .ground
            } else {
                content.append(ch)
                if content.count > 256 {
                    parseState = .ground
                } else {
                    parseState = .osc(content)
                }
            }
        }
    }

    private mutating func putGraphicCharacter(_ ch: Character) {
        if cursorCol >= cols {
            cursorCol = 0
            lineFeed()
        }
        grid[cursorRow][cursorCol] = TerminalCell(
            scalar: ch,
            foreground: currentFG,
            background: currentBG,
            isBold: currentBold,
            isDim: currentDim
        )
        cursorCol += 1
    }

    private mutating func lineFeed() {
        if cursorRow + 1 < rows {
            cursorRow += 1
        } else {
            let evicted = grid.removeFirst()
            scrollback.append(evicted)
            if scrollback.count > maxScrollbackLines {
                scrollback.removeFirst(scrollback.count - maxScrollbackLines)
            }
            grid.append(Array(repeating: .empty, count: cols))
        }
    }

    private mutating func handleCSISequence(params: String, finalByte: Character) {
        let cleanParams = params.replacingOccurrences(of: "?", with: "")
        let numbers = cleanParams.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        let first = numbers.first ?? 0

        switch finalByte {
        case "m":
            applySGR(numbers.isEmpty ? [0] : numbers)
        case "A":
            cursorRow = max(0, cursorRow - max(1, first))
        case "B":
            cursorRow = min(rows - 1, cursorRow + max(1, first))
        case "C":
            cursorCol = min(cols - 1, cursorCol + max(1, first))
        case "D":
            cursorCol = max(0, cursorCol - max(1, first))
        case "G":
            cursorCol = max(0, min(cols - 1, max(1, first) - 1))
        case "H", "f":
            let targetRow = max(1, numbers.first ?? 1) - 1
            let targetCol = max(1, numbers.count > 1 ? numbers[1] : 1) - 1
            cursorRow = max(0, min(rows - 1, targetRow))
            cursorCol = max(0, min(cols - 1, targetCol))
        case "J":
            if first == 2 || first == 3 {
                clearScreen()
            } else if first == 0 {
                for c in cursorCol..<cols {
                    grid[cursorRow][c] = .empty
                }
                if cursorRow + 1 < rows {
                    for r in (cursorRow + 1)..<rows {
                        grid[r] = Array(repeating: .empty, count: cols)
                    }
                }
            }
        case "K":
            if first == 0 {
                for c in cursorCol..<cols {
                    grid[cursorRow][c] = .empty
                }
            } else if first == 1 {
                for c in 0...min(cursorCol, cols - 1) {
                    grid[cursorRow][c] = .empty
                }
            } else if first == 2 {
                grid[cursorRow] = Array(repeating: .empty, count: cols)
            }
        default:
            break
        }
    }

    private mutating func applySGR(_ codes: [Int]) {
        var idx = 0
        while idx < codes.count {
            let code = codes[idx]
            switch code {
            case 0:
                currentFG = .defaultForeground
                currentBG = .defaultBackground
                currentBold = false
                currentDim = false
            case 1:
                currentBold = true
            case 2:
                currentDim = true
            case 22:
                currentBold = false
                currentDim = false
            case 30...37:
                currentFG = .ansi(UInt8(code - 30 + (currentBold ? 8 : 0)))
            case 39:
                currentFG = .defaultForeground
            case 40...47:
                currentBG = .ansi(UInt8(code - 40))
            case 49:
                currentBG = .defaultBackground
            case 90...97:
                currentFG = .ansi(UInt8(code - 90 + 8))
            case 100...107:
                currentBG = .ansi(UInt8(code - 100 + 8))
            case 38:
                if idx + 2 < codes.count && codes[idx + 1] == 5 {
                    currentFG = .ansi(UInt8(clamping: codes[idx + 2]))
                    idx += 2
                } else if idx + 4 < codes.count && codes[idx + 1] == 2 {
                    currentFG = .rgb(
                        UInt8(clamping: codes[idx + 2]),
                        UInt8(clamping: codes[idx + 3]),
                        UInt8(clamping: codes[idx + 4])
                    )
                    idx += 4
                }
            case 48:
                if idx + 2 < codes.count && codes[idx + 1] == 5 {
                    currentBG = .ansi(UInt8(clamping: codes[idx + 2]))
                    idx += 2
                } else if idx + 4 < codes.count && codes[idx + 1] == 2 {
                    currentBG = .rgb(
                        UInt8(clamping: codes[idx + 2]),
                        UInt8(clamping: codes[idx + 3]),
                        UInt8(clamping: codes[idx + 4])
                    )
                    idx += 4
                }
            default:
                break
            }
            idx += 1
        }
    }
}

/// Native macOS PTY session powered by Darwin `openpty` + `DispatchSourceRead` for zero-latency I/O.
@MainActor
public final class NativePTYSession: ObservableObject {
    @Published public private(set) var screenBuffer = TerminalScreenBuffer()
    @Published public private(set) var isRunning: Bool = false

    private var masterFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var shellProcess: Process?
    public var workingDirectory: URL

    public init(workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) {
        self.workingDirectory = workingDirectory
    }

    public func startIfNeeded() {
        guard !isRunning else { return }
        startShell(in: workingDirectory)
    }

    public func startShell(in directory: URL) {
        stop()
        self.workingDirectory = directory

        var master: Int32 = -1
        var slave: Int32 = -1
        var win = winsize(
            ws_row: UInt16(screenBuffer.rows),
            ws_col: UInt16(screenBuffer.cols),
            ws_xpixel: 0,
            ws_ypixel: 0
        )

        guard openpty(&master, &slave, nil, nil, &win) == 0 else {
            screenBuffer.feed("\r\n\u{1B}[31m[og terminal] Failed to allocate PTY.\u{1B}[0m\r\n")
            return
        }

        let flags = fcntl(master, F_GETFL)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)

        let proc = Process()
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        proc.executableURL = URL(fileURLWithPath: shellPath)
        proc.arguments = ["-l"]
        proc.currentDirectoryURL = directory

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        proc.environment = env

        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        proc.standardInput = slaveHandle
        proc.standardOutput = slaveHandle
        proc.standardError = slaveHandle

        do {
            try proc.run()
        } catch {
            close(master)
            screenBuffer.feed("\r\n\u{1B}[31m[og terminal] Failed to launch shell: \(error.localizedDescription)\u{1B}[0m\r\n")
            return
        }

        self.masterFD = master
        self.shellProcess = proc
        self.isRunning = true

        let source = Self.makePTYReadSource(master: master) { [weak self] text in
            Task { @MainActor [weak self] in
                self?.screenBuffer.feed(text)
            }
        }
        self.readSource = source
        source.resume()
    }

    nonisolated private static func makePTYReadSource(
        master: Int32,
        onText: @escaping @Sendable (String) -> Void
    ) -> DispatchSourceRead {
        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: .global(qos: .userInteractive))
        source.setEventHandler {
            var buf = [UInt8](repeating: 0, count: 16384)
            let n = read(master, &buf, buf.count)
            guard n > 0 else { return }
            let text = String(decoding: buf[0..<n], as: UTF8.self)
            onText(text)
        }
        source.setCancelHandler {
            close(master)
        }
        return source
    }

    public func sendInput(_ text: String) {
        guard masterFD >= 0 else { return }
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return 0 }
            return write(masterFD, base, ptr.count)
        }
    }

    public func executeCommand(_ command: String) {
        startIfNeeded()
        sendInput(command + "\r")
    }

    public func resize(cols: Int, rows: Int) {
        screenBuffer.resize(cols: cols, rows: rows)
        guard masterFD >= 0 else { return }
        var win = winsize(
            ws_row: UInt16(max(4, rows)),
            ws_col: UInt16(max(20, cols)),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        _ = ioctl(masterFD, TIOCSWINSZ, &win)
    }

    public func clear() {
        screenBuffer.clearScreen()
        sendInput("\u{0C}")
    }

    public func stop() {
        readSource?.cancel()
        readSource = nil
        masterFD = -1
        if let proc = shellProcess, proc.isRunning {
            proc.terminate()
        }
        shellProcess = nil
        isRunning = false
    }
}

/// 120fps CoreText GPU-accelerated terminal canvas view.
@MainActor
public final class NativeTerminalView: NSView {
    public var session: NativePTYSession {
        didSet { needsDisplay = true }
    }

    public var terminalFont: NSFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular) {
        didSet {
            boldFont = NSFont.monospacedSystemFont(ofSize: terminalFont.pointSize, weight: .bold)
            computeMetrics()
        }
    }
    private var boldFont: NSFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .bold)
    private(set) var lineHeight: CGFloat = 18.0
    private(set) var charAdvance: CGFloat = 7.6
    private(set) var fontAscent: CGFloat = 13.0
    private let paddingX: CGFloat = 12.0
    private let paddingY: CGFloat = 8.0

    public init(session: NativePTYSession, frame frameRect: NSRect = .zero) {
        self.session = session
        super.init(frame: frameRect)
        self.wantsLayer = true
        computeMetrics()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public var isFlipped: Bool { true }
    override public var acceptsFirstResponder: Bool { true }

    private func computeMetrics() {
        let ctFont = terminalFont as CTFont
        let ascent = CTFontGetAscent(ctFont)
        let descent = CTFontGetDescent(ctFont)
        let leading = CTFontGetLeading(ctFont)
        self.fontAscent = ceil(ascent)
        self.lineHeight = ceil(ascent + descent + leading + 3.0)

        let sample = NSAttributedString(string: "M", attributes: [.font: terminalFont])
        let ctLine = CTLineCreateWithAttributedString(sample)
        self.charAdvance = max(6.5, CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil)))
        needsDisplay = true
    }

    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard newSize.width > 40 && newSize.height > 30 else { return }
        let cols = max(20, Int((newSize.width - paddingX * 2) / charAdvance))
        let rows = max(4, Int((newSize.height - paddingY * 2) / lineHeight))
        session.resize(cols: cols, rows: rows)
    }

    override public func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let bg = NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.09, alpha: 1.0)
        ctx.setFillColor(bg.cgColor)
        ctx.fill(dirtyRect)

        let screen = session.screenBuffer
        let grid = screen.grid

        for row in 0..<grid.count {
            let rowY = paddingY + CGFloat(row) * lineHeight
            if rowY + lineHeight < dirtyRect.minY || rowY > dirtyRect.maxY {
                continue
            }

            let rowCells = grid[row]
            let lineAttr = NSMutableAttributedString()

            for (col, cell) in rowCells.enumerated() {
                if cell.background != .defaultBackground {
                    let cellX = paddingX + CGFloat(col) * charAdvance
                    ctx.setFillColor(cell.background.nsColor(isBackground: true).cgColor)
                    ctx.fill(CGRect(x: cellX, y: rowY, width: ceil(charAdvance), height: lineHeight))
                }

                let fgColor = cell.isDim
                    ? cell.foreground.nsColor(isBackground: false).withAlphaComponent(0.55)
                    : cell.foreground.nsColor(isBackground: false)
                let font = cell.isBold ? boldFont : terminalFont
                lineAttr.append(
                    NSAttributedString(
                        string: String(cell.scalar),
                        attributes: [
                            .font: font,
                            .foregroundColor: fgColor
                        ]
                    )
                )
            }

            ctx.saveGState()
            ctx.textMatrix = CGAffineTransform(scaleX: 1.0, y: -1.0)
            ctx.textPosition = CGPoint(x: paddingX, y: rowY + fontAscent)
            let ctLine = CTLineCreateWithAttributedString(lineAttr)
            CTLineDraw(ctLine, ctx)
            ctx.restoreGState()
        }

        let cursorX = paddingX + CGFloat(screen.cursorCol) * charAdvance
        let cursorY = paddingY + CGFloat(screen.cursorRow) * lineHeight
        ctx.setFillColor(NSColor(calibratedRed: 0.00, green: 0.78, blue: 0.90, alpha: 0.75).cgColor)
        ctx.fill(CGRect(x: cursorX, y: cursorY + 2, width: max(2.0, charAdvance), height: lineHeight - 3))
    }

    override public func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override public func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags.contains(.command) {
            if let ch = event.charactersIgnoringModifiers?.lowercased() {
                switch ch {
                case "v":
                    if let pasted = NSPasteboard.general.string(forType: .string) {
                        session.sendInput(pasted)
                    }
                    return
                case "k":
                    session.clear()
                    return
                default:
                    break
                }
            }
        }

        if flags.contains(.control), let ch = event.charactersIgnoringModifiers?.lowercased().first {
            if ch >= "a" && ch <= "z", let ascii = ch.asciiValue {
                let ctrlByte = ascii - 96
                session.sendInput(String(UnicodeScalar(ctrlByte)))
                return
            }
        }

        switch event.keyCode {
        case 36, 76:
            session.sendInput("\r")
        case 51:
            session.sendInput("\u{7F}")
        case 48:
            session.sendInput("\t")
        case 53:
            session.sendInput("\u{1B}")
        case 126:
            session.sendInput("\u{1B}[A")
        case 125:
            session.sendInput("\u{1B}[B")
        case 124:
            session.sendInput("\u{1B}[C")
        case 123:
            session.sendInput("\u{1B}[D")
        default:
            if let chars = event.characters, !chars.isEmpty {
                session.sendInput(chars)
            }
        }
    }
}

public struct NativeTerminalRepresentable: NSViewRepresentable {
    @ObservedObject public var session: NativePTYSession
    public let bufferVersion: UInt64

    public init(session: NativePTYSession) {
        self.session = session
        self.bufferVersion = session.screenBuffer.version
    }

    public func makeNSView(context: Context) -> NativeTerminalView {
        let view = NativeTerminalView(session: session)
        session.startIfNeeded()
        return view
    }

    public func updateNSView(_ nsView: NativeTerminalView, context: Context) {
        nsView.session = session
        nsView.needsDisplay = true
    }
}
