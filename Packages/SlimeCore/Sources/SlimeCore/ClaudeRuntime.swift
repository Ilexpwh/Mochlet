import Foundation

public actor ClaudeRuntime: AgentRuntime {
    public nonisolated let events: AsyncStream<JSONValue>
    private let sink: AsyncStream<JSONValue>.Continuation
    private let client: RPCClient
    private let executable: String
    private var reader: Task<Void, Never>?
    private var controls: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var protocolState: ClaudeProtocol?
    private var closed = false
    private var sent = false
    private var settlementTimeout: Task<Void, Never>?
    public init(executable: String, client: RPCClient = RPCClient()) {
        self.executable = executable; self.client = client
        let stream = AsyncStream<JSONValue>.makeStream(bufferingPolicy: .bufferingNewest(2048)); events = stream.stream; sink = stream.continuation
    }
    public func prepare(project: Project, threadID: String?, readOnly: Bool) async throws -> String {
        guard protocolState == nil, !closed else { throw MochletError.message("Claude runtimes handle one task turn at a time.") }
        try ProjectResolver.validateRoot(project)
        let version = try await CommandProcess().run(executable: executable, arguments: ["--version"], timeout: 10)
        guard version.status == 0, String(decoding: version.data, as: UTF8.self).split(separator: " ").first == "2.1.296" else {
            throw MochletError.message("This experimental adapter requires Claude Code 2.1.296. Verify a newer CLI protocol before enabling it.")
        }
        try Task.checkCancellation()
        guard !closed else { throw MochletError.message("Claude startup was cancelled.") }
        let id = threadID ?? UUID().uuidString.lowercased()
        guard UUID(uuidString: id) != nil else { throw MochletError.message("Claude requires an exact stored session UUID.") }
        protocolState = ClaudeProtocol(sessionID: id, cwd: project.root, readOnly: readOnly)
        var arguments = ["--output-format", "stream-json", "--verbose", "--input-format", "stream-json", "--permission-prompt-tool", "stdio", "--permission-mode", "manual", "--strict-mcp-config", "--tools", readOnly ? "Read,Glob,Grep,AskUserQuestion" : "Read,Glob,Grep,Edit,Write,Bash,AskUserQuestion"]
        arguments.append(threadID == nil ? "--session-id=\(id)" : "--resume=\(id)")
        try await client.launch(executable: executable, arguments: arguments, cwd: project.root, environment: ["CLAUDE_CODE_DISABLE_BACKGROUND_TASKS": "1", "CLAUDE_CODE_DISABLE_AGENT_VIEW": "1", "CLAUDE_CODE_SDK_READS_SESSION_STATE": "1"])
        reader = Task { [weak self, client] in for await frame in client.events { await self?.receive(frame) } }
        do { _ = try await control(["subtype": .string("initialize"), "hooks": .null]); return id }
        catch { await stop(); throw error }
    }
    public func send(threadID: String, text: String) async throws -> String {
        guard !sent, protocolState?.sessionID == threadID, !closed else { throw MochletError.message("Claude session is not ready for this turn.") }
        sent = true
        try await client.writeRaw(.object(["type": .string("user"), "session_id": .string(threadID), "message": .object(["role": .string("user"), "content": .string(text)]), "parent_tool_use_id": .null]))
        return threadID
    }
    public func interrupt(threadID: String, turnID: String) async throws {
        guard protocolState?.sessionID == threadID else { throw MochletError.message("Cannot interrupt a different Claude session.") }
        _ = try await control(["subtype": .string("interrupt")])
    }
    public func reply(id: JSONValue, result: JSONValue) async throws {
        guard let key = id.string, let state = protocolState else { throw MochletError.message("Invalid Claude request identity.") }
        let wire = try state.response(id: key, result: result)
        // Mark before crossing an actor boundary so duplicate UI replies fail closed.
        protocolState?.delivered(key)
        do {
            try await client.writeRaw(wire)
            if var state = protocolState {
                let events = state.settleIfReady(); protocolState = state
                if state.completed { settlementTimeout?.cancel(); settlementTimeout = nil }
                for event in events { sink.yield(event) }
            }
        }
        catch { await fail(error.localizedDescription); throw error }
    }
    public func reject(id: JSONValue, message: String) async throws {
        guard let key = id.string else { return }
        try await client.writeRaw(.object(["type": .string("control_response"), "response": .object(["subtype": .string("error"), "request_id": .string(key), "error": .string(message)])]))
        protocolState?.delivered(key)
    }
    public func readUsage() throws -> JSONValue { .null } // No supported subscription allowance telemetry.
    private func control(_ request: [String: JSONValue]) async throws -> JSONValue {
        let id = UUID().uuidString
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard !closed else { continuation.resume(throwing: MochletError.message("Claude is disconnected.")); return }
                controls[id] = continuation
                Task { [weak self, client] in
                    do { try await client.writeRaw(.object(["type": .string("control_request"), "request_id": .string(id), "request": .object(request)])) }
                    catch { await self?.fail(error.localizedDescription) }
                }
                Task { [weak self] in try? await Task.sleep(for: .seconds(30)); await self?.timeout(id) }
            }
        } onCancel: { Task { await self.timeout(id) } }
    }
    private func timeout(_ id: String) async {
        if controls[id] != nil { await fail("Claude control request timed out or was cancelled.") }
    }
    private func receive(_ frame: JSONValue) async {
        guard !closed else { return }
        if frame["method"].string == "mochlet/disconnected" { await fail(frame["params"]["reason"].string ?? "Claude disconnected."); return }
        if frame["type"].string == "control_response", let id = frame["response"]["request_id"].string, let pending = controls.removeValue(forKey: id) {
            if frame["response"]["subtype"].string == "success" { pending.resume(returning: frame["response"]["response"]) }
            else { pending.resume(throwing: MochletError.message(frame["response"]["error"].string ?? "Claude control request failed.")) }; return
        }
        do {
            guard var state = protocolState else { return }
            let normalized = try state.receive(frame); protocolState = state
            if frame["type"].string == "result", !state.completed {
                settlementTimeout?.cancel()
                settlementTimeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(30)); await self?.fail("Claude returned a result without becoming idle. Inspect its session before resuming.") } catch { }
                }
            }
            if state.completed { settlementTimeout?.cancel(); settlementTimeout = nil }
            for event in normalized {
                if case .dropped = sink.yield(event) { throw MochletError.message("Claude output exceeded the UI event queue.") }
            }
        } catch { await fail(error.localizedDescription) }
    }
    private func fail(_ reason: String) async {
        guard !closed else { return }; closed = true
        settlementTimeout?.cancel(); settlementTimeout = nil
        for pending in controls.values { pending.resume(throwing: MochletError.message(reason)) }; controls = [:]
        sink.yield(.object(["method": .string("mochlet/disconnected"), "params": .object(["reason": .string(reason)])])); sink.finish()
        await client.stop(); reader?.cancel(); reader = nil
    }
    public func stop() async { await fail("Claude connection stopped.") }
}
