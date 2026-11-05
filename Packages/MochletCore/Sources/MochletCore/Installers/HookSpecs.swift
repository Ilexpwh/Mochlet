import Foundation

public enum HookInstallStatus: String, Sendable, Equatable {
    case notInstalled, installed, outdated
}

/// Marker every Mochlet hook command carries; removal strips only entries containing it.
public let hookMarker = "mochlet-hook"

func containsMarker(_ v: JSONValue) -> Bool {
    switch v {
    case .string(let s): return s.contains(hookMarker)
    case .array(let a): return a.contains(where: containsMarker)
    case .object(let o): return o.values.contains(where: containsMarker)
    default: return false
    }
}

/// Removes Mochlet's own entries from a `[group]` array: legacy flat groups whose `command`
/// is ours, inner hooks whose `command` is ours, then groups left empty.
func stripOurs(_ groups: [JSONValue]) -> [JSONValue] {
    groups.compactMap { g -> JSONValue? in
        if let c = g["command"].string, c.contains(hookMarker) { return nil }
        guard let inner = g["hooks"].array else { return g }
        let kept = inner.filter { !($0["command"].string ?? "").contains(hookMarker) }
        if kept.isEmpty { return nil }
        var g2 = g
        g2["hooks"] = .array(kept)
        return g2
    }
}

func hookGroups(_ json: JSONValue, event: String, path: String) throws -> [JSONValue] {
    let hooks = json["hooks"]
    if hooks.isNull { return [] }
    guard let o = hooks.object else { throw ConfigFileError.unexpectedShape(path, "hooks") }
    guard let g = o[event] else { return [] }
    guard let arr = g.array else { throw ConfigFileError.unexpectedShape(path, "hooks.\(event)") }
    return arr
}

func setHookGroups(_ json: inout JSONValue, event: String, groups: [JSONValue]) {
    var hooks = json["hooks"].object ?? [:]
    if groups.isEmpty { hooks[event] = nil } else { hooks[event] = .array(groups) }
    json["hooks"] = .object(hooks)
}

/// Claude Code: `~/.claude/settings.json` hooks + statusLine chaining.
public enum ClaudeHookSpec {
    public static let events: [(String, Int)] = [
        ("SessionStart", 10), ("SessionEnd", 10), ("UserPromptSubmit", 10), ("PreToolUse", 10), ("PostToolUse", 10),
        ("PostToolUseFailure", 10), ("PermissionRequest", 120), ("Notification", 10), ("Stop", 10), ("StopFailure", 10),
        ("SubagentStart", 10), ("SubagentStop", 10),
    ]
    public static let askTimeout = 130

    public static func command(_ relayPath: String) -> String { "\"\(relayPath)\"" }

    /// Returns the new settings and the statusLine object that was replaced (to be saved as
    /// `statusline-previous.json`), if any.
    public static func install(into json: JSONValue, relayPath: String, path: String = "~/.claude/settings.json") throws -> (json: JSONValue, previousStatusLine: JSONValue?) {
        var out = json
        let cmd = command(relayPath)
        for (event, timeout) in events {
            var groups = stripOurs(try hookGroups(json, event: event, path: path))
            groups.append(.object(["hooks": .array([.object(["type": .string("command"), "command": .string(cmd), "timeout": .number(Double(timeout))])])]))
            if event == "PreToolUse" {
                groups.append(.object(["matcher": .string("AskUserQuestion"),
                                       "hooks": .array([.object(["type": .string("command"), "command": .string(cmd + " --ask"), "timeout": .number(Double(askTimeout))])])]))
            }
            setHookGroups(&out, event: event, groups: groups)
        }
        // statusLine: chain the existing command.
        let statusCmd = cmd + " --statusline"
        var previous: JSONValue?
        let existing = json["statusLine"]
        if let o = existing.object, let c = o["command"]?.string {
            if !c.contains(hookMarker) { previous = existing }
            var s = o
            s["command"] = .string(statusCmd)
            out["statusLine"] = .object(s)
        } else {
            out["statusLine"] = .object(["type": .string("command"), "command": .string(statusCmd)])
        }
        return (out, previous)
    }

    /// Removes our hooks and restores the statusLine (`previousStatusLine` from the saved file, or drops ours).
    public static func uninstall(from json: JSONValue, previousStatusLine: JSONValue?, path: String = "~/.claude/settings.json") throws -> JSONValue {
        var out = json
        if let hooks = json["hooks"].object {
            for (event, g) in hooks {
                guard let arr = g.array else { continue }
                setHookGroups(&out, event: event, groups: stripOurs(arr))
            }
            if out["hooks"].object?.isEmpty == true { out["hooks"] = .object([:]) }
        }
        if let c = json["statusLine"]["command"].string, c.contains(hookMarker) {
            if let p = previousStatusLine, p.object != nil {
                out["statusLine"] = p
            } else {
                var o = out.object ?? [:]
                o["statusLine"] = nil
                out = .object(o)
            }
        }
        return out
    }

    public static func status(of json: JSONValue, relayPath: String) -> HookInstallStatus {
        let groups = (try? hookGroups(json, event: "SessionStart", path: "")) ?? []
        guard groups.contains(where: containsMarker) else { return .notInstalled }
        let cmd = command(relayPath)
        var ok = true
        for (event, timeout) in events {
            let gs = (try? hookGroups(json, event: event, path: "")) ?? []
            let ours = gs.filter { $0["matcher"].isNull && containsMarker($0) }
            guard let g = ours.first, let h = g["hooks"][0].object else { ok = false; break }
            if h["command"]?.string != cmd || (h["timeout"]?.int ?? 0) < timeout { ok = false; break }
        }
        let pre = (try? hookGroups(json, event: "PreToolUse", path: "")) ?? []
        if !pre.contains(where: { $0["matcher"].string == "AskUserQuestion" && containsMarker($0) }) { ok = false }
        if json["statusLine"]["command"].string != cmd + " --statusline" { ok = false }
        return ok ? .installed : .outdated
    }
}

/// Codex: `~/.codex/hooks.json` (same shape as Claude; the user must trust hooks with `/hooks`).
public enum CodexHookSpec {
    public static let events: [(String, Int)] = [
        ("SessionStart", 10), ("UserPromptSubmit", 10), ("PreToolUse", 10), ("PermissionRequest", 120), ("PostToolUse", 10),
        ("Stop", 10), ("SubagentStart", 10), ("SubagentStop", 10), ("PreCompact", 3), ("Interrupt", 3), ("SessionEnd", 3),
    ]
    public static let waitingMessage = "Waiting for your answer in the notch (Mochlet)"

    public static func command(_ relayPath: String) -> String { "/bin/sh \"\(relayPath)\" --agent codex" }

    public static func install(into json: JSONValue, relayPath: String, path: String = "~/.codex/hooks.json") throws -> JSONValue {
        var out = json
        let cmd = command(relayPath)
        for (event, timeout) in events {
            var groups = stripOurs(try hookGroups(json, event: event, path: path))
            var hook: [String: JSONValue] = ["type": .string("command"), "command": .string(cmd), "timeout": .number(Double(timeout))]
            if event == "PermissionRequest" { hook["statusMessage"] = .string(waitingMessage) }
            groups.append(.object(["hooks": .array([.object(hook)])]))
            setHookGroups(&out, event: event, groups: groups)
        }
        return out
    }

    public static func uninstall(from json: JSONValue) -> JSONValue {
        var out = json
        if let hooks = json["hooks"].object {
            for (event, g) in hooks {
                guard let arr = g.array else { continue }
                setHookGroups(&out, event: event, groups: stripOurs(arr))
            }
            if out["hooks"].object?.isEmpty == true {
                var o = out.object ?? [:]
                o["hooks"] = nil
                out = .object(o)
            }
        }
        return out
    }

    public static func status(of json: JSONValue, relayPath: String) -> HookInstallStatus {
        let cmd = command(relayPath)
        var any = false, ok = true
        for (event, timeout) in events {
            let gs = (try? hookGroups(json, event: event, path: "")) ?? []
            guard let g = gs.first(where: containsMarker), let h = g["hooks"][0].object else { ok = false; continue }
            any = true
            if h["command"]?.string != cmd || (h["timeout"]?.int ?? 0) < timeout { ok = false }
        }
        return !any ? .notInstalled : ok ? .installed : .outdated
    }

    /// Group index of our hook under an event (what Codex's trust state keys on), if installed.
    public static func groupIndex(in json: JSONValue, event: String) -> Int? {
        ((try? hookGroups(json, event: event, path: "")) ?? []).firstIndex(where: containsMarker)
    }

    /// Codex keeps `[hooks.state."<hooks.json>:<event_snake>:<group>:<index>"] trusted_hash` in
    /// config.toml once the user trusted the hooks. True when our SessionStart group has one.
    public static func isTrusted(configTOML: String, hooksPath: String, sessionStartGroup: Int) -> Bool {
        let key = "[hooks.state.\"\(hooksPath):session_start:\(sessionStartGroup):0\"]"
        return configTOML.contains(key)
    }
}

/// Gemini CLI: `~/.gemini/settings.json` → `hooks` with millisecond timeouts and `matcher: "*"`.
public enum GeminiHookSpec {
    public static let events: [(String, String, Int)] = [
        ("SessionStart", "SessionStart", 10000), ("SessionEnd", "SessionEnd", 10000), ("BeforeTool", "PreToolUse", 5000),
        ("AfterTool", "PostToolUse", 5000), ("BeforeAgent", "UserPromptSubmit", 5000), ("AfterAgent", "Stop", 5000),
        ("Notification", "Notification", 5000),
    ]

    public static func command(_ relayPath: String, _ normalized: String) -> String { "/bin/sh \"\(relayPath)\" --agent gemini \(normalized)" }

    public static func install(into json: JSONValue, relayPath: String, path: String = "~/.gemini/settings.json") throws -> JSONValue {
        var out = json
        for (event, normalized, timeout) in events {
            var groups = stripOurs(try hookGroups(json, event: event, path: path))
            groups.append(.object(["matcher": .string("*"),
                                   "hooks": .array([.object(["type": .string("command"), "command": .string(command(relayPath, normalized)), "timeout": .number(Double(timeout))])])]))
            setHookGroups(&out, event: event, groups: groups)
        }
        return out
    }

    public static func uninstall(from json: JSONValue) -> JSONValue {
        var out = json
        if let hooks = json["hooks"].object {
            for (event, g) in hooks {
                guard let arr = g.array else { continue }
                setHookGroups(&out, event: event, groups: stripOurs(arr))
            }
            if out["hooks"].object?.isEmpty == true {
                var o = out.object ?? [:]
                o["hooks"] = nil
                out = .object(o)
            }
        }
        return out
    }

    public static func status(of json: JSONValue, relayPath: String) -> HookInstallStatus {
        var any = false, ok = true
        for (event, normalized, _) in events {
            let gs = (try? hookGroups(json, event: event, path: "")) ?? []
            guard let g = gs.first(where: containsMarker) else { ok = false; continue }
            any = true
            if g["hooks"][0]["command"].string != command(relayPath, normalized) { ok = false }
        }
        return !any ? .notInstalled : ok ? .installed : .outdated
    }
}
