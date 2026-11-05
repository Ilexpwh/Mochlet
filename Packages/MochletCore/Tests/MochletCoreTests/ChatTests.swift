import Foundation
import Testing
@testable import MochletCore

enum Fixtures {
    static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tests/Fixtures")
    }
    static func text(_ rel: String) throws -> String { try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8) }
    static func lines(_ rel: String) throws -> [String] { try text(rel).components(separatedBy: "\n").filter { !$0.isEmpty } }
}

func collect<P>(_ parser: inout P, lines: [String], step: (inout P, String) -> [ChatEvent]) -> [ChatEvent] {
    var out: [ChatEvent] = []
    for l in lines { out += step(&parser, l) }
    return out
}

func text(of events: [ChatEvent]) -> String {
    events.compactMap { if case .textDelta(let t) = $0 { return t } else { return nil } }.joined()
}

@Suite struct SSEParserTests {
    @Test func splitsEventsAcrossChunks() {
        var p = SSEParser()
        var out = p.feed("event: a\ndata: {\"x\":")
        #expect(out.isEmpty)
        out += p.feed("1}\n\n: comment\ndata: line1\ndata: line2\r\n\r\ndata: tail")
        out += p.finish()
        #expect(out == [SSEEvent(event: "a", data: "{\"x\":1}"), SSEEvent(event: nil, data: "line1\nline2"), SSEEvent(event: nil, data: "tail")])
    }
}

@Suite struct AnthropicStreamTests {
    @Test func fixture() throws {
        var sse = SSEParser()
        var events = sse.feed(try Fixtures.text("cli/anthropic-sse.txt"))
        events += sse.finish()
        var p = AnthropicStreamParser()
        var out: [ChatEvent] = []
        for e in events { out += p.parse(e) }
        #expect(out.first == .started(continuation: "msg_01abc"))
        #expect(text(of: out) == "Hello there")
        #expect(out.contains(.usage(ChatUsage(inputTokens: 25, outputTokens: 12))))
        #expect(out.last == .done)
    }

    @Test func requestBody() throws {
        let m = ChatMessage(threadID: "t", role: .user, text: "hi", attachments: [ChatAttachment(kind: .window, title: "Safari", text: "URL: x")])
        let body = AnthropicRequest.body(ChatRequest(messages: [m], system: "sys", model: "claude-sonnet-5-5"))
        #expect(body["model"].string == "claude-sonnet-5-5")
        #expect(body["system"].string == "sys")
        #expect(body["stream"].bool == true)
        let blocks = body["messages"][0]["content"].array ?? []
        #expect(blocks.count == 2)
        #expect(blocks[0]["text"].string?.contains("<attachment kind=\"window\" title=\"Safari\">") == true)
        #expect(blocks[1]["text"].string == "hi")
    }
}

@Suite struct OpenAIStreamTests {
    @Test func fixtureStripsThinkAndReportsUsage() throws {
        var sse = SSEParser()
        var events = sse.feed(try Fixtures.text("cli/openai-sse.txt"))
        events += sse.finish()
        var p = OpenAIStreamParser()
        var out: [ChatEvent] = []
        for e in events { out += p.parse(e) }
        #expect(out.first == .activity("thinking"))
        #expect(text(of: out) == "Hello!")
        #expect(out.contains(.usage(ChatUsage(inputTokens: 30, outputTokens: 9))))
        #expect(out.filter { $0 == .done }.count == 1)
    }

    @Test func thinkStripperAcrossChunks() {
        var s = ThinkStripper()
        var out = s.feed("a<th")
        out += s.feed("ink>secret</th")
        out += s.feed("ink>b")
        out += s.finish()
        #expect(out == "ab")
        #expect(s.sawThinking)
        var plain = ThinkStripper()
        #expect(plain.feed("1 < 2 and 3 > 2") + plain.finish() == "1 < 2 and 3 > 2")
    }

    @Test func requestBody() {
        let m = ChatMessage(threadID: "t", role: .user, text: "hi", attachments: [ChatAttachment(kind: .text, title: "note", text: "n")])
        let body = OpenAIRequest.body(ChatRequest(messages: [m], system: "sys", model: "deepseek-chat"), kind: .deepseek)
        let msgs = body["messages"].array ?? []
        #expect(msgs.count == 2 && msgs[0]["role"].string == "system")
        #expect(msgs[1]["content"].string?.hasPrefix("<attachment") == true)
        #expect(body["stream_options"]["include_usage"].bool == true)
        let local = OpenAIRequest.body(ChatRequest(messages: [m], model: "llama3"), kind: .ollama)
        #expect(local["stream_options"].isNull && local["max_tokens"].isNull)
    }
}

@Suite struct CLIStreamTests {
    @Test func claudeFixture() throws {
        var p = ClaudeStreamParser()
        let out = collect(&p, lines: try Fixtures.lines("cli/claude-stream.jsonl")) { $0.parse(line: $1) }
        #expect(out.first == .started(continuation: "f1db316f-ebe9-4d42-b95f-8bdd422a7fc7"))
        #expect(text(of: out) == "hi")
        #expect(out.last == .done)
        #expect(p.lastRateLimits?["unifiedWindows"]["five_hour"]["utilization"].number == 0.03)
        if case .usage(let u)? = out.first(where: { if case .usage = $0 { return true } else { return false } }) {
            #expect(u.outputTokens == 4 && u.inputTokens > 30000)
        } else { Issue.record("no usage") }
    }

    @Test func claudeWithoutPartialsAndErrors() {
        var p = ClaudeStreamParser()
        var out = p.parse(line: #"{"type":"system","subtype":"init","session_id":"s1"}"#)
        out += p.parse(line: #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/a/b.swift"}}]},"session_id":"s1","parent_tool_use_id":null}"#)
        out += p.parse(line: #"{"type":"assistant","message":{"content":[{"type":"text","text":"Done."}]},"session_id":"s1","parent_tool_use_id":null}"#)
        out += p.parse(line: "not json")
        out += p.parse(line: #"{"type":"result","subtype":"success","is_error":false,"result":"Done.","num_turns":2,"usage":{"input_tokens":1,"output_tokens":2}}"#)
        #expect(out == [.started(continuation: "s1"), .activity("Reads · b.swift"), .textDelta("Done."), .usage(ChatUsage(inputTokens: 1, outputTokens: 2)), .done])
        var e = ClaudeStreamParser()
        let err = e.parse(line: #"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"Not logged in"}"#)
        #expect(err.last == .failed("Not logged in"))
    }

    @Test func codexFixture() throws {
        var p = CodexExecParser()
        let out = collect(&p, lines: try Fixtures.lines("cli/codex-exec.jsonl")) { $0.parse(line: $1) }
        #expect(out.first == .started(continuation: "01a1ac8e-ba38-7123-8163-f4bbec36c3cb"))
        #expect(text(of: out) == "hi")
        #expect(out.contains(.usage(ChatUsage(inputTokens: 21373, outputTokens: 5))))
        #expect(out.last == .done)
    }

    @Test func codexActivityAndIncrementalText() {
        var p = CodexExecParser()
        var out = p.parse(line: #"{"type":"item.started","item":{"id":"c1","type":"command_execution","command":"rg -n foo src","status":"in_progress"}}"#)
        out += p.parse(line: #"{"type":"item.completed","item":{"id":"c1","type":"command_execution","command":"rg -n foo src","exit_code":0}}"#)
        out += p.parse(line: #"{"type":"item.updated","item":{"id":"m1","type":"agent_message","text":"Hel"}}"#)
        out += p.parse(line: #"{"type":"item.completed","item":{"id":"m1","type":"agent_message","text":"Hello"}}"#)
        out += p.parse(line: #"{"type":"item.completed","item":{"id":"f1","type":"file_change","changes":[{"path":"src/a.swift","kind":"update"},{"path":"src/b.swift","kind":"add"}]}}"#)
        out += p.parse(line: #"{"type":"turn.failed","error":{"message":"boom"}}"#)
        #expect(out == [.activity("Searches · rg -n foo src"), .textDelta("Hel"), .textDelta("lo"), .activity("Edits · a.swift +1"), .failed("boom")])
    }

    @Test func geminiFixture() throws {
        var p = GeminiStreamParser()
        let out = collect(&p, lines: try Fixtures.lines("cli/gemini-stream.jsonl")) { $0.parse(line: $1) }
        #expect(out.first == .started(continuation: "9c2f1c1e-1111-4f2a-9a1b-5c6d7e8f9a0b"))
        #expect(out.contains(.activity("Reads · README.md")))
        #expect(text(of: out) == "hi")
        #expect(out.contains(.usage(ChatUsage(inputTokens: 110, outputTokens: 10))))
        #expect(out.last == .done)
        var e = GeminiStreamParser()
        #expect(e.parse(line: #"{"type":"result","status":"error","error":{"message":"quota"}}"#).last == .failed("quota"))
    }

    @Test func capabilitiesAndArgs() {
        let caps = CLICapabilities.parse(help: "  -p, --print   Print\n  --output-format <f>\n  --allowedTools, --allowed-tools <tools...>\n  --session-id <uuid>")
        #expect(caps.has("--print") && caps.has("--allowed-tools") && caps.has("--session-id") && !caps.has("--resume"))
        let a = CLIArgs.claude(resume: nil, sessionID: "u1", model: "opus", caps: caps)
        #expect(a == ["-p", "--output-format", "stream-json", "--verbose", "--session-id", "u1", "--model", "opus"])
        let b = CLIArgs.claude(resume: "r1", sessionID: "u1", model: nil, caps: CLICapabilities())
        #expect(b == ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages", "--resume", "r1"])
        #expect(CLIArgs.codex(resume: nil, model: nil, cwd: "/p", sandbox: "read-only", caps: CLICapabilities()) == ["exec", "--json", "--skip-git-repo-check", "-C", "/p", "-s", "read-only", "-"])
        #expect(CLIArgs.codex(resume: "t1", model: "m", cwd: "/p", sandbox: "", caps: CLICapabilities()) == ["exec", "resume", "t1", "--json", "--skip-git-repo-check", "-m", "m", "-"])
        #expect(CLIArgs.gemini(resume: "s", model: nil, approvalMode: "yolo", caps: CLICapabilities()) == ["-p", "", "-o", "stream-json", "--resume", "s", "--approval-mode", "yolo"])
    }
}

@Suite struct ChatRepositoryTests {
    @Test func threadsAndMessagesRoundTrip() throws {
        let repo = try ChatRepository(db: try SQLiteDB.inMemory())
        var t = ChatThread(provider: "claude-cli", model: "", cwd: "/p")
        try repo.save(t)
        let m1 = ChatMessage(threadID: t.id, role: .user, text: "hi", attachments: [ChatAttachment(kind: .file, title: "a.txt", text: "x", path: "/a.txt")])
        let m2 = ChatMessage(threadID: t.id, role: .assistant, text: "hello", activity: ["Reads · a.txt"], usage: ChatUsage(inputTokens: 1, outputTokens: 2), createdAt: m1.createdAt.addingTimeInterval(1))
        try repo.save(m1)
        try repo.save(m2)
        t.continuation = "sess"
        t.title = "hi"
        try repo.save(t)
        let threads = try repo.threads()
        #expect(threads.count == 1 && threads[0].continuation == "sess" && threads[0].title == "hi")
        let msgs = try repo.messages(threadID: t.id)
        #expect(msgs.map(\.text) == ["hi", "hello"])
        #expect(msgs[0].attachments.first?.path == "/a.txt")
        #expect(msgs[1].activity == ["Reads · a.txt"] && msgs[1].usage?.outputTokens == 2)
        try repo.delete(threadID: t.id)
        #expect(try repo.threads().isEmpty)
        #expect(try repo.messages(threadID: t.id).isEmpty)
    }
}
