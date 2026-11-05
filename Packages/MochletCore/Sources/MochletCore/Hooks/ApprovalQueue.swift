import Foundation

/// A pending permission request shown as a card.
public struct ApprovalRequest: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var sessionID: String
    public var agent: AgentKind
    public var projectName: String
    public var cwd: String
    public var tool: String
    public var command: String
    public var inputKey: String
    public var input: JSONValue
    public var permissionSuggestions: JSONValue
    public var received: Date
    public var terminal: TerminalIdentity

    public init(id: UUID = UUID(), event: HookEvent) {
        self.id = id
        sessionID = event.sessionID
        agent = event.agent
        projectName = event.projectName
        cwd = event.cwd
        tool = event.tool ?? ""
        input = event.toolInput
        inputKey = event.toolInputKey
        permissionSuggestions = event.raw["permission_suggestions"]
        received = event.receivedAt
        terminal = event.terminal
        if tool == "ExitPlanMode" {
            command = Self.planTitle(event.toolInput["plan"].string ?? "")
        } else if let c = event.toolInput["command"].string, !c.isEmpty {
            command = c
        } else {
            command = tool
        }
    }

    public var isPlan: Bool { tool == "ExitPlanMode" }
    public var canAlways: Bool { agent.supportsAlways && !permissionSuggestions.isEmptyish }

    /// Everything the card must show before the user decides: the whole command (never
    /// truncated), the file an edit touches, the full plan, or the tool input itself.
    public var detail: String {
        if isPlan { return input["plan"].string ?? command }
        if let c = input["command"].string, !c.isEmpty { return c }
        var lines: [String] = []
        if let path = input.firstString(["file_path", "path", "notebook_path"]) { lines.append(path) }
        if let url = input["url"].string { lines.append(url) }
        if let pattern = input["pattern"].string { lines.append("pattern: \(pattern)") }
        if let old = input["old_string"].string {
            lines.append("- " + OneLine.collapse(old, limit: 160))
            lines.append("+ " + OneLine.collapse(input["new_string"].string ?? "", limit: 160))
        }
        if let edits = input["edits"].array { lines.append("\(edits.count) edits") }
        if let content = input["content"].string { lines.append("\(content.utf8.count) bytes, \(content.components(separatedBy: "\n").count) lines") }
        if let prompt = input.firstString(["prompt", "description", "query"]) { lines.append(OneLine.collapse(prompt, limit: 200)) }
        if lines.isEmpty, let data = try? input.data(pretty: true, sortedKeys: true), let text = String(data: data, encoding: .utf8), text != "null" {
            return text
        }
        return lines.isEmpty ? tool : lines.joined(separator: "\n")
    }

    public var detailLineCount: Int { detail.isEmpty ? 0 : detail.components(separatedBy: "\n").count }

    /// What "Always" would add, one line per rule, from the agent's `permission_suggestions`.
    public var alwaysSummary: [String] {
        guard let items = permissionSuggestions.array else { return [] }
        var out: [String] = []
        for item in items {
            let type = item["type"].string ?? ""
            switch type {
            case "addRules":
                let behavior = item["behavior"].string ?? "allow"
                for rule in item["rules"].array ?? [] {
                    let tool = rule["toolName"].string ?? "?"
                    if let content = rule["ruleContent"].string, !content.isEmpty {
                        out.append("\(behavior) \(tool)(\(content))")
                    } else {
                        out.append("\(behavior) \(tool)")
                    }
                }
            case "setMode":
                out.append("switch to \(item["mode"].string ?? "?") mode")
            case "addDirectories":
                for d in item["directories"].array ?? [] { out.append("allow directory \(d.string ?? "?")") }
            default:
                out.append(type.isEmpty ? "rule" : type)
            }
        }
        return out
    }

    public static func planTitle(_ plan: String) -> String {
        for raw in plan.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            return line.replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression)
        }
        return "Plan"
    }

    /// Seconds before the card gives up ("Still waiting in <terminal>").
    public var timeout: TimeInterval {
        switch agent {
        case .copilot, .muse: return 110
        default: return 115
        }
    }
}

/// What the user chose on an approval card.
public enum ApprovalDecision: String, Sendable, Codable {
    case allow, always, deny, ask
    case planAuto = "plan_auto", planDefault = "plan_default", planChange = "plan_change"

    /// The one-line reply written to the relay.
    public var reply: JSONValue {
        switch self {
        case .allow: return .object(["permissionDecision": .string("allow")])
        case .always: return .object(["permissionDecision": .string("always")])
        case .deny: return .object(["permissionDecision": .string("deny")])
        case .ask: return .object(["permissionDecision": .string("ask")])
        case .planAuto: return .object(["permissionDecision": .string("allow"), "mode": .string("auto")])
        case .planDefault: return .object(["permissionDecision": .string("allow"), "mode": .string("default")])
        case .planChange: return .object(["permissionDecision": .string("change_plan")])
        }
    }
}

/// FIFO of pending approvals: the head is on screen; at most five wait; later events resolve them.
public struct ApprovalQueue: Sendable, Equatable {
    public static let maxPending = 5
    public private(set) var items: [ApprovalRequest] = []

    public init() {}

    public var head: ApprovalRequest? { items.first }
    public var count: Int { items.count }
    public var isEmpty: Bool { items.isEmpty }

    /// Returns false when the queue is full (answer `ask` immediately).
    @discardableResult
    public mutating func enqueue(_ r: ApprovalRequest) -> Bool {
        guard items.count < Self.maxPending else { return false }
        items.append(r)
        return true
    }

    public mutating func remove(id: UUID) -> ApprovalRequest? {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: i)
    }

    public func position(of id: UUID) -> Int? { items.firstIndex { $0.id == id }.map { $0 + 1 } }
    public func contains(sessionID: String) -> Bool { items.contains { $0.sessionID == sessionID } }

    /// Removes the requests a later event proves were handled elsewhere and returns them.
    public mutating func resolved(by event: HookEvent) -> [ApprovalRequest] {
        let out: [ApprovalRequest]
        switch event.name {
        case .postToolUse, .postToolUseFailure:
            let key = event.toolInputKey
            out = items.filter { $0.sessionID == event.sessionID && $0.tool == (event.tool ?? "") && $0.inputKey == key }
        case .stop, .stopFailure, .userPromptSubmit, .sessionEnd, .interrupt:
            out = items.filter { $0.sessionID == event.sessionID }
        default:
            return []
        }
        let ids = Set(out.map(\.id))
        items.removeAll { ids.contains($0.id) }
        return out
    }

    public mutating func expired(now: Date) -> [ApprovalRequest] {
        let out = items.filter { now.timeIntervalSince($0.received) > $0.timeout }
        let ids = Set(out.map(\.id))
        items.removeAll { ids.contains($0.id) }
        return out
    }
}
