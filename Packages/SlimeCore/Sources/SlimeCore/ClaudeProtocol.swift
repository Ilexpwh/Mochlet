import Foundation

/// Pinned to Claude Code 2.1.296 and the official SDK v0.2.176 control contract.
/// This reducer is independent of process I/O so approval identity and routing can
/// be tested without sending prompts or loading a user's sessions.
public struct ClaudeProtocol: Sendable {
    public let sessionID: String
    public let cwd: String
    public private(set) var pending: [String: JSONValue] = [:]
    public private(set) var verified = false
    public private(set) var completed = false
    public private(set) var cost: JSONValue = .null
    private var messageIDs: Set<String> = []
    private var hasText = false
    private var idle = false
    private var finalResult: JSONValue?
    private let allowedTools: Set<String>
    public init(sessionID: String, cwd: String, readOnly: Bool = false) {
        self.sessionID = sessionID; self.cwd = cwd
        allowedTools = Set(readOnly ? ["Read", "Glob", "Grep", "AskUserQuestion", "EndConversation"] : ["Read", "Glob", "Grep", "Edit", "Write", "Bash", "AskUserQuestion", "EndConversation"])
    }
    public func event(_ method: String, _ params: [String: JSONValue] = [:], id: String? = nil) -> JSONValue {
        var body: [String: JSONValue] = ["method": .string(method), "params": .object(params.merging(["threadId": .string(sessionID)]) { a, _ in a })]
        if let id { body["id"] = .string(id) }; return .object(body)
    }
    public mutating func receive(_ frame: JSONValue) throws -> [JSONValue] {
        if let id = frame["session_id"].string, !id.isEmpty, id != sessionID { throw MochletError.message("Claude returned a different session. Work was interrupted.") }
        let type = frame["type"].string ?? ""
        if type == "system", frame["subtype"].string == "init" {
            guard frame["session_id"].string == sessionID, let actual = frame["cwd"].string else { throw MochletError.message("Claude did not identify its session and directory.") }
            try ProjectResolver.verifyCWD(expected: cwd, actual: actual)
            guard frame["tools"] != .null, frame["mcp_servers"] != .null,
                  frame["tools"].array.allSatisfy({ $0.string.map(allowedTools.contains) == true }), frame["mcp_servers"].array.isEmpty else {
                throw MochletError.message("Claude enabled tools or MCP servers outside this adapter's supported configuration.")
            }
            verified = true; return [event("mochlet/sessionVerified")]
        }
        if type == "system", frame["subtype"].string == "session_state_changed" {
            idle = frame["state"].string == "idle"
            return settleIfReady()
        }
        if type == "system", frame["subtype"].string == "task_started" {
            throw MochletError.message("Claude started background work, which this adapter does not support. Inspect the CLI session before resuming.")
        }
        if type == "control_cancel_request", let id = frame["request_id"].string {
            pending.removeValue(forKey: id); return [event("serverRequest/resolved", ["requestId": .string(id)])] + settleIfReady()
        }
        if type == "control_request", let id = frame["request_id"].string {
            guard verified, !completed else { throw MochletError.message("Claude requested a tool outside a verified active session.") }
            let request = frame["request"]
            guard request["subtype"].string == "can_use_tool" else { throw MochletError.message("Unsupported Claude control request. Work was interrupted.") }
            guard pending[id] == nil else { return [] }
            pending[id] = request
            let input = request["input"]
            if request["tool_name"].string == "AskUserQuestion" {
                let questions = input["questions"].array.enumerated().map { index, q in
                    JSONValue.object(["id": .string("q\(index)"), "question": q["question"], "options": q["options"], "isOther": .bool(true), "multiSelect": q["multiSelect"]])
                }
                guard !questions.isEmpty else { throw MochletError.message("Claude sent an empty question request.") }
                return [event("item/tool/requestUserInput", ["questions": .array(questions)], id: id)]
            }
            return [event("item/commandExecution/requestApproval", ["reason": .string("Claude requests \(request["tool_name"].string ?? "a tool"). Review the exact input below."), "command": .string(input.formatted)], id: id)]
        }
        if type == "assistant" {
            guard verified, !completed else { throw MochletError.message("Claude output arrived before session verification.") }
            if let id = frame["uuid"].string, !messageIDs.insert(id).inserted { return [] }
            var result: [JSONValue] = []
            for block in frame["message"]["content"].array {
                if block["type"].string == "text", let text = block["text"].string, !text.isEmpty {
                    result.append(event("item/agentMessage/delta", ["delta": .string((hasText ? "\n\n" : "") + text)])); hasText = true
                } else if block["type"].string == "tool_use" {
                    result.append(event("item/started", ["item": .object(["id": block["id"], "type": block["name"], "input": block["input"]])]))
                }
            }
            return result
        }
        if type == "result" {
            guard !completed else { return [] }
            finalResult = frame
            // Startup errors may not emit idle; no verified session can have work.
            if !verified { idle = true }
            return settleIfReady()
        }
        return []
    }
    public mutating func settleIfReady() -> [JSONValue] {
        guard let frame = finalResult, idle, pending.isEmpty, !completed else { return [] }
        let reason = frame["terminal_reason"].string ?? ""
        let interrupted = reason == "aborted_streaming" || reason == "aborted_tools"
        let failure = frame["is_error"] == .bool(true) || frame["subtype"].string != "success" || !verified || (!reason.isEmpty && reason != "completed" && reason != "success" && !interrupted)
        cost = .object(["total_cost_usd": frame["total_cost_usd"], "usage": frame["usage"], "modelUsage": frame["modelUsage"]])
        completed = true
        var result: [JSONValue] = [event("mochlet/providerUsage", ["usage": cost])]
        if !hasText, let text = frame["result"].string { result.append(event("item/agentMessage/delta", ["delta": .string(text)])) }
        var turn: [String: JSONValue] = ["status": .string(interrupted ? "interrupted" : failure ? "failed" : "completed")]
        if failure { turn["error"] = .object(["message": .string(frame["errors"].array.compactMap(\.string).joined(separator: "\n").nilIfEmpty ?? "Claude did not complete successfully. Inspect the session before retrying.")]) }
        result.append(event("turn/completed", ["turn": .object(turn)])); return result
    }
    public func response(id: String, result: JSONValue) throws -> JSONValue {
        guard let request = pending[id], !completed else { throw MochletError.message("This Claude request expired or was already answered.") }
        var response: [String: JSONValue]
        if request["tool_name"].string == "AskUserQuestion" {
            var input = request["input"].object; var answers: [String: JSONValue] = [:]
            for (index, q) in request["input"]["questions"].array.enumerated() {
                let choices = result["answers"]["q\(index)"]["answers"].array.compactMap(\.string).filter { !$0.isEmpty }
                guard let question = q["question"].string, !choices.isEmpty else { throw MochletError.message("Answer each Claude question before sending.") }
                answers[question] = q["multiSelect"] == .bool(true) ? .array(choices.map(JSONValue.string)) : .string(choices[0])
            }
            input["answers"] = .object(answers); response = ["behavior": .string("allow"), "updatedInput": .object(input)]
        } else if result["decision"].string == "accept" {
            response = ["behavior": .string("allow"), "updatedInput": request["input"]]
        } else { response = ["behavior": .string("deny"), "message": .string("User declined this operation.")] }
        return .object(["type": .string("control_response"), "response": .object(["subtype": .string("success"), "request_id": .string(id), "response": .object(response)])])
    }
    public mutating func delivered(_ id: String) { pending.removeValue(forKey: id) }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
