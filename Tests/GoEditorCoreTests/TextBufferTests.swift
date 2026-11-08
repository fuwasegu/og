import Testing
@testable import GoEditorCore

@Suite("GoEditorCore Tests")
struct TextBufferTests {
    @Test("Insert, delete, and undo/redo operations")
    func insertDeleteAndUndoRedo() {
        let initial = "package main\n\nfunc main() {\n}\n"
        let buffer = TextBuffer(initial)

        #expect(buffer.lineCount == 5)
        #expect(buffer.lineContent(at: 0) == "package main")
        #expect(buffer.lineContent(at: 2) == "func main() {")

        let insertPos = TextPosition(line: 3, column: 0)
        let insertOffset = buffer.characterOffset(for: insertPos)
        let afterPos = buffer.insert("\tfmt.Println(\"hello\")\n", at: insertOffset)

        #expect(afterPos == TextPosition(line: 4, column: 0))
        #expect(buffer.lineCount == 6)
        #expect(buffer.lineContent(at: 3) == "\tfmt.Println(\"hello\")")

        #expect(buffer.canUndo)
        _ = buffer.undo()
        #expect(buffer.string == initial)
        #expect(buffer.lineCount == 5)

        #expect(buffer.canRedo)
        _ = buffer.redo()
        #expect(buffer.lineCount == 6)
        #expect(buffer.lineContent(at: 3) == "\tfmt.Println(\"hello\")")
    }

    @Test("UTF-8 and UTF-16 coordinate conversions")
    func utf8AndUTF16CoordinateConversions() {
        let source = "package main\n// 日本語コメント\nfunc Run() {}\n"
        let buffer = TextBuffer(source)

        let pos = TextPosition(line: 2, column: 5)
        let charOffset = buffer.characterOffset(for: pos)
        let roundTripPos = buffer.position(forCharacterOffset: charOffset)
        #expect(roundTripPos == pos)

        let utf16Off = buffer.utf16Offset(for: pos)
        #expect(utf16Off > charOffset - 1)

        let jpPos = TextPosition(line: 1, column: 6)
        let lspCol = buffer.lspUTF16Column(for: jpPos)
        let restored = buffer.position(forLSPPosition: LSPPosition(line: 1, character: lspCol))
        #expect(restored == jpPos)
    }

    @Test("Go AST implicit interface and error block detection")
    func goASTImplicitInterfaceAndErrorBlockDetection() {
        let goCode = """
        package service

        import "net/http"

        type Handler interface {
        \tServeHTTP(w http.ResponseWriter, r *http.Request)
        }

        type MyServer struct{}

        func (s *MyServer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
        \tif err != nil {
        \t\treturn
        \t}
        }

        func TestMyServer(t *testing.T) {}
        """

        let buffer = TextBuffer(goCode)
        let highlighter = SyntaxHighlighter()
        let analysis = highlighter.analyzeGoAST(in: buffer)

        #expect(analysis.packageName == "service")
        #expect(analysis.errorHandlingBlocks.count == 1)
        #expect(analysis.implicitInterfaceImpls[8] == ["Handler"])
        #expect(analysis.functions.filter(\.isTest).map(\.name) == ["TestMyServer"])
    }

    @Test("FIM prompt formatting")
    func fimPromptFormatting() {
        let goCode = """
        package store

        type Store struct {
        \tDSN string
        }

        func (s *Store) Connect() error {
        \t
        }
        """
        let buffer = TextBuffer(goCode)
        let highlighter = SyntaxHighlighter()
        let analysis = highlighter.analyzeGoAST(in: buffer)
        let extractor = GoFIMContextExtractor()

        let ctx = extractor.buildContext(
            from: buffer,
            cursor: TextPosition(line: 7, column: 1),
            filePath: "/workspace/store.go",
            astAnalysis: analysis
        )
        let fimPrompt = GoFIMContextExtractor.formatQwenFIMPrompt(context: ctx)

        #expect(fimPrompt.hasPrefix("<|fim_prefix|>"))
        #expect(fimPrompt.contains("<|fim_suffix|>"))
        #expect(fimPrompt.hasSuffix("<|fim_middle|>"))
    }

    @Test("Large multi-chunk edits and undo/redo")
    func largeMultiChunkEditsAndUndoRedo() {
        let repeatedLines = (0..<250).map { "func Handler\($0)() error { return nil }" }.joined(separator: "\n")
        let buffer = TextBuffer(repeatedLines)
        #expect(buffer.lineCount == 250)

        let midPos = TextPosition(line: 125, column: 5)
        let midOff = buffer.characterOffset(for: midPos)
        _ = buffer.replace(range: midOff..<(midOff + 7), with: "Service")
        #expect(buffer.lineContent(at: 125).hasPrefix("func Service125()"))

        _ = buffer.undo()
        #expect(buffer.lineContent(at: 125) == "func Handler125() error { return nil }")
        #expect(buffer.string == repeatedLines)

        _ = buffer.redo()
        #expect(buffer.lineContent(at: 125).hasPrefix("func Service125()"))
    }

    @Test("Transactional rename preview, commit, and rollback")
    func transactionalRenameAndRollback() async throws {
        let initial = "package main\n\ntype Server struct{}\n"
        try await TestWorkspaceHelper.withTempGoFile(initialContent: initial) { filePath, fileURI in
            let buffer = TextBuffer(initial)
            let edit = LSPWorkspaceEdit(
                changes: [
                    fileURI: [
                        LSPTextEdit(
                            range: LSPRange(
                                start: LSPPosition(line: 2, character: 5),
                                end: LSPPosition(line: 2, character: 11)
                            ),
                            newText: "HTTPServer"
                        )
                    ]
                ]
            )

            let manager = TransactionalRenameManager()
            let previews = try await TestWorkspaceHelper.buildPreview(
                manager: manager,
                edit: edit,
                filePath: filePath,
                buffer: buffer
            )
            #expect(previews.count == 1)
            #expect(previews[0].modifiedContent == "package main\n\ntype HTTPServer struct{}\n")

            _ = try await manager.commitRename(previews: previews, oldName: "Server", newName: "HTTPServer")
            let diskAfterCommit = try TestWorkspaceHelper.readFile(atPath: filePath)
            #expect(diskAfterCommit == "package main\n\ntype HTTPServer struct{}\n")

            let canRollback = await manager.canRollback
            #expect(canRollback)

            _ = try await manager.rollbackLastRename()
            let diskAfterRollback = try TestWorkspaceHelper.readFile(atPath: filePath)
            #expect(diskAfterRollback == initial)
        }
    }

    @Test("Native PTY TerminalScreenBuffer ANSI CSI parsing and SGR colors")
    func nativeTerminalScreenBufferANSIParsing() {
        var screen = TerminalScreenBuffer(cols: 40, rows: 6)
        screen.feed("\u{1B}[32mPASS\u{1B}[0m go test\r\nLine2")

        #expect(screen.grid[0][0].scalar == "P")
        #expect(screen.grid[0][0].foreground == .ansi(2))
        #expect(screen.grid[0][5].scalar == "g")
        #expect(screen.grid[0][5].foreground == .defaultForeground)
        #expect(screen.grid[1][0].scalar == "L")
        #expect(screen.cursorRow == 1)
        #expect(screen.cursorCol == 5)

        screen.feed("\u{1B}[2J")
        #expect(screen.cursorRow == 0)
        #expect(screen.cursorCol == 0)
        #expect(screen.grid[0][0].scalar == " ")
    }
}
