import Foundation
import Testing
@testable import MochletCore

private func line(_ s: String) -> Data { Data(s.utf8) }

@Suite struct HookNormalizerTests {
    @Test func claudePreToolUse() {
        let d = line(#"{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/Users/me/proj","tool_name":"Bash","tool_input":{"command":"swift test"},"term_program":"iTerm.app","bundle_id":"com.googlecode.iterm2","tty":"ttys003","session_title":"My Proj"}"#)
        guard case .event(let e) = HookNormalizer.parse(d) else { Issue.record("not an event"); return }
        #expect(e.name == .preToolUse && e.agent == .claude && e.sessionID == "s1")
        #expect(e.projectName == "My Proj")
        #expect(e.terminal.terminalName == "iTerm" && e.terminal.tty == "ttys003")
        #expect(TickerLabel.label(tool: e.tool!, input: e.toolInput) == "Tests · swift test")
    }

    @Test func geminiNamesAreMapped() {
        let d = line(#"{"hook_event_name":"BeforeTool","mochlet_agent":"gemini","conversationId":"c9","cwd":"/tmp/x","toolCall":{"name":"run_shell_command","args":{"CommandLine":"ls -la"}}}"#)
        guard case .event(let e) = HookNormalizer.parse(d) else { Issue.record("not an event"); return }
        #expect(e.name == .preToolUse && e.agent == .gemini && e.sessionID == "c9")
        #expect(e.toolInput["command"].string == "ls -la")
        #expect(e.tool == "run_shell_command")
    }

    @Test func copilotCamelCase() {
        let d = line(#"{"hook_event_name":"preToolUse","mochlet_agent":"copilot","sessionId":"k","toolName":"bash","toolArgs":{"command":"cat a"}}"#)
        guard case .event(let e) = HookNormalizer.parse(d) else { Issue.record("not an event"); return }
        #expect(e.name == .preToolUse && e.agent == .copilot)
        #expect(TickerLabel.label(tool: e.tool!, input: e.toolInput) == "Reads · cat a")
    }

    @Test func permissionAndQuestionAreBlocking() {
        let p = line(#"{"hook_event_name":"PermissionRequest","session_id":"s","cwd":"/p","tool_name":"Bash","tool_input":{"command":"rm -rf build"},"permission_suggestions":[{"type":"addRules"}],"mochlet_wait":true}"#)
        guard case .permission(let e) = HookNormalizer.parse(p) else { Issue.record("not permission"); return }
        let r = ApprovalRequest(event: e)
        #expect(r.command == "rm -rf build" && r.canAlways)
        let q = line(#"{"hook_event_name":"PreToolUse","mochlet_kind":"ask_user_question","session_id":"s","cwd":"/p","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which?","header":"Choice header long","options":[{"label":"A"},{"label":"B","description":"bee"}],"multiSelect":true}]},"mochlet_wait":true}"#)
        guard case .question(let e2, let ask?) = HookNormalizer.parse(q) else { Issue.record("not question"); return }
        #expect(e2.name == .askUserQuestion)
        #expect(ask.questions[0].header == "Choice heade" && ask.questions[0].multiSelect && ask.hasDescriptions)
        let answers = ask.answers(selections: [["A", "B"]])
        #expect(answers["Which?"].array?.count == 2)
    }

    @Test func statusLine() {
        let d = line(#"{"mochlet_kind":"statusline","session_id":"s","rate_limits":{"five_hour":{"used_percentage":42,"resets_at":1900000000},"seven_day":{"used_percentage":150}}}"#)
        guard case .statusLine(let s) = HookNormalizer.parse(d) else { Issue.record("not statusline"); return }
        let u = PlanUsage.fromClaude(rateLimits: s.rateLimits, now: Date(timeIntervalSince1970: 1_800_000_000))!
        #expect(u.fiveHour?.usedPercent == 42 && u.week?.usedPercent == 100)
        #expect(PlanUsage.level(u.dominantPercent(now: Date(timeIntervalSince1970: 1_800_000_000))) == .high)
    }

    @Test func unknownSessionFallsBackToAgentAndCwd() {
        let d = line(#"{"hook_event_name":"Stop","cwd":"/a/b","mochlet_agent":"amp"}"#)
        guard case .event(let e) = HookNormalizer.parse(d) else { Issue.record("not an event"); return }
        #expect(e.sessionID == "amp+/a/b" && e.projectName == "b")
    }

    @Test func garbageDoesNotThrow() {
        #expect({ if case .invalid = HookNormalizer.parse(line("not json")) { return true } else { return false } }())
        #expect({ if case .invalid = HookNormalizer.parse(line("[1,2]")) { return true } else { return false } }())
    }
}

@Suite struct TickerLabelTests {
    @Test func labels() {
        #expect(TickerLabel.label(tool: "Edit", input: .object(["file_path": .string("/x/y/main.swift")])) == "Edits · main.swift")
        #expect(TickerLabel.label(tool: "mcp__mochlet__find", input: .null) == "mochlet · find")
        #expect(TickerLabel.label(tool: "Bash", input: .object(["command": .string("rg foo src")])) == "Searches · rg foo src")
        #expect(TickerLabel.label(tool: "apply_patch", input: .object(["command": .string("*** Begin Patch\n*** Update File: src/a.py\n")])) == "Edits · a.py")
        #expect(TickerLabel.label(tool: "WebSearch", input: .object(["query": .string("swift 6")])) == "Searches the web · swift 6")
        #expect(TickerLabel.label(tool: "Weird", input: .null) == "Weird")
    }

    @Test func oneLine() {
        #expect(OneLine.collapse("a\n  b\tc", limit: 60) == "a b c")
        #expect(OneLine.collapse(String(repeating: "x", count: 70), limit: 60).hasSuffix("…"))
        #expect(OneLine.firstParagraph("## Done\n\n- **Fixed** the `bug`\n\nMore") == "Done")
        #expect(OneLine.firstParagraph("\n\n1. First thing\nsecond line\n---\nafter") == "First thing second line")
        #expect(OneLine.firstParagraph("| a | b |\nreal text") == "real text")
    }

    @Test func stopFailure() {
        #expect(StopFailureDetail.detail(.object(["error_type": .string("rate_limit")]))!.hasPrefix("Rate limited"))
        #expect(StopFailureDetail.detail(.object(["message": .string("boom\nmore")])) == "boom more")
        #expect(StopFailureDetail.detail(.object(["error": .string("x")])) == nil)
    }
}

@Suite struct ApprovalQueueTests {
    func event(_ name: HookEventName, session: String = "s", tool: String = "Bash", cmd: String = "ls") -> HookEvent {
        HookEvent(name: name, rawName: name.rawValue, agent: .claude, sessionID: session, cwd: "/p", tool: tool, toolInput: .object(["command": .string(cmd)]))
    }

    @Test func fifoAndCap() {
        var q = ApprovalQueue()
        for i in 0..<5 {
            let ok = q.enqueue(ApprovalRequest(event: event(.permissionRequest, cmd: "c\(i)")))
            #expect(ok)
        }
        let full = q.enqueue(ApprovalRequest(event: event(.permissionRequest, cmd: "c6")))
        #expect(!full)
        #expect(q.head?.command == "c0" && q.count == 5)
        let id = q.items[2].id
        #expect(q.position(of: id) == 3)
        _ = q.remove(id: id)
        #expect(q.count == 4)
        let again = q.remove(id: id)
        #expect(again == nil)
    }

    @Test func resolution() {
        var q = ApprovalQueue()
        q.enqueue(ApprovalRequest(event: event(.permissionRequest, cmd: "a")))
        q.enqueue(ApprovalRequest(event: event(.permissionRequest, session: "t", cmd: "b")))
        let r1 = q.resolved(by: event(.preToolUse, cmd: "a"))
        let r2 = q.resolved(by: event(.postToolUse, cmd: "zzz"))
        let r3 = q.resolved(by: event(.postToolUse, cmd: "a"))
        let r4 = q.resolved(by: event(.stop, session: "t"))
        #expect(r1.isEmpty && r2.isEmpty && r3.count == 1 && r4.count == 1)
        #expect(q.isEmpty)
    }

    @Test func decisions() {
        #expect(ApprovalDecision.planAuto.reply["mode"].string == "auto")
        #expect(ApprovalDecision.deny.reply["permissionDecision"].string == "deny")
        #expect(ApprovalRequest.planTitle("\n# My plan\nbody") == "My plan")
    }
}

@Suite struct SessionReducerTests {
    func ev(_ name: HookEventName, tool: String? = nil, input: JSONValue = .null, msg: String? = nil, last: String? = nil, prompt: String? = nil) -> HookEvent {
        HookEvent(name: name, rawName: name.rawValue, agent: .claude, sessionID: "s1", cwd: "/Users/me/proj", tool: tool, toolInput: input, prompt: prompt, message: msg, lastAssistantMessage: last, terminal: TerminalIdentity(termProgram: "iTerm.app", bundleID: "com.googlecode.iterm2"))
    }

    @Test func lifecycle() {
        var r = SessionRegistry()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var fx = r.reduce(.hook(ev(.sessionStart)), now: t0)
        #expect(fx.contains(.spawnMini(id: "s1")) && fx.contains(.sound("work")))
        fx = r.reduce(.hook(ev(.userPromptSubmit, prompt: "fix the bug please")), now: t0 + 1)
        #expect(r.card("s1")?.state == .thinking && r.card("s1")?.steps.last?.text == "fix the bug please")
        fx = r.reduce(.hook(ev(.preToolUse, tool: "Edit", input: .object(["file_path": .string("/p/a.swift")]))), now: t0 + 2)
        #expect(r.card("s1")?.state == .working && r.card("s1")?.steps.last?.text == "Edits · a.swift")
        fx = r.reduce(.hook(ev(.postToolUse, tool: "Edit", input: .object(["file_path": .string("/p/a.swift"), "old_string": .string("a\n"), "new_string": .string("b\n")]))), now: t0 + 3)
        #expect(r.card("s1")?.diffs.count == 1)
        if case .diff(_, let name, let added, let removed)? = r.card("s1")?.steps.last?.kind { #expect(name == "a.swift" && added == 1 && removed == 1) } else { Issue.record("no diff step") }
        fx = r.reduce(.hook(ev(.stop, last: "**Done.** Fixed it.\n\nDetails")), now: t0 + 4)
        #expect(r.card("s1")?.state == .finished && r.card("s1")?.finalLine == "Done. Fixed it.")
        #expect(fx.contains(.sound("finish")) && fx.contains(.mainEmote("happy")) && fx.contains(.scheduleFinishedReset(id: "s1", after: SessionRegistry.finishedReset)))
        fx = r.reduce(.finishedReset(id: "s1"), now: t0 + 10)
        #expect(r.card("s1")?.state == .idle && fx == [.mergeMini(id: "s1")])
        fx = r.reduce(.hook(ev(.sessionEnd)), now: t0 + 11)
        #expect(r.card("s1") == nil && fx.contains(.removeSession(id: "s1")))
    }

    @Test func frontmostTerminalGetsBadgeNotSound() {
        var r = SessionRegistry()
        r.frontmostBundleID = "com.googlecode.iterm2"
        let t0 = Date()
        _ = r.reduce(.hook(ev(.userPromptSubmit, prompt: "x")), now: t0)
        let fx = r.reduce(.hook(ev(.stop, last: "ok")), now: t0 + 1)
        #expect(!fx.contains(.sound("finish")) && fx.contains(.badge(id: "s1", state: .finished)))
    }

    @Test func newTurnCancelsReset() {
        var r = SessionRegistry()
        let t0 = Date()
        _ = r.reduce(.hook(ev(.stop, last: "ok")), now: t0)
        let fx = r.reduce(.hook(ev(.userPromptSubmit, prompt: "again")), now: t0 + 1)
        #expect(fx.contains(.cancelFinishedReset(id: "s1")))
        let later = r.reduce(.finishedReset(id: "s1"), now: t0 + 7)
        #expect(later.isEmpty)
    }

    @Test func sweeps() {
        var r = SessionRegistry()
        let t0 = Date()
        _ = r.reduce(.hook(ev(.userPromptSubmit, prompt: "x")), now: t0)
        _ = r.reduce(.sweep, now: t0 + SessionRegistry.maxTurnSilence + 1)
        #expect(r.card("s1")?.isWorking == false && r.card("s1")?.state == .idle)
        let fx = r.reduce(.sweep, now: t0 + SessionRegistry.maxSilence + 1)
        #expect(r.card("s1") == nil && fx.contains(.removeSession(id: "s1")))
    }

    @Test func rateLimitAndQuestionNotifications() {
        var r = SessionRegistry()
        let t0 = Date()
        _ = r.reduce(.hook(ev(.notification, msg: "You hit the rate limit")), now: t0)
        #expect(r.card("s1")?.state == .ratelimit)
        _ = r.reduce(.hook(ev(.notification, msg: "Continue?")), now: t0 + 1)
        #expect(r.card("s1")?.state == .question)
        #expect(SlimeMoodPolicy.aggregate([.working, .question, .idle]) == .question)
    }

    @Test func stepsAreCapped() {
        var r = SessionRegistry()
        let t0 = Date()
        for i in 0..<30 { _ = r.reduce(.hook(ev(.preToolUse, tool: "Read", input: .object(["file_path": .string("/f\(i)")]))), now: t0 + Double(i)) }
        #expect(r.card("s1")?.steps.count == SessionCard.maxSteps)
        #expect(r.card("s1")?.steps.last?.text == "Reads · f29")
    }
}
