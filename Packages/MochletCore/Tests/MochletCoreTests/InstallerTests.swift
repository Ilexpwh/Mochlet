import Foundation
import Testing
@testable import MochletCore

@Suite struct ClaudeHookSpecTests {
    let relay = "/Users/me/Library/Application Support/Mochlet/bin/mochlet-hook"

    @Test func installChainsStatusLineAndIsIdempotent() throws {
        let original = JSONValue.parse(Data(#"{"model":"opus","statusLine":{"type":"command","command":"bash ~/.claude/statusline-command.sh","padding":0},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#.utf8))!
        let (first, previous) = try ClaudeHookSpec.install(into: original, relayPath: relay)
        #expect(previous?["command"].string == "bash ~/.claude/statusline-command.sh")
        #expect(first["statusLine"]["command"].string == "\"\(relay)\" --statusline" && first["statusLine"]["padding"].int == 0)
        #expect(first["model"].string == "opus")
        let stop = first["hooks"]["Stop"].array!
        #expect(stop.count == 2 && stop[0]["hooks"][0]["command"].string == "say done")
        #expect(first["hooks"]["PermissionRequest"][0]["hooks"][0]["timeout"].int == 120)
        let pre = first["hooks"]["PreToolUse"].array!
        #expect(pre.count == 2 && pre[1]["matcher"].string == "AskUserQuestion" && pre[1]["hooks"][0]["command"].string!.hasSuffix("--ask"))
        #expect(ClaudeHookSpec.status(of: first, relayPath: relay) == .installed)
        let (second, previous2) = try ClaudeHookSpec.install(into: first, relayPath: relay)
        #expect(second == first && previous2 == nil)
        let restored = try ClaudeHookSpec.uninstall(from: second, previousStatusLine: previous)
        #expect(restored["statusLine"] == original["statusLine"])
        #expect(restored["hooks"]["Stop"].array?.count == 1 && restored["hooks"]["PreToolUse"].isNull)
        #expect(ClaudeHookSpec.status(of: restored, relayPath: relay) == .notInstalled)
    }

    @Test func outdatedWhenPathMoves() throws {
        let (json, _) = try ClaudeHookSpec.install(into: .object([:]), relayPath: "/old/mochlet-hook")
        #expect(ClaudeHookSpec.status(of: json, relayPath: relay) == .outdated)
        let (json2, prev) = try ClaudeHookSpec.install(into: json, relayPath: relay)
        #expect(prev == nil && ClaudeHookSpec.status(of: json2, relayPath: relay) == .installed)
        #expect(json2["hooks"]["Stop"].array?.count == 1)
    }

    @Test func uninstallWithoutPreviousDropsStatusLine() throws {
        let (json, _) = try ClaudeHookSpec.install(into: .object([:]), relayPath: relay)
        let out = try ClaudeHookSpec.uninstall(from: json, previousStatusLine: nil)
        #expect(out["statusLine"].isNull && out["hooks"].object?.isEmpty == true)
    }

    @Test func wrongShapeRefuses() {
        let json = JSONValue.parse(Data(#"{"hooks":{"Stop":"nope"}}"#.utf8))!
        #expect(throws: ConfigFileError.self) { _ = try ClaudeHookSpec.install(into: json, relayPath: relay) }
    }
}

@Suite struct CodexGeminiSpecTests {
    let relay = "/x/mochlet-hook"

    @Test func codexRoundTrip() throws {
        let json = try CodexHookSpec.install(into: .object([:]), relayPath: relay)
        #expect(CodexHookSpec.status(of: json, relayPath: relay) == .installed)
        #expect(json["hooks"]["PermissionRequest"][0]["hooks"][0]["statusMessage"].string == CodexHookSpec.waitingMessage)
        #expect(json["hooks"]["Interrupt"][0]["hooks"][0]["timeout"].int == 3)
        #expect(CodexHookSpec.groupIndex(in: json, event: "SessionStart") == 0)
        let toml = "[hooks.state.\"/Users/me/.codex/hooks.json:session_start:0:0\"]\ntrusted_hash = \"sha256:abc\"\n"
        #expect(CodexHookSpec.isTrusted(configTOML: toml, hooksPath: "/Users/me/.codex/hooks.json", sessionStartGroup: 0))
        #expect(!CodexHookSpec.isTrusted(configTOML: toml, hooksPath: "/Users/me/.codex/hooks.json", sessionStartGroup: 1))
        let out = CodexHookSpec.uninstall(from: json)
        #expect(out == .object([:]))
    }

    @Test func geminiKeepsOtherHooks() throws {
        let original = JSONValue.parse(Data(#"{"ui":{"theme":"GitHub"},"hooks":{"BeforeTool":[{"matcher":"*","hooks":[{"type":"command","command":"mine"},{"type":"command","command":"/bin/sh \"/old/mochlet-hook\" --agent gemini PreToolUse"}]}]}}"#.utf8))!
        let json = try GeminiHookSpec.install(into: original, relayPath: relay)
        let before = json["hooks"]["BeforeTool"].array!
        #expect(before.count == 2 && before[0]["hooks"].array?.count == 1 && before[1]["hooks"][0]["timeout"].int == 5000)
        #expect(GeminiHookSpec.status(of: json, relayPath: relay) == .installed)
        #expect(GeminiHookSpec.status(of: original, relayPath: relay) == .outdated)
        let out = GeminiHookSpec.uninstall(from: json)
        #expect(out["hooks"]["BeforeTool"][0]["hooks"].array?.count == 1 && out["ui"]["theme"].string == "GitHub")
    }
}

@Suite struct ConfigFileTests {
    @Test func writeRefusesWhenChangedAndKeepsBackup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mochlet-cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")
        let (json0, bytes0) = try ConfigFile.read(url)
        #expect(json0 == .object([:]) && bytes0 == nil)
        let backup0 = try ConfigFile.write(ConfigFile.serialize(.object(["a": .number(1)])), to: url, expecting: nil)
        #expect(backup0 == nil)
        let (json1, bytes1) = try ConfigFile.read(url)
        #expect(json1["a"].int == 1 && bytes1 != nil)
        try Data("{\"a\": 2}".utf8).write(to: url)
        #expect(throws: ConfigFileError.self) { try ConfigFile.write(Data("{}".utf8), to: url, expecting: bytes1) }
        let (_, bytes2) = try ConfigFile.read(url)
        let backup = try ConfigFile.write(ConfigFile.serialize(.object(["a": .number(3)])), to: url, expecting: bytes2, now: Date(timeIntervalSince1970: 0))
        #expect(backup?.lastPathComponent.hasPrefix("settings.json.bak-") == true)
        #expect(try Data(contentsOf: backup!) == bytes2)
        try Data("   \n".utf8).write(to: url)
        #expect(try ConfigFile.read(url).json == .object([:]))
        try Data("[1]".utf8).write(to: url)
        #expect(throws: ConfigFileError.self) { _ = try ConfigFile.read(url) }
    }
}

@Suite struct TerminalJumpPlannerTests {
    @Test func itermWithTmux() {
        let t = TerminalIdentity(termProgram: "iTerm.app", itermSessionID: "w0t1p0:ABCD", tmuxPane: "%3", tmuxSocket: "/tmp/tmux-501/default", bundleID: "com.googlecode.iterm2", tty: "ttys004")
        let steps = TerminalJumpPlanner.plan(terminal: t, agent: .claude, cwd: "/p/x")
        #expect(steps.first == .tmux(socket: "/tmp/tmux-501/default", pane: "%3"))
        guard case .appleScript(let src, let b) = steps[1] else { Issue.record("no applescript"); return }
        #expect(b == "com.googlecode.iterm2" && src.contains("unique id of s is \"ABCD\"") && src.contains("/dev/ttys004"))
        #expect(steps.contains(.activate(bundleID: "com.googlecode.iterm2")) && steps.last == .openTerminalApp)
    }

    @Test func cursorAndGhostty() {
        let c = TerminalJumpPlanner.plan(terminal: TerminalIdentity(bundleID: AgentKind.cursorBundleID), agent: .claude, cwd: "/p/x")
        #expect(c.first == .openFolder(bundleID: AgentKind.cursorBundleID, path: "/p/x"))
        let g = TerminalJumpPlanner.plan(terminal: TerminalIdentity(termProgram: "ghostty", ghostty: true, bundleID: "com.mitchellh.ghostty"), agent: .codex, cwd: "/p/x")
        #expect(g.first == .raiseWindow(bundleID: "com.mitchellh.ghostty", titleContains: "x"))
        let ta = TerminalJumpPlanner.plan(terminal: TerminalIdentity(termProgram: "Apple_Terminal", tty: "/dev/ttys001"), agent: .claude, cwd: "")
        guard case .appleScript(let src, _) = ta.first! else { Issue.record("no applescript"); return }
        #expect(src.contains("tty of t is \"/dev/ttys001\""))
    }
}
