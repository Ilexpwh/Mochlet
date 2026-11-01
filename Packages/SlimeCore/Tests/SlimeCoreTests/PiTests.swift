import Foundation
import Testing
@testable import SlimeCore

@Test func piSessionBindingRejectsMovedRootsReplacedHeadersAndOutsideFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    let sessions = try PiSessions(directory: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID().uuidString
    let file = sessions.sessions.appendingPathComponent("session.jsonl")
    let binding = PiSessionBinding(id: id, file: file.path, cwd: root.path)
    try sessions.save(binding)
    #expect(throws: (any Error).self) { try sessions.load(id, cwd: root.path) }
    let header = JSONValue.object(["type": .string("session"), "id": .string(id), "cwd": .string(root.path)])
    var data = try JSONEncoder().encode(header); data.append(10); try data.write(to: file)
    #expect(try sessions.load(id, cwd: root.path) == binding)
    #expect(throws: (any Error).self) { try sessions.load(id, cwd: "/Users") }
    #expect(throws: (any Error).self) { try sessions.save(.init(id: id, file: "/tmp/outside.jsonl", cwd: root.path)) }
    try "{\"type\":\"session\",\"id\":\"other\",\"cwd\":\"/tmp\"}\n".write(to: file, atomically: true, encoding: .utf8)
    #expect(throws: (any Error).self) { try sessions.load(id, cwd: root.path) }
    #expect(FileManager.default.fileExists(atPath: PiSessions.guardExtension.path))
}

private func piJSON(_ text: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
@Test func piReconcilesFinalTextAndWaitsPastAgentEnd() throws {
    var state = PiProtocol(sessionID: "fixture")
    _ = try state.receive(piJSON(#"{"type":"message_start","message":{"role":"assistant"}}"#))
    _ = try state.receive(piJSON(#"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"draft"}}"#))
    let events = try state.receive(piJSON(#"{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"corrected"}],"stopReason":"stop"}}"#))
    #expect(events.first?["params"]["text"].string == "corrected\n\n")
    #expect(try state.receive(piJSON(#"{"type":"agent_end"}"#)).isEmpty)
    #expect(!state.completed)
    #expect(try state.receive(piJSON(#"{"type":"agent_settled","aborted":false}"#)).last?["params"]["turn"]["status"].string == "completed")
    #expect(try state.receive(piJSON(#"{"type":"agent_settled","aborted":false}"#)).isEmpty)
}
@Test func piDialogsKeepIdentityOptionsAndExpiration() throws {
    var state = PiProtocol(sessionID: "fixture"); let now = Date(timeIntervalSince1970: 100)
    _ = try state.receive(piJSON(#"{"type":"extension_ui_request","id":"a","method":"confirm","title":"Approve","message":"write file","timeout":1000}"#), now: now)
    _ = try state.receive(piJSON(#"{"type":"extension_ui_request","id":"b","method":"select","title":"Choose","options":["one","two"]}"#), now: now)
    let response = try state.response(id: "a", result: .object(["decision": .string("accept")]), now: now)
    #expect(response["confirmed"] == .bool(true) && response["id"].string == "a")
    #expect(throws: (any Error).self) { try state.response(id: "b", result: piJSON(#"{"answers":{"b":{"answers":["invented"]}}}"#)) }
    #expect(state.expire("a", now: now.addingTimeInterval(2)).count == 2)
    #expect(throws: (any Error).self) { try state.response(id: "a", result: .null, now: now) }
    #expect(try state.response(id: "b", result: .object(["cancelled": .bool(true)]))["cancelled"] == .bool(true))
    state.delivered("b"); #expect(state.pending.isEmpty)
}
@Test func piProviderFailureAndAbortAreNotSuccess() throws {
    var failure = PiProtocol(sessionID: "fixture")
    _ = try failure.receive(piJSON(#"{"type":"message_end","message":{"role":"assistant","content":[],"stopReason":"error","errorMessage":"No model configured"}}"#))
    #expect(try failure.receive(piJSON(#"{"type":"agent_settled","aborted":false}"#)).last?["params"]["turn"]["status"].string == "failed")
    var stopped = PiProtocol(sessionID: "fixture")
    #expect(try stopped.receive(piJSON(#"{"type":"agent_settled","aborted":true}"#)).last?["params"]["turn"]["status"].string == "interrupted")
}

private struct PiFixtureResult: Sendable {
    var status = ""
    var output = ""
    var draft = ""
    var approvals = 0
    var questions = 0
    var usage: JSONValue = .null
}
private func collectPi(_ runtime: PiRuntime, session: String, cancel: Bool = false) async throws -> PiFixtureResult {
    try await withThrowingTaskGroup(of: PiFixtureResult.self) { group in
        group.addTask {
            var result = PiFixtureResult()
            for await event in runtime.events {
                switch event["method"].string {
                case "item/commandExecution/requestApproval":
                    result.approvals += 1
                    if cancel { try await runtime.interrupt(threadID: session, turnID: session) }
                    else { try await runtime.reply(id: event["id"], result: .object(["decision": .string("decline")])) }
                case "item/tool/requestUserInput":
                    result.questions += 1
                    try await runtime.reply(id: event["id"], result: .object(["answers": .object(["choice": .object(["answers": .array([.string("Mochlet")])])])]))
                case "mochlet/outputSnapshot": result.output = event["params"]["text"].string ?? ""
                case "mochlet/cancelledDrafts": result.draft = event["params"]["text"].string ?? ""
                case "mochlet/providerUsage": result.usage = event["params"]["usage"]
                case "turn/completed": result.status = event["params"]["turn"]["status"].string ?? ""; return result
                case "mochlet/disconnected": throw MochletError.message("Unexpected Pi disconnect: " + event["params"].formatted)
                default: break
                }
            }
            throw MochletError.message("Pi event stream ended without a result")
        }
        group.addTask { try await Task.sleep(for: .seconds(20)); await runtime.stop(); throw MochletError.message("Pi fixture timed out") }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

@Test(arguments: ["normal", "cancel", "no_stats"])
func piProcessRoundTripAndExactResume(mode: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = Bundle.module.url(forResource: "pi-rpc", withExtension: "py", subdirectory: "Fixtures")!
    let trace = root.appendingPathComponent("wire.jsonl")
    var session: String?
    for _ in 0..<(mode == "normal" ? 2 : 1) {
        let runtime = PiRuntime(executable: executable.path, directory: root.appendingPathComponent("registry"), environment: ["MOCHLET_PI_FIXTURE": mode, "MOCHLET_PI_TRACE": trace.path])
        do {
            let id = try await runtime.prepare(project: Project(name: "Pi fixture", root: root.path), threadID: session, readOnly: false)
            if let session { #expect(id == session) }; session = id
            _ = try await runtime.send(threadID: id, text: "fixture")
            let result = try await collectPi(runtime, session: id, cancel: mode == "cancel")
            #expect(result.approvals == 1)
            if mode == "cancel" {
                #expect(result.status == "interrupted")
                #expect(result.draft == "Keep this unsent instruction")
            } else {
                #expect(result.status == "completed" && result.output == "PI_FIXTURE_OK\n\n" && result.questions == 1)
                #expect(mode == "no_stats" ? result.usage == .null : result.usage["tokens"]["input"].number == 12)
            }
            await runtime.stop()
        } catch { await runtime.stop(); throw error }
    }
    let commands = try String(contentsOf: trace, encoding: .utf8).split(separator: "\n").map { try piJSON(String($0)) }
    if mode == "cancel" {
        #expect(commands.firstIndex { $0["type"].string == "clear_queue" }! < commands.firstIndex { $0["type"].string == "abort" }!)
    }
    #expect(commands.filter { $0["type"].string == "get_session_stats" }.count == (mode == "normal" ? 2 : 1))
}

@Test(arguments: ["missing_guard", "wrong_cwd", "crash"])
func piProcessRefusesUnverifiedDispatchAndSurfacesDeath(mode: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = Bundle.module.url(forResource: "pi-rpc", withExtension: "py", subdirectory: "Fixtures")!
    let runtime = PiRuntime(executable: executable.path, directory: root.appendingPathComponent("registry"), environment: ["MOCHLET_PI_FIXTURE": mode])
    do {
        let session = try await runtime.prepare(project: Project(name: "fixture", root: root.path), threadID: nil, readOnly: true)
        #expect(mode == "crash")
        _ = try await runtime.send(threadID: session, text: "fixture")
        Issue.record("Expected Pi to reject this operation")
    } catch {
        #expect(!error.localizedDescription.isEmpty)
    }
    await runtime.stop()
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MOCHLET_LIVE_PI_PATH"] != nil))
func livePiGuardPreflightWithoutModelInference() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = PiRuntime(executable: ProcessInfo.processInfo.environment["MOCHLET_LIVE_PI_PATH"]!, directory: root.appendingPathComponent("registry"), environment: ["PI_CODING_AGENT_DIR": root.appendingPathComponent("auth").path])
    do {
        let session = try await runtime.prepare(project: Project(name: "Live Pi preflight", root: root.path), threadID: nil, readOnly: true)
        #expect(UUID(uuidString: session) != nil)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("registry/" + session + ".json").path))
        await runtime.stop()
    } catch { await runtime.stop(); throw error }
}
