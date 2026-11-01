import Foundation

public struct PiProtocol: Sendable {
    public let sessionID: String
    public private(set) var completed = false
    public private(set) var pending: [String: JSONValue] = [:]
    public private(set) var deadlines: [String: Date] = [:]
    private var finishedText = ""
    private var blocks: [Int: String] = [:]
    private var lastError: String?
    private var assistantAborted = false
    public init(sessionID: String) { self.sessionID = sessionID }
    public func event(_ method: String, _ params: [String: JSONValue] = [:], id: String? = nil) -> JSONValue {
        var value: [String: JSONValue] = ["method": .string(method), "params": .object(params.merging(["threadId": .string(sessionID)]) { a, _ in a })]
        if let id { value["id"] = .string(id) }; return .object(value)
    }
    private func snapshot() throws -> JSONValue {
        let text = finishedText + blocks.keys.sorted().compactMap { blocks[$0] }.joined()
        guard text.utf8.count <= 2_000_000 else { throw MochletError.message("Pi output exceeded Mochlet's display limit. Inspect the saved session.") }
        return event("mochlet/outputSnapshot", ["text": .string(text)])
    }
    public mutating func receive(_ frame: JSONValue, now: Date = Date()) throws -> [JSONValue] {
        guard !completed else { return [] }
        switch frame["type"].string {
        case "message_start":
            if frame["message"]["role"].string == "assistant" { blocks = [:] }
        case "message_update":
            let update = frame["assistantMessageEvent"]
            if update["type"].string == "text_delta" || update["type"].string == "text_end" {
                guard let index = update["contentIndex"].number, index.isFinite, index >= 0, index < 10_000 else { throw MochletError.message("Invalid Pi message block.") }
                if update["type"].string == "text_delta" { blocks[Int(index), default: ""] += update["delta"].string ?? "" }
                else { blocks[Int(index)] = update["content"].string ?? "" }
                return [try snapshot()]
            }
        case "message_end":
            let message = frame["message"]
            if message["role"].string == "assistant" {
                let text = message["content"].array.filter { $0["type"].string == "text" }.compactMap { $0["text"].string }.joined(separator: "\n")
                if !text.isEmpty { finishedText += text + "\n\n" }; blocks = [:]
                let reason = message["stopReason"].string
                assistantAborted = reason == "aborted"
                lastError = reason == "error" ? (message["errorMessage"].string ?? "Pi's provider returned an error.") : nil
                return [try snapshot()]
            }
        case "tool_execution_start", "tool_execution_end":
            return [event(frame["type"].string == "tool_execution_start" ? "item/started" : "item/completed", ["item": .object(["id": frame["toolCallId"], "type": frame["toolName"], "input": frame["args"], "result": frame["result"], "isError": frame["isError"]])])]
        case "auto_retry_end":
            if frame["success"] == .bool(false) { lastError = frame["finalError"].string ?? "Pi exhausted its automatic retries." }
        case "extension_error": throw MochletError.message("Pi's approval extension failed. Work was interrupted: " + (frame["error"].string ?? "unknown error"))
        case "extension_ui_request":
            let method = frame["method"].string ?? ""
            if method == "notify" {
                return [event("mochlet/providerNotice", ["message": frame["message"]])]
            }
            if ["setStatus", "setWidget", "setTitle", "set_editor_text"].contains(method) { return [] }
            guard ["confirm", "select", "input", "editor"].contains(method), let id = frame["id"].string else { throw MochletError.message("Pi requested an unsupported dialog.") }
            if pending[id] != nil { return [] }
            guard pending.count < 32 else { throw MochletError.message("Pi has too many unanswered dialogs.") }
            pending[id] = frame
            if let timeout = frame["timeout"].number {
                guard timeout.isFinite, timeout >= 0, timeout <= 86_400_000 else { throw MochletError.message("Pi supplied an invalid dialog timeout.") }
                deadlines[id] = now.addingTimeInterval(timeout / 1000)
            }
            if method == "confirm" {
                return [event("item/commandExecution/requestApproval", ["reason": frame["title"], "command": frame["message"], "expiresAt": deadlines[id].map { .number($0.timeIntervalSince1970) } ?? .null], id: id)]
            }
            let options = frame["options"].array.compactMap(\.string).map { JSONValue.object(["label": .string($0)]) }
            return [event("item/tool/requestUserInput", ["questions": .array([.object(["id": .string(id), "question": frame["title"], "options": .array(options), "prefill": frame["prefill"], "allowCustom": .bool(method != "select")])]), "canDismiss": .bool(true)], id: id)]
        case "agent_settled":
            completed = true
            let abandoned = Array(pending.keys); pending = [:]; deadlines = [:]
            let aborted = frame["aborted"] == .bool(true) || assistantAborted
            let error = lastError ?? (!abandoned.isEmpty && !aborted ? "Pi settled with unanswered requests." : nil)
            var turn: [String: JSONValue] = ["status": .string(aborted ? "interrupted" : error == nil ? "completed" : "failed")]
            if let error { turn["error"] = .object(["message": .string(error)]) }
            return abandoned.map { event("serverRequest/resolved", ["requestId": .string($0)]) } + [event("turn/completed", ["turn": .object(turn)])]
        default: break // agent_end is deliberately NOT completion.
        }
        return []
    }
    public mutating func expire(_ id: String, now: Date = Date()) -> [JSONValue] {
        guard let deadline = deadlines[id], deadline <= now, pending[id] != nil else { return [] }
        delivered(id)
        return [event("serverRequest/resolved", ["requestId": .string(id)]), event("mochlet/providerNotice", ["message": .string("Pi's request expired; no answer was sent.")])]
    }
    public func response(id: String, result: JSONValue, now: Date = Date()) throws -> JSONValue {
        guard let request = pending[id], !completed, deadlines[id].map({ $0 > now }) ?? true else { throw MochletError.message("This Pi request expired or was already answered.") }
        var response: [String: JSONValue] = ["type": .string("extension_ui_response"), "id": .string(id)]
        if result["cancelled"] == .bool(true) { response["cancelled"] = .bool(true) }
        else if request["method"].string == "confirm" { response["confirmed"] = .bool(result["decision"].string == "accept") }
        else {
            guard let value = result["answers"][id]["answers"].array.first?.string else { throw MochletError.message("Pi needs an answer or an explicit dismissal.") }
            if request["method"].string == "select", !request["options"].array.contains(.string(value)) { throw MochletError.message("Choose one of Pi's offered options.") }
            response["value"] = .string(value)
        }
        return .object(response)
    }
    public mutating func delivered(_ id: String) { pending.removeValue(forKey: id); deadlines.removeValue(forKey: id) }
}
