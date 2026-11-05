import Foundation

/// Text helpers for the one-line ticker and final lines.
public enum OneLine {
    /// Joins lines and tabs with single spaces and cuts at `limit` with an ellipsis.
    public static func collapse(_ s: String, limit: Int = 60) -> String {
        let joined = s.replacingOccurrences(of: "\r", with: "").components(separatedBy: CharacterSet(charactersIn: "\n\t"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        if joined.count <= limit { return joined }
        return String(joined.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// First meaningful paragraph of an assistant message, markdown stripped, at most `max` chars.
    public static func firstParagraph(_ text: String, max: Int = 200) -> String {
        var lines: [String] = []
        var started = false
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let isRule = line.count >= 3 && Set(line).count == 1 && "-*_".contains(line.first!)
            let isTable = line.hasPrefix("|")
            if line.isEmpty || isRule || isTable {
                if started { break } else { continue }
            }
            started = true
            lines.append(line)
        }
        var s = lines.joined(separator: " ")
        s = s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "").replacingOccurrences(of: "`", with: "")
        s = s.replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^(?:[-*•]\s+|\d+\.\s+)"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if s.count > max { return String(s.prefix(max)).trimmingCharacters(in: .whitespaces) + "…" }
        return s
    }
}

/// The ticker line for a PreToolUse: "Edits · main.swift", "Runs · swift test", "server · tool".
public enum TickerLabel {
    public static let baseLabels: [String: String] = [
        "Bash": "Runs", "Read": "Reads", "Write": "Writes", "Edit": "Edits", "MultiEdit": "Edits", "apply_patch": "Edits",
        "Glob": "Searches", "Grep": "Searches", "WebSearch": "Searches the web", "WebFetch": "Fetches",
        "TodoWrite": "Tasks", "update_plan": "Tasks", "Task": "Agent", "spawn_agent": "Agent", "LS": "Lists",
        "NotebookEdit": "Notebook", "ask_question": "Needs input",
    ]

    public static func bashVerb(_ command: String) -> String {
        let first = command.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
        let base = (first as NSString).lastPathComponent
        if ["cat", "bat", "head", "tail", "less", "more", "nl"].contains(base) { return "Reads" }
        if ["rg", "grep", "find", "fd", "ls", "tree", "wc"].contains(base) { return "Searches" }
        let tests = ["pytest", "vitest", "jest", "npm test", "npm run test", "cargo test", "go test", "swift test", "make test", "xcodebuild test", "unittest"]
        if tests.contains(where: { command.contains($0) }) { return "Tests" }
        return "Runs"
    }

    public static func label(tool: String, input: JSONValue) -> String {
        if tool.hasPrefix("mcp__") {
            let parts = tool.dropFirst(5).components(separatedBy: "__")
            if parts.count >= 2 { return "\(parts[0]) · \(parts.dropFirst().joined(separator: "__"))" }
            return parts.first ?? tool
        }
        if tool == "ask_question" || tool.hasSuffix(":ask_question") {
            if let q = input["questions"][0]["question"].string { return "Needs input · \(OneLine.collapse(q))" }
            return "Needs input"
        }
        if tool == "Bash" || tool == "bash" {
            let cmd = input["command"].string ?? ""
            return cmd.isEmpty ? "Runs" : "\(bashVerb(cmd)) · \(OneLine.collapse(cmd))"
        }
        if tool == "apply_patch" {
            let text = input["command"].string ?? input["patch"].string ?? ""
            for line in text.components(separatedBy: "\n") {
                for p in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] where line.hasPrefix(p) {
                    return "Edits · \((String(line.dropFirst(p.count)) as NSString).lastPathComponent)"
                }
            }
            return "Edits"
        }
        let base = baseLabels[tool] ?? tool
        if let c = input["command"].string, !c.isEmpty { return "\(base) · \(OneLine.collapse(c))" }
        if let p = input["path"].string, !p.isEmpty { return "\(base) · \((p as NSString).lastPathComponent)" }
        if let p = input["file_path"].string, !p.isEmpty { return "\(base) · \((p as NSString).lastPathComponent)" }
        if let q = input["query"].string, !q.isEmpty { return "\(base) · \(OneLine.collapse(q))" }
        if let p = input["pattern"].string, !p.isEmpty { return "\(base) · \(OneLine.collapse(p))" }
        if let u = input["url"].string, !u.isEmpty { return "\(base) · \(OneLine.collapse(u))" }
        return base
    }
}

/// What to show when a turn ends in StopFailure.
public enum StopFailureDetail {
    public static func detail(_ raw: JSONValue) -> String? {
        if let s = raw.firstString(["error_message", "error_details", "message"]) { return OneLine.firstParagraph(s) }
        if let s = raw.path("error.message").string, !s.isEmpty { return OneLine.firstParagraph(s) }
        let type = raw["error_type"].string ?? raw["error"].string ?? ""
        let known: [String: String] = [
            "rate_limit": "Rate limited. The agent will retry after the limit resets.",
            "overloaded": "The model is overloaded right now.",
            "authentication_failed": "Authentication failed. Sign in again in the terminal.",
            "oauth_org_not_allowed": "This organisation is not allowed to use the agent.",
            "billing_error": "Billing problem on the account.",
            "server_error": "The model returned a server error.",
            "max_output_tokens": "The reply hit the output token limit.",
            "model_not_found": "The requested model was not found.",
        ]
        if let k = known[type] { return k }
        if let last = raw["last_assistant_message"].string, last.lowercased().contains("error") { return OneLine.firstParagraph(last) }
        if type.count > 3, Double(type) == nil, type != "unknown" { return type }
        return nil
    }
}
