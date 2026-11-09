import Foundation

// MARK: - ANSI SGR

public enum ANSIColor: Sendable, Equatable {
    /// 0-255 (0-7 normal, 8-15 bright, 16-255 the xterm cube/greys).
    case indexed(UInt8)
    case rgb(UInt8, UInt8, UInt8)
}

public struct ANSIStyle: Sendable, Equatable {
    public var foreground: ANSIColor?
    public var background: ANSIColor?
    public var bold = false
    public var dim = false
    public var italic = false
    public var underline = false
    public init() {}
}

/// Splits terminal output into styled runs. SGR (colors, bold, ...) is kept as
/// style; every other escape sequence (cursor movement, OSC titles, ...) and
/// stray control characters are dropped. Escapes split across chunks are handled.
public struct ANSIParser: Sendable {
    public struct Segment: Sendable, Equatable {
        public let text: String
        public let style: ANSIStyle
    }

    private enum State: Sendable { case text, escape, csi, osc, oscEscape, charset }

    public private(set) var style = ANSIStyle()
    private var state = State.text
    private var params = ""

    public init() {}

    public mutating func parse(_ input: String) -> [Segment] {
        var segments: [Segment] = []
        var run = String.UnicodeScalarView()
        func flush(_ style: ANSIStyle) {
            if !run.isEmpty { segments.append(Segment(text: String(run), style: style)); run = .init() }
        }
        for scalar in input.unicodeScalars {
            switch state {
            case .text:
                switch scalar.value {
                case 0x1B:
                    state = .escape
                case 0x0A, 0x09:
                    run.append(scalar)
                case 0x00...0x1F, 0x7F:
                    break // \r, backspace, bell, ...
                case 0x9B:
                    state = .csi; params = ""
                default:
                    run.append(scalar)
                }
            case .escape:
                switch scalar {
                case "[": state = .csi; params = ""
                case "]": state = .osc
                case "(", ")", "*", "+": state = .charset
                default: state = .text // two-byte escape (ESC 7, ESC =, ...)
                }
            case .charset:
                state = .text
            case .csi:
                if (0x40...0x7E).contains(scalar.value) {
                    if scalar == "m" {
                        flush(style)
                        applySGR(params)
                    }
                    state = .text
                } else {
                    params.unicodeScalars.append(scalar)
                }
            case .osc:
                if scalar.value == 0x07 { state = .text } else if scalar.value == 0x1B { state = .oscEscape }
            case .oscEscape:
                state = scalar == "\\" ? .text : .osc
            }
        }
        flush(style)
        return segments
    }

    /// Removes all escape sequences and control characters (stateless convenience).
    public static func strip(_ text: String) -> String {
        var p = ANSIParser()
        return p.parse(text).map(\.text).joined()
    }

    private mutating func applySGR(_ params: String) {
        // Private-mode CSI (`?`/`>`) is not SGR.
        guard !params.hasPrefix("?"), !params.hasPrefix(">") else { return }
        let codes = params.isEmpty ? [0] : params.split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0.split(separator: ":").first ?? "") ?? 0 }
        var i = 0
        while i < codes.count {
            let c = codes[i]
            switch c {
            case 0: style = ANSIStyle()
            case 1: style.bold = true
            case 2: style.dim = true
            case 3: style.italic = true
            case 4: style.underline = true
            case 22: style.bold = false; style.dim = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 30...37: style.foreground = .indexed(UInt8(c - 30))
            case 39: style.foreground = nil
            case 40...47: style.background = .indexed(UInt8(c - 40))
            case 49: style.background = nil
            case 90...97: style.foreground = .indexed(UInt8(c - 90 + 8))
            case 100...107: style.background = .indexed(UInt8(c - 100 + 8))
            case 38, 48:
                var color: ANSIColor?
                if i + 2 < codes.count, codes[i + 1] == 5 {
                    color = .indexed(UInt8(clamping: codes[i + 2])); i += 2
                } else if i + 4 < codes.count, codes[i + 1] == 2 {
                    color = .rgb(UInt8(clamping: codes[i + 2]), UInt8(clamping: codes[i + 3]), UInt8(clamping: codes[i + 4])); i += 4
                }
                if c == 38 { style.foreground = color } else { style.background = color }
            default: break
            }
            i += 1
        }
    }
}

// MARK: - File links

/// A `path/file.go:LINE[:COL]` reference in console text.
public struct ConsoleFileLink: Sendable, Equatable {
    /// UTF-16 range in the scanned text (for NSRange / NSTextStorage).
    public let utf16Range: Range<Int>
    public let path: String
    /// 1-based, as printed by Go tools.
    public let line: Int
    public let column: Int?

    /// Scans `text` for Go source references (`./a.go:3`, `/abs/b_test.go:10:5`, `c.go:7 +0x2c`).
    public static func scan(_ text: String) -> [ConsoleFileLink] {
        let ns = text as NSString
        return patternBox.regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard let line = Int(ns.substring(with: m.range(at: 2))) else { return nil }
            let col = m.range(at: 3).location == NSNotFound ? nil : Int(ns.substring(with: m.range(at: 3)))
            let r = m.range
            return ConsoleFileLink(utf16Range: r.location..<(r.location + r.length),
                                   path: ns.substring(with: m.range(at: 1)), line: line, column: col)
        }
    }

    /// Resolves the path against candidate directories (absolute paths are taken as is).
    public func resolve(in directories: [URL], fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> URL? {
        if path.hasPrefix("/") { return fileExists(path) ? URL(fileURLWithPath: path).standardizedFileURL : nil }
        for dir in directories {
            let url = dir.appendingPathComponent(path).standardizedFileURL
            if fileExists(url.path) { return url }
        }
        return nil
    }

    // Path characters exclude whitespace, quotes, brackets and `:`.
    private static let patternBox: RegexBox = {
        do {
            return RegexBox(try NSRegularExpression(pattern: #"((?:[^\s:"'`()\[\]<>]*/)?[^\s:"'`()\[\]<>/]+\.go):(\d+)(?::(\d+))?"#))
        } catch {
            preconditionFailure("invalid link pattern: \(error)")
        }
    }()
}

/// Older SDKs do not mark NSRegularExpression Sendable; it is immutable.
private final class RegexBox: @unchecked Sendable {
    let regex: NSRegularExpression
    init(_ regex: NSRegularExpression) { self.regex = regex }
}

// MARK: - Locating test functions

public enum GoTestLocator {
    /// Line (0-based) of `func Name(` or a method `) Name(` in `source`, if any.
    public static func functionLine(named name: String, in source: String) -> Int? {
        var lineNo = 0
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("func ") {
                if line.hasPrefix("func \(name)(") || line.hasPrefix("func \(name)[") { return lineNo }
                if line.hasPrefix("func ("), line.contains(") \(name)(") { return lineNo }
            }
            lineNo += 1
        }
        return nil
    }

    /// Line (0-based) of the `t.Run("sub name", ...)` literal for a subtest, searching from `startLine`.
    /// Go rewrites spaces to `_` in subtest names, so both spellings are tried.
    public static func subtestLine(named sub: String, in source: String, from startLine: Int) -> Int? {
        let candidates = Set([sub, sub.replacingOccurrences(of: "_", with: " ")]).map { "\"\($0)\"" }
        var lineNo = 0
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            defer { lineNo += 1 }
            guard lineNo > startLine else { continue }
            if lineNo > startLine && line.hasPrefix("func ") { return nil }
            if candidates.contains(where: { line.contains($0) }) { return lineNo }
        }
        return nil
    }

    /// `module` path from a go.mod file's contents.
    public static func modulePath(fromGoMod text: String) -> String? {
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("module ") || t.hasPrefix("module\t") {
                let rest = t.dropFirst(6).trimmingCharacters(in: .whitespaces)
                let path = rest.split(separator: " ").first.map(String.init) ?? ""
                let unquoted = path.trimmingCharacters(in: CharacterSet(charactersIn: "\"`"))
                return unquoted.isEmpty ? nil : unquoted
            }
        }
        return nil
    }

    /// Directory of an import path inside a module, or nil when it is outside it.
    public static func directory(forImportPath importPath: String, modulePath: String, moduleRoot: URL) -> URL? {
        if importPath == modulePath { return moduleRoot }
        guard importPath.hasPrefix(modulePath + "/") else { return nil }
        return moduleRoot.appendingPathComponent(String(importPath.dropFirst(modulePath.count + 1)), isDirectory: true)
    }

    /// Nearest ancestor (or `dir` itself) containing go.mod, with its module path.
    public static func findModule(from dir: URL) -> (root: URL, path: String)? {
        var cur = dir.standardizedFileURL
        while true {
            let mod = cur.appendingPathComponent("go.mod")
            if let text = try? String(contentsOf: mod, encoding: .utf8), let path = modulePath(fromGoMod: text) {
                return (cur, path)
            }
            let parent = cur.deletingLastPathComponent()
            if parent.path == cur.path { return nil }
            cur = parent
        }
    }

    /// Finds the source location of a test in `packageDir`'s `_test.go` files.
    /// Subtests resolve to their `t.Run("name"` literal when it can be found, else the parent function.
    public static func locate(test: String, in packageDir: URL) -> (url: URL, line: Int)? {
        let parts = test.split(separator: "/").map(String.init)
        guard let top = parts.first else { return nil }
        let files = ((try? FileManager.default.contentsOfDirectory(at: packageDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasSuffix("_test.go") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files {
            guard let src = try? String(contentsOf: file, encoding: .utf8),
                  var line = functionLine(named: top, in: src) else { continue }
            for sub in parts.dropFirst() {
                guard let l = subtestLine(named: sub, in: src, from: line) else { break }
                line = l
            }
            return (file, line)
        }
        return nil
    }
}
