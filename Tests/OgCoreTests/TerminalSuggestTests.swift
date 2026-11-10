import Testing
@testable import OgCore

@Suite struct TerminalSuggestTests {
    @Test func tracksTypedLine() {
        var t = TerminalLineTracker()
        #expect(t.feed(Array("go modx".utf8)) == nil)
        _ = t.feed([0x7f])
        #expect(t.line == "go mod")
        #expect(t.feed([0x0d]) == "go mod")
        #expect(t.line == "")
    }

    @Test func unknownAfterHistoryKeysUntilReturn() {
        var t = TerminalLineTracker()
        _ = t.feed([0x1b, 0x5b, 0x41])  // up: the shell replaced the line
        #expect(t.line == nil)
        #expect(t.feed(Array("x\r".utf8)) == nil)
        #expect(t.line == "")
        _ = t.feed(Array("ab".utf8) + [0x15])  // ^U clears
        #expect(t.line == "")
    }

    @Test func tabAndNonASCIIMakeLineUnknown() {
        var t = TerminalLineTracker()
        _ = t.feed(Array("go\t".utf8))
        #expect(t.line == nil)
        t.reset()
        _ = t.feed(Array("echo あ".utf8))
        #expect(t.line == nil)
    }

    @Test func historyBeatsCommonCommands() {
        #expect(TerminalSuggestions.completion(for: "go m", history: []) == "od tidy")
        #expect(TerminalSuggestions.completion(for: "go r", history: ["go run ./cmd/server"]) == "un ./cmd/server")
        #expect(TerminalSuggestions.completion(for: "go run .", history: []) == nil)
        #expect(TerminalSuggestions.completion(for: "", history: ["ls"]) == nil)
        #expect(TerminalSuggestions.completion(for: "   ", history: []) == nil)
    }

    @Test func rememberDeduplicatesMostRecentFirst() {
        let h = TerminalSuggestions.remember("go test ./...", in: ["go run .", "go test ./..."])
        #expect(h == ["go test ./...", "go run ."])
        #expect(TerminalSuggestions.remember("  ", in: h) == h)
    }
}
