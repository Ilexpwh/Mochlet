import Foundation

public actor PiRuntime: AgentRuntime {
    public nonisolated let events: AsyncStream<JSONValue>
    private let sink: AsyncStream<JSONValue>.Continuation
    private let client = RPCClient()
    private let executable: String
    private let directory: URL
    private let extraEnvironment: [String: String]
    private var reader: Task<Void, Never>?
    private var pending: [String: (String, CheckedContinuation<JSONValue, Error>, Bool)] = [:]
    private var dialogTimers: [String: Task<Void, Never>] = [:]
    private var state: PiProtocol?
    private var binding: PiSessionBinding?
    private var handshake: JSONValue?
    private let nonce = UUID().uuidString
    private var closed = false
    private var sent = false
    private var interrupting = false
    public init(executable: String, directory: URL, environment: [String: String] = [:]) {
        self.executable = executable; self.directory = directory; extraEnvironment = environment
        let pair = AsyncStream<JSONValue>.makeStream(bufferingPolicy: .bufferingNewest(2048)); events = pair.stream; sink = pair.continuation
    }
    public func prepare(project: Project, threadID: String?, readOnly: Bool) async throws -> String {
        guard state == nil, !closed else { throw MochletError.message("Pi runtimes handle one turn at a time.") }
        try ProjectResolver.validateRoot(project)
        let registry = try PiSessions(directory: directory)
        let saved = try threadID.map { try registry.load($0, cwd: project.root) }
        var environment = extraEnvironment
        environment["PATH"] = URL(fileURLWithPath: executable).deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/local/bin:" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
        environment["MOCHLET_PI_NONCE"] = nonce; environment["MOCHLET_PI_READ_ONLY"] = readOnly ? "1" : "0"
        let version = try await CommandProcess().run(executable: executable, arguments: ["--version"], timeout: 10, environment: environment)
        guard version.status == 0, String(decoding: version.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "1.4.0" else { throw MochletError.message("This Pi adapter requires CLI 1.4.0. Select its executable in Agent settings.") }
        try Task.checkCancellation(); guard !closed else { throw CancellationError() }
        let tools = readOnly ? ["read", "grep", "find", "ls"] : ["read", "grep", "find", "ls", "bash", "edit", "write"]
        var arguments = ["--mode", "rpc", "--offline", "--no-extensions", "--no-mcp", "--no-skills", "--no-prompt-templates", "--no-themes", "--no-approve", "--session-dir", registry.sessions.path, "--tools", tools.joined(separator: ","), "-e", PiSessions.guardExtension.path]
        if let saved { arguments += ["--session", saved.file] }
        try await client.launch(executable: executable, arguments: arguments, cwd: project.root, environment: environment)
        reader = Task { [weak self, client] in for await frame in client.events { await self?.receive(frame) } }
        do {
            let info = try await command("get_state")
            guard let id = info["sessionId"].string, let file = info["sessionFile"].string,
                  info["isStreaming"] == .bool(false), info["isCompacting"] == .bool(false), info["pendingMessageCount"].number == 0 else { throw MochletError.message("Pi did not return an idle, durable session.") }
            if let saved, saved.id != id || saved.file != file { throw MochletError.message("Pi resumed a different session.") }
            let current = PiSessionBinding(id: id, file: file, cwd: project.root)
            try registry.validate(current, cwd: project.root, requireFile: saved != nil)
            let checked = try await command("prompt", ["message": .string("/mochlet-guard-check " + nonce)])
            guard checked["disposition"].string == "handled", let handshake,
                  handshake["mochletGuard"].number == 1, handshake["sessionID"].string == id,
                  handshake["sessionFile"].string == file, handshake["readOnly"] == .bool(readOnly),
                  Set(handshake["tools"].array.compactMap(\.string)) == Set(tools), let cwd = handshake["cwd"].string else {
                throw MochletError.message("Pi's Mochlet approval extension did not verify its session and tool configuration.")
            }
            try ProjectResolver.verifyCWD(expected: project.root, actual: cwd)
            try Task.checkCancellation(); guard !closed else { throw CancellationError() }
            try registry.save(current); binding = current; state = PiProtocol(sessionID: id)
            return id
        } catch { await stop(); throw error }
    }
    public func send(threadID: String, text: String) async throws -> String {
        guard let binding, binding.id == threadID, !sent, !closed else { throw MochletError.message("Pi session is not ready.") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") else { throw MochletError.message("Pi slash commands are not supported in Mochlet tasks. Send a plain-language request.") }
        sent = true
        try emit(state!.event("mochlet/sessionVerified"))
        let response = try await command("prompt", ["message": .string(text)])
        guard response["disposition"].string == "started" else { await fail("Pi handled or queued the prompt without starting this task. Inspect the CLI session."); throw MochletError.message("Pi did not start the requested turn.") }
        return threadID
    }
    public func interrupt(threadID: String, turnID: String) async throws {
        guard binding?.id == threadID, !closed else { throw MochletError.message("Cannot interrupt a different Pi session.") }
        guard !interrupting, state?.completed != true else { return }; interrupting = true
        do {
            let cleared = try await command("clear_queue")
            let drafts = (cleared["steering"].array + cleared["followUp"].array).compactMap(\.string)
            if !drafts.isEmpty { try emit(state!.event("mochlet/cancelledDrafts", ["text": .string(drafts.joined(separator: "\n\n"))])) }
            for id in Array(state?.pending.keys ?? Dictionary<String, JSONValue>().keys) {
                try await client.writeRaw(.object(["type": .string("extension_ui_response"), "id": .string(id), "cancelled": .bool(true)]))
                state?.delivered(id); dialogTimers.removeValue(forKey: id)?.cancel()
                try emit(state!.event("serverRequest/resolved", ["requestId": .string(id)]))
            }
            _ = try await command("abort")
        } catch { await fail(error.localizedDescription); throw error }
    }
    public func reply(id: JSONValue, result: JSONValue) async throws {
        guard let key = id.string, let state else { throw MochletError.message("Invalid Pi dialog identity.") }
        let response = try state.response(id: key, result: result)
        self.state?.delivered(key); dialogTimers.removeValue(forKey: key)?.cancel()
        do { try await client.writeRaw(response) }
        catch { await fail(error.localizedDescription); throw error }
    }
    public func reject(id: JSONValue, message: String) async throws { try await reply(id: id, result: .object(["cancelled": .bool(true)])) }
    public func readUsage() -> JSONValue { .null } // Session statistics are NOT subscription limits.
    private func command(_ name: String, _ params: [String: JSONValue] = [:], timeout: Double = 30, fatalTimeout: Bool = true) async throws -> JSONValue {
        let id = UUID().uuidString
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard !closed else { continuation.resume(throwing: MochletError.message("Pi is disconnected.")); return }
                pending[id] = (name, continuation, fatalTimeout)
                Task { [weak self, client] in
                    do { try await client.writeRaw(.object(params.merging(["id": .string(id), "type": .string(name)]) { _, reserved in reserved })) }
                    catch { await self?.fail(error.localizedDescription) }
                }
                Task { [weak self] in try? await Task.sleep(for: .seconds(timeout)); await self?.timeout(id) }
            }
        } onCancel: { Task { await self.timeout(id) } }
    }
    private func timeout(_ id: String) async {
        guard let (_, continuation, fatal) = pending[id] else { return }
        if fatal { await fail("Pi request timed out or was cancelled.") }
        else { pending.removeValue(forKey: id); continuation.resume(throwing: MochletError.message("Pi session statistics are unavailable.")) }
    }
    private func emit(_ event: JSONValue) throws {
        if case .dropped = sink.yield(event) { throw MochletError.message("Pi output exceeded the event queue.") }
    }
    private func receive(_ frame: JSONValue) async {
        guard !closed else { return }
        if frame["method"].string == "mochlet/disconnected" { await fail(frame["params"]["reason"].string ?? "Pi disconnected."); return }
        if frame["type"].string == "response", let id = frame["id"].string, let (name, continuation, _) = pending.removeValue(forKey: id) {
            if frame["command"].string != name { continuation.resume(throwing: MochletError.message("Pi response command did not match its request.")); await fail("Pi returned a mismatched response.") }
            else if frame["success"] == .bool(true) { continuation.resume(returning: frame["data"]) }
            else { continuation.resume(throwing: MochletError.message(frame["error"].string ?? "Pi request failed.")) }; return
        }
        if frame["type"].string == "extension_ui_request", frame["method"].string == "notify", let text = frame["message"].string,
           let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)), value["nonce"].string == nonce {
            handshake = value; return
        }
        if frame["type"].string == "extension_error" { await fail("Pi's approval extension failed: " + (frame["error"].string ?? "unknown error")); return }
        do {
            guard var state, !state.completed else { return }
            let events = try state.receive(frame); self.state = state
            if let id = frame["id"].string, let deadline = state.deadlines[id], dialogTimers[id] == nil {
                dialogTimers[id] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))); await self?.expire(id) } catch { }
                }
            }
            if frame["type"].string == "agent_settled" {
                for timer in dialogTimers.values { timer.cancel() }; dialogTimers = [:]
                Task { [weak self] in await self?.settle(events) }
            } else { for event in events { try emit(event) } }
        } catch { await fail(error.localizedDescription) }
    }
    private func expire(_ id: String) async {
        dialogTimers.removeValue(forKey: id)
        do { for event in state?.expire(id) ?? [] { try emit(event) } } catch { await fail(error.localizedDescription) }
    }
    private func settle(_ events: [JSONValue]) async {
        // Keep reading stdout while requesting statistics; never await a response
        // from inside the stream reader itself.
        do {
            let stats = try await command("get_session_stats", timeout: 5, fatalTimeout: false)
            if let state { try emit(state.event("mochlet/providerUsage", ["usage": stats])) }
        } catch {
            guard !closed else { return }
            if let state { _ = try? emit(state.event("mochlet/providerNotice", ["message": .string("Pi session statistics are unavailable.")])) }
        }
        guard !closed else { return }
        do { for event in events { try emit(event) } } catch { await fail(error.localizedDescription) }
    }
    private func fail(_ reason: String) async {
        guard !closed else { return }; closed = true
        for (_, continuation, _) in pending.values { continuation.resume(throwing: MochletError.message(reason)) }; pending = [:]
        for timer in dialogTimers.values { timer.cancel() }; dialogTimers = [:]
        sink.yield(.object(["method": .string("mochlet/disconnected"), "params": .object(["reason": .string(reason)])])); sink.finish()
        await client.stop(); reader?.cancel(); reader = nil
    }
    public func stop() async { await fail("Pi connection stopped.") }
}
