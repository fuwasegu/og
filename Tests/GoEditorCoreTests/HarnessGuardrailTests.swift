import Testing
@testable import GoEditorCore

@Suite("Harness Guardrails & Performance SLAs")
struct HarnessGuardrailTests {
    @Test("Deterministic fuzzing: 300 random multi-byte edits + full Undo/Redo invariant")
    func deterministicFuzzTextBufferInvariants() {
        let initial = """
        package main

        import "fmt"

        // 初期状態コメント 🚀
        func main() {
        \tfmt.Println("hello world")
        }
        """
        let buffer = TextBuffer(initial)
        let snippets = [
            "if err != nil {\n\treturn err\n}\n",
            "// 日本語と絵文字🔥テスト\n",
            "ctx, cancel := context.WithCancel(ctx)\n",
            "type Service struct { ID int }\n",
            "x := 42\n",
            ""
        ]

        var state: UInt64 = 0xCAFE_BABE_1234_5678
        func nextRand(_ bound: Int) -> Int {
            guard bound > 0 else { return 0 }
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Int(state % UInt64(bound))
        }

        for step in 0..<300 {
            let count = buffer.count
            let start = nextRand(count + 1)
            let maxLen = min(24, count - start)
            let deleteLen = nextRand(maxLen + 1)
            let snippet = snippets[step % snippets.count]

            _ = buffer.replace(range: start..<(start + deleteLen), with: snippet)

            let full = buffer.string
            #expect(buffer.count == full.count)
            #expect(buffer.utf8Count == full.utf8.count)
            #expect(buffer.utf16Count == full.utf16.count)
        }

        let finalSnapshot = buffer.string

        while buffer.canUndo {
            _ = buffer.undo()
        }
        #expect(buffer.string == initial)
        #expect(buffer.count == initial.count)

        while buffer.canRedo {
            _ = buffer.redo()
        }
        #expect(buffer.string == finalSnapshot)
    }

    @Test("Performance SLA: 500 localized edits on 2,000-line file under 250ms")
    func performanceSLARopeEdits() {
        let largeSource = (0..<2000)
            .map { "func Handler_\($0)(ctx context.Context) error { if err != nil { return err }; return nil }" }
            .joined(separator: "\n")
        let buffer = TextBuffer(largeSource)

        let elapsedMs = TestWorkspaceHelper.measureMilliseconds {
            for i in 0..<500 {
                let line = (i * 3) % buffer.lineCount
                let offset = buffer.characterOffset(for: TextPosition(line: line, column: 5))
                _ = buffer.insert("Fast", at: offset)
            }
        }

        #expect(elapsedMs < 250.0)
    }

    @Test("Performance SLA: TerminalScreenBuffer processes 300 ANSI lines under 80ms")
    func performanceSLATerminalANSIScreenBuffer() {
        var screen = TerminalScreenBuffer(cols: 120, rows: 24)
        let ansiChunk = "\u{1B}[32m=== RUN\u{1B}[0m   TestServerValidation\r\n\u{1B}[36m--- PASS:\u{1B}[0m TestServerValidation (0.00s)\r\n"

        let elapsedMs = TestWorkspaceHelper.measureMilliseconds {
            for _ in 0..<150 {
                screen.feed(ansiChunk)
            }
        }

        #expect(elapsedMs < 80.0)
        #expect(screen.scrollback.count > 100)
    }
}
