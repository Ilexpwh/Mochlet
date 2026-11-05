import Foundation

/// Which coding agent sent a hook. `generic(name)` carries any other `--agent` tag.
public enum AgentKind: Sendable, Equatable, Hashable, Codable {
    case claude, codex, gemini, antigravity, copilot, muse, opencode, amp, hermes, cursor, claudeDesktop
    case generic(String)

    /// `^[a-z0-9-]{1,24}$`
    public static func isValidTag(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 24 && s.allSatisfy { ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == "-" }
    }

    public init(tag: String?, bundleID: String?, termProgram: String?) {
        if let tag, !tag.isEmpty, tag != "claude" {
            switch tag {
            case "codex": self = .codex
            case "gemini": self = .gemini
            case "antigravity": self = .antigravity
            case "copilot": self = .copilot
            case "muse": self = .muse
            case "opencode": self = .opencode
            case "amp": self = .amp
            case "hermes": self = .hermes
            case "cursor": self = .cursor
            case "claude-desktop": self = .claudeDesktop
            default: self = Self.isValidTag(tag) ? .generic(tag) : .claude
            }
            return
        }
        if bundleID?.lowercased() == Self.cursorBundleID { self = .cursor; return }
        self = .claude
    }

    public static let cursorBundleID = "com.todesktop.230313mzl4w4u92"

    public var id: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .gemini: return "gemini"
        case .antigravity: return "antigravity"
        case .copilot: return "copilot"
        case .muse: return "muse"
        case .opencode: return "opencode"
        case .amp: return "amp"
        case .hermes: return "hermes"
        case .cursor: return "cursor"
        case .claudeDesktop: return "claude-desktop"
        case .generic(let n): return n
        }
    }

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Gemini CLI"
        case .antigravity: return "Antigravity"
        case .copilot: return "Copilot CLI"
        case .muse: return "Muse Code"
        case .opencode: return "OpenCode"
        case .amp: return "Amp"
        case .hermes: return "Hermes"
        case .cursor: return "Cursor"
        case .claudeDesktop: return "Claude Desktop"
        case .generic(let n): return n.prefix(1).uppercased() + n.dropFirst()
        }
    }

    /// One-glyph badge next to a mini slime's label.
    public var glyph: String {
        switch self {
        case .claude, .claudeDesktop: return "✳"
        case .codex: return "◎"
        case .gemini, .antigravity: return "✦"
        case .copilot: return "⌘"
        case .cursor: return "▮"
        default: return "•"
        }
    }

    /// Agents whose permission hook must always receive JSON (an empty reply is an error for them).
    public var failsClosed: Bool {
        switch self {
        case .gemini, .antigravity, .muse, .copilot: return true
        default: return false
        }
    }

    /// Agents that cannot express "always allow" (Codex has no such option).
    public var supportsAlways: Bool {
        switch self {
        case .codex, .copilot, .muse: return false
        default: return true
        }
    }
}

/// Normalised hook names (Claude Code's vocabulary; other agents are mapped onto it).
public enum HookEventName: String, Sendable, Codable, CaseIterable {
    case sessionStart = "SessionStart"
    case sessionEnd = "SessionEnd"
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case postToolUseFailure = "PostToolUseFailure"
    case notification = "Notification"
    case stop = "Stop"
    case stopFailure = "StopFailure"
    case subagentStart = "SubagentStart"
    case subagentStop = "SubagentStop"
    case preCompact = "PreCompact"
    case interrupt = "Interrupt"
    case permissionRequest = "PermissionRequest"
    case askUserQuestion = "AskUserQuestion"
    case statusLine = "StatusLine"
    case unknown = "Unknown"

    /// Maps every agent's raw event name onto the normalised vocabulary.
    public static func normalise(_ raw: String) -> HookEventName {
        switch raw {
        case "BeforeTool", "BeforeToolSelection", "pre_tool_use", "preToolUse", "PreToolUse": return .preToolUse
        case "AfterTool", "AfterModel", "PostInvocation", "post_tool_use", "postToolUse", "PostToolUse": return .postToolUse
        case "PostToolUseFailure", "postToolUseFailure", "post_tool_use_failure": return .postToolUseFailure
        case "BeforeAgent", "PreInvocation", "user_prompt_submit", "userPromptSubmitted", "beforeSubmitPrompt", "UserPromptSubmit": return .userPromptSubmit
        case "AfterAgent", "stop", "agentStop", "Stop": return .stop
        case "StopFailure", "stopFailure": return .stopFailure
        case "startup", "session_start", "sessionStart", "SessionStart": return .sessionStart
        case "exit", "session_end", "sessionEnd", "SessionEnd": return .sessionEnd
        case "notification", "Notification": return .notification
        case "permissionRequest", "PermissionRequest": return .permissionRequest
        case "SubagentStart", "subagentStart": return .subagentStart
        case "SubagentStop", "subagentStop": return .subagentStop
        case "PreCompact", "preCompact": return .preCompact
        case "Interrupt", "interrupt": return .interrupt
        case "AskUserQuestion": return .askUserQuestion
        default: return .unknown
        }
    }
}

/// Everything the relay could learn about the terminal the agent runs in.
public struct TerminalIdentity: Sendable, Equatable, Hashable, Codable {
    public var termProgram: String?
    public var termSessionID: String?
    public var itermSessionID: String?
    public var weztermPane: String?
    public var kittyWindowID: String?
    public var ghostty: Bool
    public var tmuxPane: String?
    public var tmuxSocket: String?
    public var bundleID: String?
    public var tty: String?
    public var shellPID: Int?
    public var claudeEntrypoint: String?
    public var vscodeIPC: Bool

    public init(termProgram: String? = nil, termSessionID: String? = nil, itermSessionID: String? = nil, weztermPane: String? = nil,
                kittyWindowID: String? = nil, ghostty: Bool = false, tmuxPane: String? = nil, tmuxSocket: String? = nil,
                bundleID: String? = nil, tty: String? = nil, shellPID: Int? = nil, claudeEntrypoint: String? = nil, vscodeIPC: Bool = false) {
        self.termProgram = termProgram
        self.termSessionID = termSessionID
        self.itermSessionID = itermSessionID
        self.weztermPane = weztermPane
        self.kittyWindowID = kittyWindowID
        self.ghostty = ghostty
        self.tmuxPane = tmuxPane
        self.tmuxSocket = tmuxSocket
        self.bundleID = bundleID
        self.tty = tty
        self.shellPID = shellPID
        self.claudeEntrypoint = claudeEntrypoint
        self.vscodeIPC = vscodeIPC
    }

    public init(json: JSONValue) {
        func s(_ k: String) -> String? { let v = json[k].string; return (v?.isEmpty ?? true) ? nil : v }
        self.init(termProgram: s("term_program"), termSessionID: s("term_session_id"), itermSessionID: s("iterm_session_id"),
                  weztermPane: s("wezterm_pane"), kittyWindowID: s("kitty_window_id"), ghostty: json["ghostty"].bool ?? (s("ghostty") != nil),
                  tmuxPane: s("tmux_pane"), tmuxSocket: s("tmux_socket"), bundleID: s("bundle_id"), tty: s("tty"),
                  shellPID: json["shell_pid"].int, claudeEntrypoint: s("claude_entrypoint"), vscodeIPC: json["vscode_ipc"].bool ?? (s("vscode_ipc") != nil))
    }

    public var isVSCode: Bool {
        vscodeIPC || (termProgram?.lowercased().contains("vscode") ?? false) || (bundleID?.lowercased().contains("vscode") ?? false)
    }
    public var isCursor: Bool { bundleID?.lowercased() == AgentKind.cursorBundleID }

    /// Known terminal apps by bundle id and by TERM_PROGRAM.
    public static let terminalsByBundle: [String: String] = [
        "dev.warp.Warp-Stable": "Warp", "dev.warp.Warp-Preview": "Warp", "com.apple.Terminal": "Terminal",
        "com.googlecode.iterm2": "iTerm", "com.mitchellh.ghostty": "Ghostty", "net.kovidgoyal.kitty": "kitty",
        "org.alacritty": "Alacritty", "com.github.wez.wezterm": "WezTerm", "co.zeit.hyper": "Hyper", "dev.zed.Zed": "Zed",
        "com.cmuxterm.app": "cmux", "com.stablyai.orca": "Orca", "com.conductor.app": "Conductor",
    ]
    public static let terminalsByProgram: [String: String] = [
        "warpterminal": "dev.warp.Warp-Stable", "apple_terminal": "com.apple.Terminal", "iterm.app": "com.googlecode.iterm2",
        "ghostty": "com.mitchellh.ghostty", "kitty": "net.kovidgoyal.kitty", "alacritty": "org.alacritty",
        "wezterm": "com.github.wez.wezterm", "hyper": "co.zeit.hyper", "zed": "dev.zed.Zed",
    ]

    /// Bundle id of the hosting terminal, if known.
    public var terminalBundleID: String? {
        if let b = bundleID, Self.terminalsByBundle[b] != nil { return b }
        if let p = termProgram?.lowercased(), let b = Self.terminalsByProgram[p] { return b }
        return nil
    }

    public var terminalName: String? {
        terminalBundleID.flatMap { Self.terminalsByBundle[$0] }
    }
}

/// One normalised hook event.
public struct HookEvent: Sendable, Equatable, Codable {
    public var name: HookEventName
    public var rawName: String
    public var agent: AgentKind
    public var sessionID: String
    public var cwd: String
    public var sessionRoot: String?
    public var sessionTitle: String?
    public var tool: String?
    public var toolInput: JSONValue
    public var toolResponse: JSONValue
    public var prompt: String?
    public var message: String?
    public var lastAssistantMessage: String?
    public var transcriptPath: String?
    public var terminal: TerminalIdentity
    public var raw: JSONValue
    public var receivedAt: Date

    public init(name: HookEventName, rawName: String, agent: AgentKind, sessionID: String, cwd: String, sessionRoot: String? = nil,
                sessionTitle: String? = nil, tool: String? = nil, toolInput: JSONValue = .null, toolResponse: JSONValue = .null,
                prompt: String? = nil, message: String? = nil, lastAssistantMessage: String? = nil, transcriptPath: String? = nil,
                terminal: TerminalIdentity = TerminalIdentity(), raw: JSONValue = .null, receivedAt: Date = Date()) {
        self.name = name
        self.rawName = rawName
        self.agent = agent
        self.sessionID = sessionID
        self.cwd = cwd
        self.sessionRoot = sessionRoot
        self.sessionTitle = sessionTitle
        self.tool = tool
        self.toolInput = toolInput
        self.toolResponse = toolResponse
        self.prompt = prompt
        self.message = message
        self.lastAssistantMessage = lastAssistantMessage
        self.transcriptPath = transcriptPath
        self.terminal = terminal
        self.raw = raw
        self.receivedAt = receivedAt
    }

    /// Project name shown on the card: the session title, else the root/cwd folder name.
    public var projectName: String {
        if let t = sessionTitle, !t.isEmpty { return t }
        let base = (sessionRoot?.isEmpty == false ? sessionRoot! : cwd)
        let name = (base as NSString).lastPathComponent
        return name.isEmpty ? "Session" : name
    }

    /// `tool_input` serialised with sorted keys: the identity of an approval.
    public var toolInputKey: String {
        toolInput.isEmptyish ? "" : String(decoding: toolInput.data(), as: UTF8.self)
    }
}
