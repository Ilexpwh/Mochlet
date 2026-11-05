import Foundation

/// `claude -p --output-format stream-json --include-partial-messages`.
public struct ClaudeStreamParser: Sendable {
    private var sawPartialText = false
    private var usage: ChatUsage?
    private var finished = false
    private var thinkingAnnounced = false
    /// The last `rate_limit_event` payload (plan pills).
    public private(set) var lastRateLimits: JSONValue?
    public private(set) var sessionID: String?

    public init() {}

    public mutating func parse(line: String) -> [ChatEvent] {
        guard let j = JSONValue.parse(line) else { return [] }
        switch j["type"].string ?? "" {
        case "system":
            if j["subtype"].string == "init" {
                sessionID = j["session_id"].string
                return [.started(continuation: sessionID)]
            }
            return []
        case "stream_event":
            let ev = j["event"]
            switch ev["type"].string ?? "" {
            case "content_block_delta":
                let d = ev["delta"]
                if d["type"].string == "text_delta", let t = d["text"].string, j["parent_tool_use_id"].isNull {
                    sawPartialText = true
                    return [.textDelta(t)]
                }
                if d["type"].string == "thinking_delta", !thinkingAnnounced {
                    thinkingAnnounced = true
                    return [.activity("thinking")]
                }
                return []
            case "content_block_start":
                if ev["content_block"]["type"].string == "thinking", !thinkingAnnounced {
                    thinkingAnnounced = true
                    return [.activity("thinking")]
                }
                return []
            default:
                return []
            }
        case "assistant":
            guard j["parent_tool_use_id"].isNull else { return [] }
            var out: [ChatEvent] = []
            for block in j["message"]["content"].array ?? [] {
                switch block["type"].string ?? "" {
                case "text":
                    if !sawPartialText, let t = block["text"].string, !t.isEmpty { out.append(.textDelta(t)) }
                case "tool_use":
                    out.append(.activity(TickerLabel.label(tool: block["name"].string ?? "tool", input: block["input"])))
                default: break
                }
            }
            if j["is_api_error_message"].bool == true, let err = j["error"].string {
                out.append(.failed(j["message"]["content"].array?.first?["text"].string ?? err))
            }
            return out
        case "rate_limit_event":
            lastRateLimits = j["rate_limit_info"]
            return []
        case "result":
            guard !finished else { return [] }
            finished = true
            var out: [ChatEvent] = []
            if let u = j["usage"].object {
                out.append(.usage(ChatUsage(inputTokens: (u["input_tokens"]?.int ?? 0) + (u["cache_read_input_tokens"]?.int ?? 0) + (u["cache_creation_input_tokens"]?.int ?? 0),
                                            outputTokens: u["output_tokens"]?.int ?? 0)))
            }
            if j["is_error"].bool == true || j["subtype"].string?.hasPrefix("error") == true {
                out.append(.failed(j["result"].string ?? j["subtype"].string ?? "Claude error"))
            } else {
                if !sawPartialText, let r = j["result"].string, !r.isEmpty, j["num_turns"].int == 0 { out.append(.textDelta(r)) }
                out.append(.done)
            }
            return out
        default:
            return []
        }
    }
}

/// `codex exec --json`.
public struct CodexExecParser: Sendable {
    private var emitted: [String: String] = [:]
    private var finished = false
    public private(set) var threadID: String?

    public init() {}

    public mutating func parse(line: String) -> [ChatEvent] {
        guard let j = JSONValue.parse(line) else { return [] }
        switch j["type"].string ?? "" {
        case "thread.started":
            threadID = j["thread_id"].string
            return [.started(continuation: threadID)]
        case "item.started", "item.updated", "item.completed":
            let item = j["item"]
            let id = item["id"].string ?? UUID().uuidString
            switch item["type"].string ?? "" {
            case "agent_message":
                let text = item["text"].string ?? ""
                let prev = emitted[id] ?? ""
                guard text.count > prev.count, text.hasPrefix(prev) else { return [] }
                emitted[id] = text
                return [.textDelta(String(text.dropFirst(prev.count)))]
            case "reasoning":
                if emitted[id] == nil { emitted[id] = "thinking"; return [.activity("thinking")] }
                return []
            case "command_execution":
                guard j["type"].string == "item.started" else { return [] }
                let cmd = item["command"].string ?? ""
                return [.activity(TickerLabel.label(tool: "Bash", input: .object(["command": .string(cmd)])))]
            case "file_change":
                guard j["type"].string != "item.updated" else { return [] }
                let paths = (item["changes"].array ?? []).compactMap { $0["path"].string }
                let name = paths.first.map { ($0 as NSString).lastPathComponent } ?? "files"
                let label = paths.count > 1 ? "Edits · \(name) +\(paths.count - 1)" : "Edits · \(name)"
                if emitted[id] == label { return [] }
                emitted[id] = label
                return [.activity(label)]
            case "mcp_tool_call":
                guard j["type"].string == "item.started" else { return [] }
                return [.activity("\(item["server"].string ?? "mcp") · \(item["tool"].string ?? "tool")")]
            case "web_search":
                guard j["type"].string == "item.started" else { return [] }
                return [.activity("Searches · \(OneLine.collapse(item["query"].string ?? "", limit: 50))")]
            default:
                return []
            }
        case "turn.completed":
            guard !finished else { return [] }
            finished = true
            var out: [ChatEvent] = []
            if let u = j["usage"].object {
                out.append(.usage(ChatUsage(inputTokens: u["input_tokens"]?.int ?? 0, outputTokens: u["output_tokens"]?.int ?? 0)))
            }
            out.append(.done)
            return out
        case "turn.failed":
            finished = true
            return [.failed(j["error"]["message"].string ?? "Codex turn failed")]
        case "error":
            finished = true
            return [.failed(j["message"].string ?? j["error"]["message"].string ?? "Codex error")]
        default:
            return []
        }
    }
}

/// `gemini -p … -o stream-json`.
public struct GeminiStreamParser: Sendable {
    private var sawDelta = false
    private var finished = false
    public private(set) var sessionID: String?

    public init() {}

    public mutating func parse(line: String) -> [ChatEvent] {
        guard let j = JSONValue.parse(line) else { return [] }
        switch j["type"].string ?? "" {
        case "init":
            sessionID = j["session_id"].string
            return [.started(continuation: sessionID)]
        case "message":
            guard j["role"].string == "assistant", let content = j["content"].string, !content.isEmpty else { return [] }
            let isDelta = j["delta"].bool ?? false
            if isDelta { sawDelta = true; return [.textDelta(content)] }
            return sawDelta ? [] : [.textDelta(content)]
        case "tool_use":
            let name = j.firstString(["tool_name", "name"]) ?? "tool"
            let input = j["parameters"].isNull ? j["input"] : j["parameters"]
            return [.activity(TickerLabel.label(tool: name, input: input))]
        case "result":
            guard !finished else { return [] }
            finished = true
            var out: [ChatEvent] = []
            if let s = j["stats"].object {
                out.append(.usage(ChatUsage(inputTokens: s["input_tokens"]?.int ?? 0, outputTokens: s["output_tokens"]?.int ?? 0)))
            }
            if let status = j["status"].string, status != "success" {
                out.append(.failed(j["error"]["message"].string ?? "Gemini \(status)"))
            } else {
                out.append(.done)
            }
            return out
        case "error":
            finished = true
            return [.failed(j["message"].string ?? j["error"]["message"].string ?? "Gemini error")]
        default:
            return []
        }
    }
}
