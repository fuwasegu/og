import Foundation
import AppKit
#if canImport(SwiftTreeSitter) && canImport(TreeSitterGo)
import SwiftTreeSitter
import TreeSitterGo
#endif

public enum GoSyntaxCategory: String, Sendable, CaseIterable {
    case keyword
    case builtinType
    case typeName
    case functionName
    case stringLiteral
    case numberLiteral
    case comment
    case errorCheck
    case operatorToken
    case identifier
}

public struct HighlightSpan: Sendable, Equatable {
    public let range: Range<Int>
    public let category: GoSyntaxCategory

    public init(range: Range<Int>, category: GoSyntaxCategory) {
        self.range = range
        self.category = category
    }
}

public struct GoASTAnalysis: Sendable {
    public struct FuncEntry: Sendable, Equatable {
        public let name: String
        public let receiverType: String?
        public let signature: String
        public let startLine: Int
        public let endLine: Int
        public let isTest: Bool
        public let isBenchmark: Bool
        public let isMain: Bool

        public init(
            name: String,
            receiverType: String?,
            signature: String,
            startLine: Int,
            endLine: Int,
            isTest: Bool,
            isBenchmark: Bool,
            isMain: Bool = false
        ) {
            self.name = name
            self.receiverType = receiverType
            self.signature = signature
            self.startLine = startLine
            self.endLine = endLine
            self.isTest = isTest
            self.isBenchmark = isBenchmark
            self.isMain = isMain
        }
    }

    public struct TypeEntry: Sendable, Equatable {
        public let name: String
        public let kind: String
        public let startLine: Int
        public let endLine: Int
        public let methods: [String]
    }

    public let packageName: String
    public let importsBlock: String
    public let functions: [FuncEntry]
    public let types: [TypeEntry]
    public let errorHandlingBlocks: [ClosedRange<Int>]
    public let implicitInterfaceImpls: [Int: [String]]
    public let interfaceImplementors: [Int: [String]]

    public init(
        packageName: String,
        importsBlock: String,
        functions: [FuncEntry],
        types: [TypeEntry],
        errorHandlingBlocks: [ClosedRange<Int>],
        implicitInterfaceImpls: [Int: [String]],
        interfaceImplementors: [Int: [String]] = [:]
    ) {
        self.packageName = packageName
        self.importsBlock = importsBlock
        self.functions = functions
        self.types = types
        self.errorHandlingBlocks = errorHandlingBlocks
        self.implicitInterfaceImpls = implicitInterfaceImpls
        self.interfaceImplementors = interfaceImplementors
    }
}

public struct GoTheme: Sendable {
    public let background = NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.13, alpha: 1.0)
    public let currentLineHighlight = NSColor(calibratedRed: 0.14, green: 0.16, blue: 0.21, alpha: 1.0)
    public let selectionBackground = NSColor(calibratedRed: 0.20, green: 0.33, blue: 0.52, alpha: 0.65)
    public let gutterBackground = NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.11, alpha: 1.0)
    public let gutterText = NSColor(calibratedWhite: 0.45, alpha: 1.0)
    public let caretColor = NSColor(calibratedRed: 0.00, green: 0.68, blue: 0.85, alpha: 1.0)
    public let ghostTextColor = NSColor(calibratedWhite: 0.50, alpha: 0.75)
    public let defaultText = NSColor(calibratedWhite: 0.90, alpha: 1.0)

    public init() {}

    public func color(for category: GoSyntaxCategory, dimErrorBoilerplate: Bool = true) -> NSColor {
        switch category {
        case .keyword:
            return NSColor(calibratedRed: 0.98, green: 0.45, blue: 0.52, alpha: 1.0)
        case .builtinType:
            return NSColor(calibratedRed: 0.00, green: 0.78, blue: 0.90, alpha: 1.0)
        case .typeName:
            return NSColor(calibratedRed: 0.52, green: 0.86, blue: 0.68, alpha: 1.0)
        case .functionName:
            return NSColor(calibratedRed: 0.82, green: 0.68, blue: 0.98, alpha: 1.0)
        case .stringLiteral:
            return NSColor(calibratedRed: 0.95, green: 0.78, blue: 0.45, alpha: 1.0)
        case .numberLiteral:
            return NSColor(calibratedRed: 0.85, green: 0.60, blue: 0.42, alpha: 1.0)
        case .comment:
            return NSColor(calibratedRed: 0.46, green: 0.52, blue: 0.60, alpha: 1.0)
        case .errorCheck:
            return dimErrorBoilerplate
                ? NSColor(calibratedWhite: 0.52, alpha: 0.65)
                : defaultText
        case .operatorToken:
            return NSColor(calibratedRed: 0.56, green: 0.78, blue: 0.95, alpha: 1.0)
        case .identifier:
            return defaultText
        }
    }
}

public final class SyntaxHighlighter: @unchecked Sendable {
    public let theme = GoTheme()
    public var dimErrorBoilerplate: Bool = true

    #if canImport(SwiftTreeSitter) && canImport(TreeSitterGo)
    private var parser: Parser?
    private var currentTree: MutableTree?
    #endif

    private static let goKeywords: Set<String> = [
        "break", "case", "chan", "const", "continue", "default", "defer", "else",
        "fallthrough", "for", "func", "go", "goto", "if", "import", "interface",
        "map", "package", "range", "return", "select", "struct", "switch", "type", "var"
    ]

    private static let goBuiltins: Set<String> = [
        "bool", "byte", "complex64", "complex128", "error", "float32", "float64",
        "int", "int8", "int16", "int32", "int64", "rune", "string",
        "uint", "uint8", "uint16", "uint32", "uint64", "uintptr",
        "any", "comparable", "true", "false", "nil", "iota",
        "append", "cap", "clear", "close", "complex", "copy", "delete", "imag",
        "len", "make", "max", "min", "new", "panic", "print", "println", "real", "recover"
    ]

    public init() {
        #if canImport(SwiftTreeSitter) && canImport(TreeSitterGo)
        let p = Parser()
        let language = Language(language: tree_sitter_go())
        try? p.setLanguage(language)
        self.parser = p
        #endif
    }

    private var cachedBufferID: ObjectIdentifier?
    private var cachedBufferVersion: Int = -1
    private var cachedDimSetting: Bool = true
    private var cachedFontSize: CGFloat = 0
    private var cachedAttributedText: NSAttributedString?

    public func computeHighlights(
        in buffer: TextBuffer,
        semanticOverlays: [HighlightSpan] = []
    ) -> [HighlightSpan] {
        let source = buffer.string
        #if canImport(SwiftTreeSitter) && canImport(TreeSitterGo)
        if let parser = parser {
            self.currentTree = parser.parse(source)
        }
        #endif

        var spans = scanGoTokens(in: source)
        if !semanticOverlays.isEmpty {
            spans.append(contentsOf: semanticOverlays)
        }
        return spans
    }

    public func attributedString(
        for buffer: TextBuffer,
        font: NSFont,
        semanticOverlays: [HighlightSpan] = []
    ) -> NSAttributedString {
        let bufID = ObjectIdentifier(buffer)
        if semanticOverlays.isEmpty,
           let cached = cachedAttributedText,
           cachedBufferID == bufID,
           cachedBufferVersion == buffer.version,
           cachedDimSetting == dimErrorBoilerplate,
           cachedFontSize == font.pointSize {
            return cached
        }

        let text = buffer.string
        let attr = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: theme.defaultText
            ]
        )

        let spans = computeHighlights(in: buffer, semanticOverlays: semanticOverlays)
        let totalLength = text.count

        for span in spans {
            let lower = max(0, min(span.range.lowerBound, totalLength))
            let upper = max(lower, min(span.range.upperBound, totalLength))
            guard lower < upper else { continue }
            let utf16Start = buffer.utf16Offset(forCharacterOffset: lower)
            let utf16End = buffer.utf16Offset(forCharacterOffset: upper)
            let nsRange = NSRange(location: utf16Start, length: max(0, utf16End - utf16Start))
            let color = theme.color(for: span.category, dimErrorBoilerplate: dimErrorBoilerplate)
            attr.addAttribute(.foregroundColor, value: color, range: nsRange)
        }

        if semanticOverlays.isEmpty {
            cachedBufferID = bufID
            cachedBufferVersion = buffer.version
            cachedDimSetting = dimErrorBoilerplate
            cachedFontSize = font.pointSize
            cachedAttributedText = attr
        }

        return attr
    }

    public func analyzeGoAST(in buffer: TextBuffer) -> GoASTAnalysis {
        let lines = (0..<buffer.lineCount).map { buffer.lineContent(at: $0) }

        var packageName = "main"
        var importLines: [String] = []
        var inImportBlock = false

        var functions: [GoASTAnalysis.FuncEntry] = []
        var types: [GoASTAnalysis.TypeEntry] = []
        var errorBlocks: [ClosedRange<Int>] = []
        var structMethods: [String: Set<String>] = [:]
        var interfaceRequirements: [String: Set<String>] = [:]

        var lineIdx = 0
        while lineIdx < lines.count {
            let rawLine = lines[lineIdx]
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("package ") {
                packageName = trimmed.replacingOccurrences(of: "package ", with: "").trimmingCharacters(in: .whitespaces)
            }

            if trimmed.hasPrefix("import (") {
                inImportBlock = true
                importLines.append(rawLine)
            } else if inImportBlock {
                importLines.append(rawLine)
                if trimmed == ")" {
                    inImportBlock = false
                }
            } else if trimmed.hasPrefix("import ") {
                importLines.append(rawLine)
            }

            if trimmed.hasPrefix("if err != nil") || trimmed.contains("; err != nil") {
                let endLine = findMatchingBraceLine(in: lines, startingAt: lineIdx)
                errorBlocks.append(lineIdx...endLine)
            }

            if trimmed.hasPrefix("func ") {
                let endLine = findMatchingBraceLine(in: lines, startingAt: lineIdx)
                if let parsedFunc = parseFuncDeclaration(line: trimmed, startLine: lineIdx, endLine: endLine) {
                    functions.append(parsedFunc)
                    if let recv = parsedFunc.receiverType {
                        structMethods[recv, default: []].insert(parsedFunc.name)
                    }
                }
            }

            if trimmed.hasPrefix("type ") && (trimmed.contains(" struct") || trimmed.contains(" interface")) {
                let endLine = findMatchingBraceLine(in: lines, startingAt: lineIdx)
                let parts = trimmed.split(separator: " ")
                if parts.count >= 3 {
                    let typeName = String(parts[1])
                    let kind = trimmed.contains(" interface") ? "interface" : "struct"
                    var methods: [String] = []
                    if kind == "interface" && endLine > lineIdx {
                        for mLine in (lineIdx + 1)..<endLine {
                            let mTrim = lines[mLine].trimmingCharacters(in: .whitespaces)
                            if !mTrim.isEmpty && !mTrim.hasPrefix("//") {
                                if let parenIdx = mTrim.firstIndex(of: "(") {
                                    let mName = String(mTrim[..<parenIdx]).trimmingCharacters(in: .whitespaces)
                                    if !mName.isEmpty {
                                        methods.append(mName)
                                    }
                                }
                            }
                        }
                        interfaceRequirements[typeName] = Set(methods)
                    }
                    types.append(
                        GoASTAnalysis.TypeEntry(
                            name: typeName,
                            kind: kind,
                            startLine: lineIdx,
                            endLine: endLine,
                            methods: methods
                        )
                    )
                }
            }

            lineIdx += 1
        }

        var implicitImpls: [Int: [String]] = [:]
        var ifaceImplsByName: [String: [String]] = [:]
        for typeEntry in types where typeEntry.kind == "struct" {
            let implemented = structMethods[typeEntry.name] ?? []
            var satisfied: [String] = []
            for (ifaceName, reqMethods) in interfaceRequirements where !reqMethods.isEmpty {
                if reqMethods.isSubset(of: implemented) {
                    satisfied.append(ifaceName)
                    ifaceImplsByName[ifaceName, default: []].append(typeEntry.name)
                }
            }
            if !satisfied.isEmpty {
                implicitImpls[typeEntry.startLine] = satisfied.sorted()
            }
        }

        var interfaceImplementors: [Int: [String]] = [:]
        for typeEntry in types where typeEntry.kind == "interface" {
            if let structs = ifaceImplsByName[typeEntry.name], !structs.isEmpty {
                interfaceImplementors[typeEntry.startLine] = structs.sorted()
            }
        }

        return GoASTAnalysis(
            packageName: packageName,
            importsBlock: importLines.joined(separator: "\n"),
            functions: functions,
            types: types,
            errorHandlingBlocks: errorBlocks,
            implicitInterfaceImpls: implicitImpls,
            interfaceImplementors: interfaceImplementors
        )
    }

    private func findMatchingBraceLine(in lines: [String], startingAt startLine: Int) -> Int {
        var depth = 0
        var foundOpen = false
        for idx in startLine..<lines.count {
            for ch in lines[idx] {
                if ch == "{" {
                    depth += 1
                    foundOpen = true
                } else if ch == "}" {
                    depth -= 1
                    if foundOpen && depth <= 0 {
                        return idx
                    }
                }
            }
        }
        return startLine
    }

    private func parseFuncDeclaration(line: String, startLine: Int, endLine: Int) -> GoASTAnalysis.FuncEntry? {
        var rest = String(line.dropFirst("func ".count)).trimmingCharacters(in: .whitespaces)
        var receiverType: String?

        if rest.hasPrefix("(") {
            guard let closeParen = rest.firstIndex(of: ")") else { return nil }
            let recvInside = String(rest[rest.index(after: rest.startIndex)..<closeParen])
            let recvParts = recvInside.split(separator: " ")
            if let lastPart = recvParts.last {
                receiverType = lastPart.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces)
            }
            rest = String(rest[rest.index(after: closeParen)...]).trimmingCharacters(in: .whitespaces)
        }

        guard let openParen = rest.firstIndex(of: "(") else { return nil }
        let funcName = String(rest[..<openParen]).trimmingCharacters(in: .whitespaces)
        let signature = line.replacingOccurrences(of: "{", with: "").trimmingCharacters(in: .whitespaces)
        let isTest = receiverType == nil && funcName.hasPrefix("Test") && line.contains("*testing.T")
        let isBenchmark = receiverType == nil && funcName.hasPrefix("Benchmark") && line.contains("*testing.B")
        let isMain = receiverType == nil && funcName == "main"

        return GoASTAnalysis.FuncEntry(
            name: funcName,
            receiverType: receiverType,
            signature: signature,
            startLine: startLine,
            endLine: endLine,
            isTest: isTest,
            isBenchmark: isBenchmark,
            isMain: isMain
        )
    }

    private func scanGoTokens(in source: String) -> [HighlightSpan] {
        var spans: [HighlightSpan] = []
        let chars = Array(source)
        let n = chars.count
        var i = 0

        let lines = source.components(separatedBy: "\n")
        var lineStartOffsets: [Int] = []
        var running = 0
        for l in lines {
            lineStartOffsets.append(running)
            running += l.count + 1
        }

        while i < n {
            let c = chars[i]
            if c == "/" && i + 1 < n && chars[i + 1] == "/" {
                let start = i
                while i < n && chars[i] != "\n" { i += 1 }
                spans.append(HighlightSpan(range: start..<i, category: .comment))
                continue
            }
            if c == "/" && i + 1 < n && chars[i + 1] == "*" {
                let start = i
                i += 2
                while i + 1 < n && !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i = min(n, i + 2)
                spans.append(HighlightSpan(range: start..<i, category: .comment))
                continue
            }
            if c == "\"" {
                let start = i
                i += 1
                while i < n && chars[i] != "\"" {
                    if chars[i] == "\\" { i += 1 }
                    i += 1
                }
                i = min(n, i + 1)
                spans.append(HighlightSpan(range: start..<i, category: .stringLiteral))
                continue
            }
            if c == "`" {
                let start = i
                i += 1
                while i < n && chars[i] != "`" { i += 1 }
                i = min(n, i + 1)
                spans.append(HighlightSpan(range: start..<i, category: .stringLiteral))
                continue
            }
            if c.isNumber {
                let start = i
                while i < n && (chars[i].isNumber || chars[i] == "." || chars[i] == "x" || chars[i] == "_") {
                    i += 1
                }
                spans.append(HighlightSpan(range: start..<i, category: .numberLiteral))
                continue
            }
            if c.isLetter || c == "_" {
                let start = i
                while i < n && (chars[i].isLetter || chars[i].isNumber || chars[i] == "_") {
                    i += 1
                }
                let word = String(chars[start..<i])
                if Self.goKeywords.contains(word) {
                    spans.append(HighlightSpan(range: start..<i, category: .keyword))
                } else if Self.goBuiltins.contains(word) {
                    spans.append(HighlightSpan(range: start..<i, category: .builtinType))
                } else if i < n && chars[i] == "(" {
                    spans.append(HighlightSpan(range: start..<i, category: .functionName))
                } else if let first = word.first, first.isUppercase {
                    spans.append(HighlightSpan(range: start..<i, category: .typeName))
                }
                continue
            }
            i += 1
        }

        if dimErrorBoilerplate {
            for (idx, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("if err != nil") || trimmed.contains("; err != nil") {
                    let endLine = findMatchingBraceLine(in: lines, startingAt: idx)
                    let startOff = lineStartOffsets[idx]
                    let endOff = min(n, lineStartOffsets[endLine] + lines[endLine].count)
                    if startOff < endOff {
                        spans.append(HighlightSpan(range: startOff..<endOff, category: .errorCheck))
                    }
                }
            }
        }

        return spans
    }
}
