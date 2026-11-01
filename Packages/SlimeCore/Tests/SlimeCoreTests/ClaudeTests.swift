import Foundation
import Testing
@testable import SlimeCore

private func json(_ text: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
private let fixtureSession = "00000000-0000-0000-0000-000000000001"
private func initializedClaude() throws -> ClaudeProtocol {
    var state = ClaudeProtocol(sessionID: fixtureSession, cwd: "/tmp")
    _ = try state.receive(json("""
    {"type":"system","subtype":"init","session_id":"\(fixtureSession)","cwd":"/tmp","tools":["Read","Bash","AskUserQuestion"],"mcp_servers":[]}
    """)); return state
}

@Test func claudeApprovalIdentityAndCancelledQuestions() throws {
    var state = try initializedClaude()
    let request = try json(#"{"type":"control_request","request_id":"a","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"swift test"},"permission_suggestions":[{"type":"allowAll"}]}}"#)
    #expect(try state.receive(request).count == 1)
    #expect(try state.receive(request).isEmpty)
    var b = request.object; b["request_id"] = .string("b"); _ = try state.receive(.object(b))
    let response = try state.response(id: "b", result: .object(["decision": .string("accept")]))
    #expect(response["response"]["request_id"].string == "b")
    #expect(response["response"]["response"]["updatedInput"]["command"].string == "swift test")
    #expect(response["response"]["response"]["updatedPermissions"] == .null)
    state.delivered("b")
    #expect(throws: (any Error).self) { try state.response(id: "b", result: .null) }
    #expect(try state.response(id: "a", result: .null)["response"]["response"]["behavior"].string == "deny")
    _ = try state.receive(json(#"{"type":"control_cancel_request","request_id":"a"}"#))
    #expect(throws: (any Error).self) { try state.response(id: "a", result: .null) }
    _ = try state.receive(json(#"{"type":"control_request","request_id":"q","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","input":{"questions":[{"question":"Which project?","options":[{"label":"Mochlet"}]}]}}}"#))
    let answer = try state.response(id: "q", result: json(#"{"answers":{"q0":{"answers":["Mochlet"]}}}"#))
    #expect(answer["response"]["response"]["updatedInput"]["answers"]["Which project?"].string == "Mochlet")
}

@Test func claudeVerifiesIdentityAndWaitsForIdle() throws {
    var state = try initializedClaude()
    #expect(throws: (any Error).self) { try state.receive(json(#"{"type":"assistant","session_id":"other"}"#)) }
    #expect(throws: (any Error).self) { try state.receive(json(#"{"type":"system","subtype":"task_started","task_id":"background"}"#)) }
    #expect(try state.receive(json(#"{"type":"result","subtype":"success","is_error":false,"terminal_reason":"api_error"}"#)).isEmpty)
    #expect(!state.completed)
    let events = try state.receive(json(#"{"type":"system","subtype":"session_state_changed","state":"idle"}"#))
    #expect(events.last?["params"]["turn"]["status"].string == "failed")
    #expect(try state.receive(json(#"{"type":"result","subtype":"success"}"#)).isEmpty)
    var readOnly = ClaudeProtocol(sessionID: fixtureSession, cwd: "/tmp", readOnly: true)
    #expect(throws: (any Error).self) { try readOnly.receive(json("""
    {"type":"system","subtype":"init","session_id":"\(fixtureSession)","cwd":"/tmp","tools":["Bash"],"mcp_servers":[]}
    """)) }
}

@Test func agentRoutesPersistAndRejectMovedOrUnconfirmedSessions() async throws {
    let store = try Store(path: ":memory:")
    let project = Project(name: "fixture", root: "/tmp"); try await store.save(project)
    var task = WorkTask(projectID: project.id, title: "Claude fixture")
    task.provider = "claude"; task.threadID = fixtureSession; task.sessionCWD = "/tmp"
    #expect(throws: (any Error).self) { try SessionRoute.validate(task: task, project: project) }
    task.sessionConfirmed = true; try SessionRoute.validate(task: task, project: project)
    try await store.save(task)
    #expect(try await store.tasks().first == task)
    var moved = project; moved.root = "/Users"
    #expect(throws: (any Error).self) { try SessionRoute.validate(task: task, project: moved) }
}

private func awaitClaude(_ runtime: ClaudeRuntime, answer: Bool = false) async throws -> String {
    try await withThrowingTaskGroup(of: String.self) { group in
        group.addTask {
            var output = ""
            for await event in runtime.events {
                switch event["method"].string {
                case "item/agentMessage/delta": output += event["params"]["delta"].string ?? ""
                case "item/commandExecution/requestApproval":
                    guard answer else { throw MochletError.message("Unexpected tool request in smoke test") }
                    try await runtime.reply(id: event["id"], result: .object(["decision": .string("decline")]))
                case "turn/completed":
                    guard event["params"]["turn"]["status"].string == "completed" else { throw MochletError.message(event["params"]["turn"].formatted) }
                    return output
                case "mochlet/disconnected": throw MochletError.message(event["params"].formatted)
                default: break
                }
            }
            throw MochletError.message("Event stream ended before completion")
        }
        group.addTask { try await Task.sleep(for: .seconds(60)); await runtime.stop(); throw MochletError.message("Claude smoke timed out") }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

@Test func claudeProcessFixtureUsesOwnWireAndFragmentedFrames() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("claude-fixture")
    try #"""
    #!/usr/bin/python3
    import sys, json, os
    if '--version' in sys.argv:
        print('2.1.296 (fixture)'); sys.exit(0)
    assert '--strict-mcp-config' in sys.argv
    assert os.environ['CLAUDE_CODE_DISABLE_BACKGROUND_TASKS'] == '1'
    sid = next(x.split('=', 1)[1] for x in sys.argv if x.startswith('--session-id='))
    def emit(obj):
        data = json.dumps(obj) + '\n'
        for c in data:
            sys.stdout.write(c); sys.stdout.flush()
    for line in sys.stdin:
        msg = json.loads(line)
        if msg['type'] == 'control_request':
            emit({'type':'control_response','response':{'subtype':'success','request_id':msg['request_id'],'response':{}}})
        elif msg['type'] == 'user':
            emit({'type':'system','subtype':'init','session_id':sid,'cwd':os.getcwd(),'tools':['Read','Bash'],'mcp_servers':[]})
            emit({'type':'system','subtype':'session_state_changed','state':'running'})
            emit({'type':'control_request','request_id':'tool','request':{'subtype':'can_use_tool','tool_name':'Bash','input':{'command':'echo fixture'}}})
        elif msg['type'] == 'control_response':
            assert msg['response']['response']['behavior'] == 'deny'
            emit({'type':'assistant','uuid':'text1','session_id':sid,'message':{'content':[{'type':'text','text':'FIXTURE_OK'}]}})
            emit({'type':'result','subtype':'success','is_error':False,'session_id':sid})
            emit({'type':'system','subtype':'session_state_changed','state':'idle'})
    """#.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let runtime = ClaudeRuntime(executable: script.path)
    do {
        let session = try await runtime.prepare(project: Project(name: "fixture", root: root.path), threadID: nil, readOnly: false)
        _ = try await runtime.send(threadID: session, text: "fixture")
        #expect(try await awaitClaude(runtime, answer: true) == "FIXTURE_OK")
        await runtime.stop()
    } catch { await runtime.stop(); throw error }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MOCHLET_LIVE_CLAUDE"] == "1"))
func liveClaudeReadOnlyAndExactResume() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mochlet-claude-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let project = Project(name: "Claude smoke", root: root.path)
    let executable = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path
    var session: String?
    for _ in 0..<2 {
        let runtime = ClaudeRuntime(executable: executable)
        do {
            let id = try await runtime.prepare(project: project, threadID: session, readOnly: true)
            if let session { #expect(id == session) }; session = id
            _ = try await runtime.send(threadID: id, text: "Reply with exactly MOCHLET_CLAUDE_OK. Do not use tools.")
            #expect(try await awaitClaude(runtime).contains("MOCHLET_CLAUDE_OK"))
            await runtime.stop()
        } catch { await runtime.stop(); throw error }
    }
}

@Test func claudeLastControlCancellationSettlesAndMultiSelectPreservesChoices() throws {
    var state = try initializedClaude()
    _ = try state.receive(json(#"{"type":"control_request","request_id":"q","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","input":{"questions":[{"question":"Pick features","multiSelect":true,"options":[{"label":"Voice"},{"label":"Memory"}]}]}}}"#))
    let response = try state.response(id: "q", result: json(#"{"answers":{"q0":{"answers":["Voice","Memory"]}}}"#))
    #expect(response["response"]["response"]["updatedInput"]["answers"]["Pick features"].array == [.string("Voice"), .string("Memory")])
    #expect(try state.receive(json(#"{"type":"result","subtype":"success","is_error":false}"#)).isEmpty)
    #expect(try state.receive(json(#"{"type":"system","subtype":"session_state_changed","state":"idle"}"#)).isEmpty)
    let events = try state.receive(json(#"{"type":"control_cancel_request","request_id":"q"}"#))
    #expect(events.filter { $0["method"].string == "turn/completed" }.count == 1)
    #expect(state.completed)
}
