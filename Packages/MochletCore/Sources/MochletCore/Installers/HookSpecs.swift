import Foundation

public enum HookInstallStatus: String, Sendable, Equatable {
    case notInstalled, installed, outdated
}

/// Marker every Mochlet hook command carries; removal strips only entries containing it.
public let hookMarker = "mochlet-hook"

func containsText(_ v: JSONValue, _ needle: String) -> Bool {
    switch v {
    case .string(let s): return s.contains(needle)
    case .array(let a): return a.contains { containsText($0, needle) }
    case .object(let o): return o.values.contains { containsText($0, needle) }
    default: return false
    }
}

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

// MARK: - Antigravity

/// Antigravity: `~/.gemini/config/hooks.json`, everything under our own top-level key.
public enum AntigravityHookSpec {
    public static let key = "mochlet"
    public static let toolEvents = ["PreToolUse", "PostToolUse"]
    public static let lifecycleEvents = ["PreInvocation", "PostInvocation", "Stop"]

    public static func command(_ relayPath: String, event: String) -> String { "\"\(relayPath)\" --agent antigravity \(event)" }

    public static func install(into json: JSONValue, relayPath: String, path: String) throws -> JSONValue {
        var root = json.isNull ? JSONValue.object([:]) : json
        guard root.object != nil else { throw ConfigFileError.unexpectedShape(path, "root") }
        var ours: [String: JSONValue] = [:]
        for e in toolEvents {
            ours[e] = .array([.object(["matcher": .string("*"), "hooks": .array([.object(["type": .string("command"), "command": .string(command(relayPath, event: e)), "timeout": .number(10)])])])])
        }
        for e in lifecycleEvents {
            ours[e] = .array([.object(["type": .string("command"), "command": .string(command(relayPath, event: e)), "timeout": .number(10)])])
        }
        root[key] = .object(ours)
        return root
    }

    public static func uninstall(from json: JSONValue) -> JSONValue {
        var root = json
        guard var o = root.object else { return root }
        o[key] = nil
        root = .object(o)
        return root
    }

    public static func status(of json: JSONValue, relayPath: String) -> HookInstallStatus {
        let ours = json[key]
        guard !ours.isNull else { return .notInstalled }
        return containsMarker(ours) && containsText(ours, relayPath) ? .installed : .outdated
    }
}

// MARK: - Copilot CLI

/// GitHub Copilot CLI: our own `~/.copilot/hooks/mochlet.json` (camelCase events, `bash` + `timeoutSec`).
public enum CopilotHookSpec {
    public static let events: [(String, Int)] = [
        ("sessionStart", 10), ("userPromptSubmitted", 10), ("preToolUse", 10), ("permissionRequest", 120),
        ("postToolUse", 10), ("agentStop", 10), ("sessionEnd", 3), ("notification", 10),
    ]

    public static func command(_ relayPath: String, event: String) -> String { "\"\(relayPath)\" --agent copilot \(event)" }

    public static func install(into json: JSONValue, relayPath: String, path: String) throws -> JSONValue {
        var root = json.isNull ? JSONValue.object([:]) : json
        guard root.object != nil else { throw ConfigFileError.unexpectedShape(path, "root") }
        var hooks = root["hooks"].object ?? [:]
        if !root["hooks"].isNull, root["hooks"].object == nil { throw ConfigFileError.unexpectedShape(path, "hooks") }
        for (event, timeout) in events {
            var entries = hooks[event]?.array ?? []
            entries.removeAll { ($0["bash"].string ?? "").contains(hookMarker) }
            entries.append(.object(["type": .string("command"), "bash": .string(command(relayPath, event: event)), "timeoutSec": .number(Double(timeout))]))
            hooks[event] = .array(entries)
        }
        root["hooks"] = .object(hooks)
        root["version"] = .number(1)
        return root
    }

    /// Returns nil when nothing but our entries remains (the file can be deleted).
    public static func uninstall(from json: JSONValue) -> JSONValue? {
        var root = json
        guard var hooks = root["hooks"].object else { return nil }
        for (k, v) in hooks {
            let kept = (v.array ?? []).filter { !($0["bash"].string ?? "").contains(hookMarker) }
            hooks[k] = kept.isEmpty ? nil : .array(kept)
        }
        if hooks.isEmpty { return nil }
        root["hooks"] = .object(hooks)
        return root
    }

    public static func status(of json: JSONValue, relayPath: String) -> HookInstallStatus {
        guard let hooks = json["hooks"].object, !hooks.isEmpty else { return .notInstalled }
        let ours = hooks.values.flatMap { $0.array ?? [] }.compactMap { $0["bash"].string }.filter { $0.contains(hookMarker) }
        if ours.isEmpty { return .notInstalled }
        return ours.count == events.count && ours.allSatisfy({ $0.contains(relayPath) }) ? .installed : .outdated
    }
}

// MARK: - Muse Code

/// Muse Code: `~/.config/muse/settings.json`, Claude-shaped hooks with `matcher: "*"` and ms timeouts.
public enum MuseHookSpec {
    public static let events: [(String, Int)] = [
        ("SessionStart", 10), ("UserPromptSubmit", 5), ("PreToolUse", 5), ("PermissionRequest", 120), ("PostToolUse", 5), ("Stop", 5), ("SessionEnd", 3),
    ]

    public static func command(_ relayPath: String, event: String) -> String { "\"\(relayPath)\" --agent muse \(event)" }

    public static func install(into json: JSONValue, relayPath: String, path: String) throws -> JSONValue {
        let isNew = json.isNull
        var root = isNew ? JSONValue.object([:]) : json
        guard root.object != nil else { throw ConfigFileError.unexpectedShape(path, "root") }
        if !root["hooks"].isNull, root["hooks"].object == nil { throw ConfigFileError.unexpectedShape(path, "hooks") }
        for (event, seconds) in events {
            var groups = stripOurs(try hookGroups(root, event: event, path: path))
            groups.append(.object(["matcher": .string("*"), "hooks": .array([.object(["type": .string("command"), "command": .string(command(relayPath, event: event)), "timeout": .number(Double(seconds * 1000))])])]))
            setHookGroups(&root, event: event, groups: groups)
        }
        if isNew { root["schema_version"] = .number(1) }
        return root
    }

    public static func uninstall(from json: JSONValue) -> JSONValue {
        var root = json
        guard let hooks = root["hooks"].object else { return root }
        for (event, v) in hooks {
            setHookGroups(&root, event: event, groups: stripOurs(v.array ?? []))
        }
        if root["hooks"].object?.isEmpty == true { var o = root.object ?? [:]; o["hooks"] = nil; root = .object(o) }
        return root
    }

    public static func status(of json: JSONValue, relayPath: String) -> HookInstallStatus {
        guard let hooks = json["hooks"].object else { return .notInstalled }
        var found = 0
        var current = true
        for (event, _) in events {
            let cmds = (hooks[event]?.array ?? []).flatMap { ($0["hooks"].array ?? []) }.compactMap { $0["command"].string }.filter { $0.contains(hookMarker) }
            if cmds.isEmpty { continue }
            found += 1
            if !cmds.allSatisfy({ $0.contains(relayPath) }) { current = false }
        }
        if found == 0 { return .notInstalled }
        return found == events.count && current ? .installed : .outdated
    }
}

// MARK: - Generated plugin files (OpenCode, Amp, Hermes)

/// A plugin file Mochlet writes whole: installed when it exists with our header and the current relay path.
public struct GeneratedPluginFile: Sendable, Equatable {
    public static let header = "generated by Mochlet"
    public var relativePath: String
    public var contents: String

    public static func status(existing: String?, relayPath: String) -> HookInstallStatus {
        guard let existing, existing.contains(header) || existing.contains(hookMarker) else { return .notInstalled }
        return existing.contains(relayPath) ? .installed : .outdated
    }

    /// Only files we generated are ever deleted.
    public static func isOurs(_ contents: String) -> Bool { contents.contains(header) }

    static func jsQuote(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }
}

public enum OpenCodePluginSpec {
    public static let relativePath = ".config/opencode/plugins/mochlet.js"

    public static func contents(relayPath: String) -> String {
        """
        // Mochlet hook plugin for OpenCode — \(GeneratedPluginFile.header). Safe to delete.
        // Forwards session and tool events to the Mochlet notch (fire-and-forget, never blocks).
        import { spawn } from 'node:child_process';

        const HOOK = '\(GeneratedPluginFile.jsQuote(relayPath))';
        const EVENT_MAP = {
          'session.created': 'SessionStart',
          'session.idle': 'Stop',
          'session.error': 'StopFailure',
          'session.deleted': 'SessionEnd',
          'permission.asked': 'PermissionRequest',
        };

        function forward(hook_event_name, payload) {
          try {
            const p = spawn(HOOK, ['--agent', 'opencode', hook_event_name], { stdio: ['pipe', 'ignore', 'ignore'], detached: true });
            p.on('error', () => {});
            p.stdin.on('error', () => {});
            p.stdin.write(JSON.stringify({ hook_event_name, ...payload }) + '\\n');
            p.stdin.end();
            p.unref();
          } catch (_) {}
        }

        export const MochletPlugin = async (_ctx) => ({
          event: async ({ event }) => {
            const hook_event_name = EVENT_MAP[event.type];
            if (!hook_event_name) return;
            const props = event.properties || {};
            const payload = {
              session_id: event.sessionID || event.session_id || props.sessionID || props.session_id || '',
              cwd: event.cwd || event.directory || props.cwd || props.directory || '',
            };
            if (typeof props.tool === 'string') payload.tool_name = props.tool;
            if (props.input != null) payload.tool_input = props.input;
            if (typeof props.error === 'string') payload.error = props.error;
            forward(hook_event_name, payload);
          },
          'tool.execute.before': async (input) => {
            forward('PreToolUse', {
              session_id: input.sessionID || input.session_id || '',
              cwd: input.cwd || '',
              tool_name: typeof input.tool === 'string' ? input.tool : '',
              tool_input: input.input ?? null,
            });
          },
          'tool.execute.after': async (input, _output) => {
            forward('PostToolUse', {
              session_id: input.sessionID || input.session_id || '',
              cwd: input.cwd || '',
              tool_name: typeof input.tool === 'string' ? input.tool : '',
            });
          },
        });
        """
    }
}

public enum AmpPluginSpec {
    public static let relativePath = ".config/amp/plugins/mochlet.ts"

    public static func contents(relayPath: String) -> String {
        """
        // Mochlet hook plugin for Amp — \(GeneratedPluginFile.header). Safe to delete.
        // Forwards every event to the Mochlet notch (display only, never blocks).
        import { spawn } from 'node:child_process';

        const HOOK = '\(GeneratedPluginFile.jsQuote(relayPath))';

        function forward(event_name: string, fields: Record<string, unknown>): void {
          try {
            const payload = JSON.stringify({ hook_event_name: event_name, ...fields });
            const p = spawn(HOOK, ['--agent', 'amp', event_name], { stdio: ['pipe', 'ignore', 'ignore'], detached: true });
            p.on('error', () => {});
            (p.stdin as import('node:stream').Writable).on('error', () => {});
            (p.stdin as import('node:stream').Writable).write(payload + '\\n');
            (p.stdin as import('node:stream').Writable).end();
            p.unref();
          } catch (_) {}
        }

        export default function (amp: any): void {
          amp.on('session.start', (e: any) => { forward('SessionStart', { session_id: e.thread?.id ?? '', cwd: e.cwd ?? '' }); });
          amp.on('agent.start', (e: any) => { forward('UserPromptSubmit', { session_id: e.thread?.id ?? '', prompt: e.prompt ?? '' }); });
          amp.on('tool.call', (e: any) => { try { forward('PreToolUse', { session_id: e.thread?.id ?? '', tool_name: typeof e.tool === 'string' ? e.tool : '', tool_input: e.input ?? null }); } finally { return { action: 'allow' }; } });
          amp.on('tool.result', (e: any) => { forward('PostToolUse', { session_id: e.thread?.id ?? '', tool_name: typeof e.tool === 'string' ? e.tool : '' }); });
          amp.on('agent.end', (e: any) => { forward('Stop', { session_id: e.thread?.id ?? '', last_assistant_message: e.message ?? '' }); });
        }
        """
    }
}

public enum HermesPluginSpec {
    public static let directory = ".hermes/plugins/mochlet"
    public static let initPath = ".hermes/plugins/mochlet/__init__.py"
    public static let yamlPath = ".hermes/plugins/mochlet/plugin.yaml"

    public static let pluginYAML = """
    name: mochlet
    version: "1.0"
    description: Mochlet notch integration (\(GeneratedPluginFile.header))
    """

    public static func initPy(relayPath: String) -> String {
        """
        # Mochlet hook plugin for Hermes Agent — \(GeneratedPluginFile.header). Safe to delete.
        # Session/tool events go to the Mochlet notch (fire-and-forget). Approvals use
        # register_approval_transport when Hermes exposes it, else an observer hook.
        import json, subprocess, threading

        HOOK = '\(GeneratedPluginFile.jsQuote(relayPath))'
        _lock = threading.Lock()
        _current_session_id = ''


        def _fire(fields):
            def _run():
                try:
                    p = subprocess.Popen([HOOK, '--agent', 'hermes', fields.get('hook_event_name', '')],
                                         stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                         start_new_session=True)
                    p.stdin.write(json.dumps(fields).encode() + b'\\n')
                    p.stdin.close()
                    p.wait(timeout=5)
                except Exception:
                    pass
            threading.Thread(target=_run, daemon=True).start()


        def register(ctx):
            def on_session_start(**kw):
                global _current_session_id
                sid = kw.get('session_id', '')
                with _lock:
                    _current_session_id = sid
                _fire({'hook_event_name': 'SessionStart', 'session_id': sid, 'platform': kw.get('platform', 'cli') or 'cli', 'cwd': kw.get('cwd', '')})

            def on_session_end(**kw):
                sid = kw.get('session_id', '') or _current_session_id
                _fire({'hook_event_name': 'StopFailure' if kw.get('interrupted') else 'SessionEnd', 'session_id': sid})

            def post_llm_call(**kw):
                sid = kw.get('session_id', '') or _current_session_id
                _fire({'hook_event_name': 'Stop', 'session_id': sid, 'last_assistant_message': kw.get('assistant_response', '')})

            def pre_tool_call(**kw):
                sid = kw.get('session_id', '') or _current_session_id
                _fire({'hook_event_name': 'PreToolUse', 'session_id': sid, 'tool_name': kw.get('tool_name', ''), 'tool_input': kw.get('args') or {}})

            def post_tool_call(**kw):
                sid = kw.get('session_id', '') or _current_session_id
                _fire({'hook_event_name': 'PostToolUse', 'session_id': sid, 'tool_name': kw.get('tool_name', '')})

            ctx.register_hook('on_session_start', on_session_start)
            ctx.register_hook('on_session_end', on_session_end)
            ctx.register_hook('post_llm_call', post_llm_call)
            ctx.register_hook('pre_tool_call', pre_tool_call)
            ctx.register_hook('post_tool_call', post_tool_call)

            if hasattr(ctx, 'register_approval_transport'):
                def _present(request):
                    sid = getattr(request, 'session_id', None) or getattr(request, 'session_key', None) or _current_session_id
                    cmd = getattr(request, 'command', '')
                    timeout = getattr(request, 'timeout_seconds', getattr(request, 'timeout', 30.0))
                    allowed = list(getattr(request, 'allowed_choices', ('once', 'deny')))
                    payload = json.dumps({'hook_event_name': 'PermissionRequest', 'session_id': sid, 'tool_name': 'Bash',
                                          'tool_input': {'command': cmd, 'description': getattr(request, 'description', '')}}).encode()
                    try:
                        result = subprocess.run([HOOK, '--agent', 'hermes', 'PermissionRequest'], input=payload, capture_output=True,
                                                timeout=max(1.0, float(timeout) - 2.0))
                        choice = json.loads(result.stdout)['choice']
                        if choice not in allowed:
                            raise ValueError(choice)
                        return request.respond(choice)
                    except Exception:
                        return request.respond('deny')
                ctx.register_approval_transport('mochlet', _present)
            else:
                def pre_approval_request(**kw):
                    sid = kw.get('session_key', '') or _current_session_id
                    _fire({'hook_event_name': 'PreToolUse', 'session_id': sid, 'tool_name': 'Approval pending in Hermes',
                           'tool_input': {'command': kw.get('command', ''), 'description': kw.get('description', '')}})
                ctx.register_hook('pre_approval_request', pre_approval_request)
        """
    }
}
