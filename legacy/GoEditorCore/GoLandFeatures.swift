import Foundation

// MARK: - 1. GoLand Postfix Completion Engine (.err, .var, .return, .forr, .for, .nn, .nil, .print, .if, .not, .len)

public struct GoPostfixCandidate: Sendable, Equatable {
    public let key: String
    public let expression: String
    public let previewLabel: String
    public let replacementText: String
    public let replaceRange: TextRange
    public let cursorOffsetInsideReplacement: Int
}

public enum GoPostfixCompletionEngine {
    public static let supportedKeys: Set<String> = [
        "err", "iferr", "nn", "nil", "var", "return", "ret",
        "print", "forr", "for", "seq", "loop", "if", "not", "len"
    ]

    public static func matchCandidate(in buffer: TextBuffer, at cursor: TextPosition) -> GoPostfixCandidate? {
        guard cursor.line >= 0 && cursor.line < buffer.lineCount else { return nil }
        let lineStr = buffer.lineContent(at: cursor.line)
        let lineChars = Array(lineStr)
        guard cursor.column > 0 && cursor.column <= lineChars.count else { return nil }

        let prefixChars = Array(lineChars[0..<cursor.column])
        let leadingWhitespace = String(prefixChars.prefix(while: { $0 == "\t" || $0 == " " }))
        let indentCount = leadingWhitespace.count
        guard cursor.column > indentCount else { return nil }

        // Ensure nothing non-whitespace follows cursor on this line
        if cursor.column < lineChars.count {
            let trailing = String(lineChars[cursor.column..<lineChars.count]).trimmingCharacters(in: .whitespaces)
            if !trailing.isEmpty { return nil }
        }

        let statementSlice = String(prefixChars[indentCount..<cursor.column])
        guard let lastDotIndex = statementSlice.lastIndex(of: ".") else { return nil }

        let key = String(statementSlice[statementSlice.index(after: lastDotIndex)...])
        guard supportedKeys.contains(key) else { return nil }

        let expr = String(statementSlice[..<lastDotIndex]).trimmingCharacters(in: .whitespaces)
        guard !expr.isEmpty else { return nil }

        let replaceRange = TextRange(
            start: TextPosition(line: cursor.line, column: indentCount),
            end: cursor
        )

        return buildExpansion(
            key: key,
            expr: expr,
            indent: leadingWhitespace,
            replaceRange: replaceRange
        )
    }

    @discardableResult
    public static func tryExpand(in buffer: TextBuffer, at cursor: TextPosition) -> TextPosition? {
        guard let candidate = matchCandidate(in: buffer, at: cursor) else { return nil }
        let startCharOffset = buffer.characterOffset(for: candidate.replaceRange.start)
        _ = buffer.replace(textRange: candidate.replaceRange, with: candidate.replacementText)
        let targetOffset = min(buffer.count, startCharOffset + candidate.cursorOffsetInsideReplacement)
        return buffer.position(forCharacterOffset: targetOffset)
    }

    private static func buildExpansion(
        key: String,
        expr: String,
        indent: String,
        replaceRange: TextRange
    ) -> GoPostfixCandidate? {
        let innerIndent = indent + "\t"

        switch key {
        case "err", "iferr":
            if expr == "err" {
                let firstLine = "if err != nil {\n\(innerIndent)return err"
                let full = "\(firstLine)\n\(indent)}"
                return GoPostfixCandidate(
                    key: key,
                    expression: expr,
                    previewLabel: "if err != nil { return err }",
                    replacementText: full,
                    replaceRange: replaceRange,
                    cursorOffsetInsideReplacement: firstLine.count
                )
            } else {
                let firstLine = "if err := \(expr); err != nil {\n\(innerIndent)return err"
                let full = "\(firstLine)\n\(indent)}"
                return GoPostfixCandidate(
                    key: key,
                    expression: expr,
                    previewLabel: "if err := \(expr); err != nil { return err }",
                    replacementText: full,
                    replaceRange: replaceRange,
                    cursorOffsetInsideReplacement: firstLine.count
                )
            }

        case "nn":
            let beforeCursor = "if \(expr) != nil {\n\(innerIndent)"
            let full = "\(beforeCursor)\n\(indent)}"
            return GoPostfixCandidate(
                key: key,
                expression: expr,
                previewLabel: "if \(expr) != nil { … }",
                replacementText: full,
                replaceRange: replaceRange,
                cursorOffsetInsideReplacement: beforeCursor.count
            )

        case "nil":
            let beforeCursor = "if \(expr) == nil {\n\(innerIndent)"
            let full = "\(beforeCursor)\n\(indent)}"
            return GoPostfixCandidate(
                key: key,
                expression: expr,
                previewLabel: "if \(expr) == nil { … }",
                replacementText: full,
                replaceRange: replaceRange,
                cursorOffsetInsideReplacement: beforeCursor.count
            )

        case "if":
            if expr == "err" {
                return buildExpansion(key: "err", expr: expr, indent: indent, replaceRange: replaceRange)
            }
            let beforeCursor = "if \(expr) {\n\(innerIndent)"
            let full = "\(beforeCursor)\n\(indent)}"
            return GoPostfixCandidate(
                key: key,
                expression: expr,
                previewLabel: "if \(expr) { … }",
                replacementText: full,
                replaceRange: replaceRange,
                cursorOffsetInsideReplacement: beforeCursor.count
            )

        case "var":
            let varName = inferVariableName(from: expr)
            let full = "\(varName) := \(expr)"
            return GoPostfixCandidate(
                key: key,
                expression: expr,
                previewLabel: "\(varName) := \(expr)",
                replacementText: full,
                replaceRange: replaceRange,
                cursorOffsetInsideReplacement: full.count
            )

        case "return", "ret":
            let full = "return \(expr)"
            return GoPostfixCandidate(
                key: key,
                expression: expr,
                previewLabel: full,
                replacementText: full,
                replaceRange: replaceRange,
                cursorOffsetInsideReplacement: full.count
            )

        case "print":
            let full = "fmt.Printf(\"%+v\\n\", \(expr))"
            return GoPostfixCandidate(
                key: key,
                expression: expr,
                previewLabel: full,
                replacementText: full,
                replaceRange: replaceRange,
                cursorOffsetInsideReplacement: full.count
            )

        case "forr":
            let isIntLiteral = !expr.isEmpty && expr.allSatisfy { $0.isNumber || $0 == "_" }
            let header = isIntLiteral ? "for i := range \(expr)" : "for i, v := range \(expr)"
            let beforeCursor = "\(header) {\n\(innerIndent)"
            let full = "\(beforeCursor)\n\(indent)}"
            return GoPostfixCandidate(
                key: key,
                expression: expr,
                previewLabel: "\(header) { … }",
                replacementText: full,
                replaceRange: replaceRange,
                cursorOffsetInsideReplacement: beforeCursor.count
            )

        case "seq":
            let beforeCursor = "for v := range \(expr) {\n\(innerIndent)"
            let full = "\(beforeCursor)\n\(indent)}"
            return GoPostfixCandidate(
                key: key,
                expression: expr,
                previewLabel: "for v := range \(expr) { … }",
                replacementText: full,
                replaceRange: replaceRange,
                cursorOffsetInsideReplacement: beforeCursor.count
            )

        case "loop":
            let beforeCursor = "for \(expr).Loop() {\n\(innerIndent)"
            let full = "\(beforeCursor)\n\(indent)}"
            return GoPostfixCandidate(
                key: key,
                expression: expr,
                previewLabel: "for \(expr).Loop() { … }",
                replacementText: full,
                replaceRange: replaceRange,
                cursorOffsetInsideReplacement: beforeCursor.count
            )

        case "for":
            let beforeCursor = "for i := 0; i < len(\(expr)); i++ {\n\(innerIndent)"
            let full = "\(beforeCursor)\n\(indent)}"
            return GoPostfixCandidate(
                key: key,
                expression: expr,
                previewLabel: "for i := 0; i < len(\(expr)); i++ { … }",
                replacementText: full,
                replaceRange: replaceRange,
                cursorOffsetInsideReplacement: beforeCursor.count
            )

        case "not":
            let full = "!\(expr)"
            return GoPostfixCandidate(
                key: key,
                expression: expr,
                previewLabel: full,
                replacementText: full,
                replaceRange: replaceRange,
                cursorOffsetInsideReplacement: full.count
            )

        case "len":
            let full = "len(\(expr))"
            return GoPostfixCandidate(
                key: key,
                expression: expr,
                previewLabel: full,
                replacementText: full,
                replaceRange: replaceRange,
                cursorOffsetInsideReplacement: full.count
            )

        default:
            return nil
        }
    }

    private static func inferVariableName(from expr: String) -> String {
        let cleaned = expr
            .replacingOccurrences(of: "&", with: "")
            .replacingOccurrences(of: "*", with: "")
        let head = cleaned.split(separator: "(").first.map(String.init) ?? cleaned
        let lastSegment = head.split(separator: ".").last.map(String.init) ?? head
        let stripped = lastSegment
            .replacingOccurrences(of: "New", with: "")
            .replacingOccurrences(of: "Get", with: "")
            .replacingOccurrences(of: "Build", with: "")
            .replacingOccurrences(of: "Create", with: "")
        let letters = stripped.filter { $0.isLetter || $0.isNumber }
        guard !letters.isEmpty else { return "val" }
        let camel = GoStructTagGenerator.toCamelCase(letters)
        if camel.isEmpty || camel == expr {
            return "val"
        }
        return camel
    }
}

// MARK: - 2. GoLand Struct Tag Generator (`json`, `yaml`, `db` with snake_case / camelCase / omitzero)

public enum GoStructTagStyle: String, Sendable, CaseIterable {
    case jsonSnake = "json (snake_case)"
    case jsonCamel = "json (camelCase)"
    case jsonOmitempty = "json (omitempty)"
    case jsonOmitzero = "json (omitzero — Go 1.24+)"
    case jsonYaml = "json + yaml"
    case dbJson = "db + json"

    public func formatTag(forField fieldName: String) -> String {
        let snake = GoStructTagGenerator.toSnakeCase(fieldName)
        let camel = GoStructTagGenerator.toCamelCase(fieldName)
        switch self {
        case .jsonSnake:
            return "`json:\"\(snake)\"`"
        case .jsonCamel:
            return "`json:\"\(camel)\"`"
        case .jsonOmitempty:
            return "`json:\"\(snake),omitempty\"`"
        case .jsonOmitzero:
            return "`json:\"\(snake),omitzero\"`"
        case .jsonYaml:
            return "`json:\"\(snake)\" yaml:\"\(snake)\"`"
        case .dbJson:
            return "`db:\"\(snake)\" json:\"\(snake)\"`"
        }
    }
}

public enum GoStructTagGenerator {
    public static func enclosingStruct(in analysis: GoASTAnalysis, atLine line: Int) -> GoASTAnalysis.TypeEntry? {
        if let exact = analysis.types.first(where: { $0.kind == "struct" && ($0.startLine...$0.endLine).contains(line) }) {
            return exact
        }
        return analysis.types.first(where: { $0.kind == "struct" })
    }

    @discardableResult
    public static func applyStructTags(
        in buffer: TextBuffer,
        structEntry: GoASTAnalysis.TypeEntry,
        style: GoStructTagStyle = .jsonSnake
    ) -> Int {
        guard structEntry.kind == "struct",
              structEntry.endLine > structEntry.startLine + 1 else {
            return 0
        }

        var updatedCount = 0
        for lineIdx in (structEntry.startLine + 1)..<structEntry.endLine {
            let rawLine = buffer.lineContent(at: lineIdx)
            guard let updatedLine = transformStructFieldLine(rawLine, style: style),
                  updatedLine != rawLine else {
                continue
            }
            let charRange = buffer.lineCharacterRange(at: lineIdx)
            _ = buffer.replace(range: charRange, with: updatedLine)
            updatedCount += 1
        }
        return updatedCount
    }

    public static func transformStructFieldLine(_ rawLine: String, style: GoStructTagStyle) -> String? {
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed == "}" {
            return nil
        }

        // Separate trailing line comment if present
        let codePart: String
        let commentSuffix: String
        if let commentRange = rawLine.range(of: "//") {
            codePart = String(rawLine[..<commentRange.lowerBound])
            commentSuffix = " " + String(rawLine[commentRange.lowerBound...]).trimmingCharacters(in: .whitespaces)
        } else {
            codePart = rawLine
            commentSuffix = ""
        }

        // Remove any existing backtick struct tag
        let withoutExistingTag: String
        if let firstTick = codePart.firstIndex(of: "`"),
           let lastTick = codePart.lastIndex(of: "`"),
           firstTick != lastTick {
            withoutExistingTag = String(codePart[..<firstTick]).replacingOccurrences(
                of: "\\s+$",
                with: "",
                options: .regularExpression
            )
        } else {
            withoutExistingTag = codePart.replacingOccurrences(
                of: "\\s+$",
                with: "",
                options: .regularExpression
            )
        }

        let tokens = withoutExistingTag.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard tokens.count >= 2 else { return nil }

        let fieldName = String(tokens[0])
        guard let firstChar = fieldName.first, firstChar.isLetter || firstChar == "_" else {
            return nil
        }

        let tagLiteral = style.formatTag(forField: fieldName)
        return "\(withoutExistingTag) \(tagLiteral)\(commentSuffix)"
    }

    public static func toSnakeCase(_ input: String) -> String {
        let chars = Array(input)
        guard !chars.isEmpty else { return input }
        var result = ""
        for i in 0..<chars.count {
            let c = chars[i]
            if c.isUppercase {
                if i > 0 {
                    let prev = chars[i - 1]
                    let nextIsLower = (i + 1 < chars.count) && chars[i + 1].isLowercase
                    if prev.isLowercase || prev.isNumber || (prev.isUppercase && nextIsLower) {
                        result.append("_")
                    }
                }
                result.append(contentsOf: c.lowercased())
            } else {
                result.append(c)
            }
        }
        return result
    }

    public static func toCamelCase(_ input: String) -> String {
        let snake = toSnakeCase(input)
        let parts = snake.split(separator: "_")
        guard let first = parts.first else { return input.lowercased() }
        let tail = parts.dropFirst().map { part -> String in
            guard let head = part.first else { return "" }
            return String(head).uppercased() + String(part.dropFirst())
        }
        return String(first) + tail.joined()
    }
}

// MARK: - 3. GoLand Table-Driven Test Generator

public enum GoTableTestGenerator {
    public static func targetFunction(in analysis: GoASTAnalysis, atLine line: Int) -> GoASTAnalysis.FuncEntry? {
        if let enclosing = analysis.functions.first(where: {
            !$0.isTest && !$0.isBenchmark && ($0.startLine...$0.endLine).contains(line)
        }) {
            return enclosing
        }
        return analysis.functions.first(where: { !$0.isTest && !$0.isBenchmark && !$0.isMain })
            ?? analysis.functions.first(where: { !$0.isTest && !$0.isBenchmark })
    }

    public static func testFunctionName(for fn: GoASTAnalysis.FuncEntry) -> String {
        let capName: String
        if let first = fn.name.first {
            capName = String(first).uppercased() + String(fn.name.dropFirst())
        } else {
            capName = fn.name
        }
        if let recv = fn.receiverType, !recv.isEmpty {
            return "Test\(recv)_\(capName)"
        }
        return "Test\(capName)"
    }

    public static func generateTableDrivenTest(for fn: GoASTAnalysis.FuncEntry) -> String {
        let testName = testFunctionName(for: fn)
        let returnsError = fn.signature.contains("error")
        let callTarget = fn.receiverType != nil ? "s.\(fn.name)" : fn.name

        if returnsError {
            return """

            func \(testName)(t *testing.T) {
            \ttests := []struct {
            \t\tname    string
            \t\twantErr bool
            \t}{
            \t\t{
            \t\t\tname:    "valid case",
            \t\t\twantErr: false,
            \t\t},
            \t}
            \tfor _, tt := range tests {
            \t\tt.Run(tt.name, func(t *testing.T) {
            \t\t\t// Arrange & Act: \(callTarget)(...)
            \t\t\tvar err error
            \t\t\tif (err != nil) != tt.wantErr {
            \t\t\t\tt.Fatalf("\(fn.name)() error = %v, wantErr %v", err, tt.wantErr)
            \t\t\t}
            \t\t})
            \t}
            }
            """
        } else {
            return """

            func \(testName)(t *testing.T) {
            \ttests := []struct {
            \t\tname string
            \t}{
            \t\t{
            \t\t\tname: "baseline case",
            \t\t},
            \t}
            \tfor _, tt := range tests {
            \t\tt.Run(tt.name, func(t *testing.T) {
            \t\t\t// Act: \(callTarget)(...)
            \t\t})
            \t}
            }
            """
        }
    }

    public static func appendOrLocateTableTest(
        for fn: GoASTAnalysis.FuncEntry,
        in buffer: TextBuffer,
        analysis: GoASTAnalysis
    ) -> (position: TextPosition, created: Bool, testName: String) {
        let expectedName = testFunctionName(for: fn)
        if let existing = analysis.functions.first(where: { $0.name == expectedName }) {
            return (TextPosition(line: existing.startLine, column: 0), false, expectedName)
        }

        let snippet = generateTableDrivenTest(for: fn)
        let insertOffset = buffer.count
        let prefixNewline = buffer.string.hasSuffix("\n") ? "" : "\n"
        _ = buffer.insert(prefixNewline + snippet + "\n", at: insertOffset)
        let targetLine = max(0, buffer.lineCount - snippet.components(separatedBy: "\n").count)
        return (TextPosition(line: targetLine, column: 0), true, expectedName)
    }
}

// MARK: - 4. GoLand Symbol & Interface Navigation

public enum GoSymbolNavigator {
    public static func findDeclarationLine(forSymbol symbol: String, in analysis: GoASTAnalysis) -> Int? {
        let cleaned = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        if let typeEntry = analysis.types.first(where: { $0.name == cleaned }) {
            return typeEntry.startLine
        }
        if let fnEntry = analysis.functions.first(where: { $0.name == cleaned }) {
            return fnEntry.startLine
        }
        return nil
    }
}
