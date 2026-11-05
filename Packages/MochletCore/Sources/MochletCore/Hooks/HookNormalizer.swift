import Foundation

/// A parsed socket line.
public enum HookInbound: Sendable, Equatable {
    case event(HookEvent)
    /// Blocking permission request; the host must answer through the reply handle.
    case permission(HookEvent)
    /// Blocking AskUserQuestion; `question` is nil when the payload could not be parsed (answer `ask`).
    case question(HookEvent, AskQuestion?)
    case statusLine(StatusLinePayload)
    case invalid(String)
}

/// Claude Code statusline payload forwarded by `mochlet-hook --statusline`.
public struct StatusLinePayload: Sendable, Equatable {
    public var sessionID: String
    public var rateLimits: JSONValue
    public var model: String?
    public var workspace: String?
    public var cost: JSONValue
    public init(sessionID: String, rateLimits: JSONValue, model: String? = nil, workspace: String? = nil, cost: JSONValue = .null) {
        self.sessionID = sessionID
        self.rateLimits = rateLimits
        self.model = model
        self.workspace = workspace
        self.cost = cost
    }
}

/// Turns a relay line into a `HookInbound`. The relay already normalises most fields; this
/// repeats the mapping so lines written by hand (tests, replay scripts, generic agents) work too.
public enum HookNormalizer {
    public static func parse(_ data: Data, now: Date = Date()) -> HookInbound {
        guard let json = JSONValue.parse(data), json.object != nil else { return .invalid("not a JSON object") }
        return parse(json, now: now)
    }

    public static func parse(_ json: JSONValue, now: Date = Date()) -> HookInbound {
        let kind = json["mochlet_kind"].string
        if kind == "statusline" {
            let rl = json["rate_limits"]
            return .statusLine(StatusLinePayload(sessionID: json["session_id"].string ?? "", rateLimits: rl.object == nil ? .object([:]) : rl,
                                                 model: json.path("model.display_name").string ?? json["model"].string,
                                                 workspace: json.path("workspace.current_dir").string ?? json["workspace"].string,
                                                 cost: json["cost"]))
        }
        let event = makeEvent(json, now: now)
        if kind == "ask_user_question" || (event.name == .preToolUse && event.tool == "AskUserQuestion" && json["mochlet_wait"].bool == true) {
            var e = event
            e.name = .askUserQuestion
            return .question(e, AskQuestion.parse(event.toolInput))
        }
        if event.name == .permissionRequest { return .permission(event) }
        return .event(event)
    }

    static func makeEvent(_ json: JSONValue, now: Date) -> HookEvent {
        let terminal = TerminalIdentity(json: json)
        var tag = json["mochlet_agent"].string
        if (tag ?? "").isEmpty, terminal.claudeEntrypoint == "claude-desktop" { tag = "claude-desktop" }
        let agent = AgentKind(tag: tag, bundleID: terminal.bundleID, termProgram: terminal.termProgram)
        let rawName = json["hook_event_name"].string ?? json["event"].string ?? ""
        let name = HookEventName.normalise(rawName)

        var tool = json.firstString(["tool_name", "toolName"])
        if tool == nil, let n = json.path("toolCall.name").string, !n.isEmpty { tool = n }
        if tool == nil, let n = json["tool"].string, !n.isEmpty { tool = n }

        var input = json["tool_input"]
        if input.isNull {
            if json["toolArgs"].object != nil { input = json["toolArgs"] }
            else if var args = json.path("toolCall.args").object {
                for (from, to) in [("CommandLine", "command"), ("FilePath", "file_path"), ("Path", "path"), ("Url", "url"), ("Query", "query"), ("Pattern", "pattern")] {
                    if let v = args[from], args[to] == nil { args[to] = v }
                }
                input = .object(args)
            } else if json["input"].object != nil { input = json["input"] }
        }

        var cwd = json["cwd"].string ?? ""
        if cwd.isEmpty {
            for k in ["workspacePaths", "workspace_roots"] {
                if let first = json[k][0].string, !first.isEmpty { cwd = first; break }
            }
        }
        if cwd.isEmpty, let w = json["workdir"].string { cwd = w }

        var sessionID = json.firstString(["session_id", "conversationId", "conversation_id", "sessionId", "GEMINI_SESSION_ID"]) ?? ""
        if sessionID.isEmpty || sessionID == "unknown" { sessionID = "\(agent.id)+\(cwd)" }

        return HookEvent(name: name, rawName: rawName, agent: agent, sessionID: sessionID, cwd: cwd,
                         sessionRoot: json["session_root"].string, sessionTitle: json["session_title"].string,
                         tool: tool, toolInput: input, toolResponse: json["tool_response"],
                         prompt: json["prompt"].string, message: json["message"].string,
                         lastAssistantMessage: json["last_assistant_message"].string, transcriptPath: json["transcript_path"].string,
                         terminal: terminal, raw: json, receivedAt: now)
    }
}
