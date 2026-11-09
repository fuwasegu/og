import Testing
@testable import OgCore

@Suite struct CompletionClientTests {
    @Test(arguments: [
        "http://127.0.0.1:8080", "https://localhost", "http://[::1]:8080", "http://LOCALHOST:1", "http://localhost/base",
    ])
    func acceptsLoopback(_ s: String) throws {
        let u = try #require(url(s))
        #expect(LocalCompletionClient.isLoopback(u))
        #expect(LocalCompletionClient(endpoint: u) != nil)
    }

    @Test(arguments: [
        "http://127.0.0.1.evil.com", "http://example.com:8080", "ftp://127.0.0.1", "http://user:pw@127.0.0.1",
        "http://10.0.0.1", "http://0.0.0.0:8080", "file:///tmp/x", "http://localhost.example.com",
    ])
    func rejectsNonLoopback(_ s: String) throws {
        let u = try #require(url(s))
        #expect(!LocalCompletionClient.isLoopback(u))
        #expect(LocalCompletionClient(endpoint: u) == nil)
    }

    @Test func requestIsLlamaInfill() throws {
        let endpoint = try #require(url("http://127.0.0.1:8080"))
        let client = try #require(LocalCompletionClient(endpoint: endpoint))
        let body = requestJSON(client, prefix: "func f() {\n\t", suffix: "\n}", maxTokens: 48)
        #expect(body["_path"] == "/infill")
        #expect(body["_method"] == "POST")
        #expect(body["input_prefix"] == "func f() {\n\t")
        #expect(body["input_suffix"] == "\n}")
        #expect(body["n_predict"] == "48")
        #expect(body["stream"] == "1")
        #expect((Double(body["temperature"] ?? "1") ?? 1) <= 0.2)
    }

    @Test func parsesSSELines() {
        #expect(SSEParser.parse(line: #"data: {"content":"x","stop":false}"#) == .content("x", stop: false))
        #expect(SSEParser.parse(line: #"data:{"content":"y"}"#) == .content("y", stop: false))
        #expect(SSEParser.parse(line: #"data: {"content":"","stop":true}"#) == .content("", stop: true))
        #expect(SSEParser.parse(line: "data: [DONE]") == .done)
        #expect(SSEParser.parse(line: #"data: {"error":{"message":"boom"}}"#) == .error("boom"))
        #expect(SSEParser.parse(line: ": keep-alive") == nil)
        #expect(SSEParser.parse(line: "") == nil)
        #expect(SSEParser.parse(line: "event: message") == nil)
        #expect(SSEParser.parse(line: "data: not json") == nil)
        #expect(SSEParser.parse(line: #"data: {"content":"z"}"# + "\r") == .content("z", stop: false))
    }

    @Test func streamStopsAtBlankLine() {
        let transcript = [
            sseLine("if err"), "", sseLine(" != nil {\n"), "", sseLine("\t\treturn err\n"), sseLine("\t}\n"),
            sseLine("\n"), sseLine("func next() {}\n"), sseLine("", stop: true),
        ].joined(separator: "\n")
        let r = runCannedSSE(transcript)
        #expect(r.error == nil)
        #expect(r.text == "if err != nil {\n\t\treturn err\n\t}")
    }

    @Test func streamStopsAtServerStop() {
        let r = runCannedSSE([sseLine("a"), sseLine("b", stop: true), sseLine("never")].joined(separator: "\n"))
        #expect(r.text == "ab")
    }

    @Test func streamReportsServerError() {
        let r = runCannedSSE([sseLine("a"), #"data: {"error":{"message":"model not loaded"}}"#].joined(separator: "\n"))
        #expect(r.error == "model not loaded")
    }

    @Test func limiterCapsLines() {
        var lim = CompletionStreamLimiter()
        var text = ""
        for i in 0..<20 {
            let (emit, finished) = lim.feed("l\(i)\n")
            text += emit
            if finished { break }
        }
        #expect(text == "l0\nl1\nl2\nl3\nl4\nl5\nl6\nl7")
        #expect(lim.finished)
    }

    @Test func limiterHoldsTrailingNewlineAndIndent() {
        var lim = CompletionStreamLimiter()
        #expect(lim.feed("foo\n\t").0 == "foo")
        #expect(lim.feed("bar").0 == "\n\tbar")
        let (emit, finished) = lim.feed("\n  \nbaz")
        #expect(emit == "")
        #expect(finished)
    }

    @Test func limiterKeepsLeadingNewline() {
        var lim = CompletionStreamLimiter()
        #expect(lim.feed("\n\treturn x").0 == "\n\treturn x")
    }

    @Test func serverDownThrows() async throws {
        // Port 1 on loopback is never a llama-server: the stream must throw, not hang or yield.
        let endpoint = try #require(url("http://127.0.0.1:1"))
        let client = try #require(LocalCompletionClient(endpoint: endpoint))
        var chunks = 0
        await #expect(throws: (any Error).self) {
            for try await _ in client.complete(prefix: "a", suffix: "b") { chunks += 1 }
        }
        #expect(chunks == 0)
    }
}
