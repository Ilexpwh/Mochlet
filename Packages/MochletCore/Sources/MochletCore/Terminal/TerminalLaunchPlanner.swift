import Foundation

/// Terminals Mochlet can open a new window in.
public enum TerminalApp: String, CaseIterable, Sendable, Codable, Identifiable {
    case terminal, iterm, ghostty, warp, kitty, wezterm, alacritty

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .terminal: return "Terminal"
        case .iterm: return "iTerm2"
        case .ghostty: return "Ghostty"
        case .warp: return "Warp"
        case .kitty: return "kitty"
        case .wezterm: return "WezTerm"
        case .alacritty: return "Alacritty"
        }
    }

    public var bundleID: String {
        switch self {
        case .terminal: return "com.apple.Terminal"
        case .iterm: return "com.googlecode.iterm2"
        case .ghostty: return "com.mitchellh.ghostty"
        case .warp: return "dev.warp.Warp-Stable"
        case .kitty: return "net.kovidgoyal.kitty"
        case .wezterm: return "com.github.wez.wezterm"
        case .alacritty: return "org.alacritty"
        }
    }

    /// Command-line binary used to open a window, when the app is driven that way.
    public var binary: String? {
        switch self {
        case .kitty: return "kitty"
        case .wezterm: return "wezterm"
        case .alacritty: return "alacritty"
        default: return nil
        }
    }

    public init?(bundleID: String) {
        guard let t = Self.allCases.first(where: { $0.bundleID == bundleID }) else { return nil }
        self = t
    }
}

/// One step of opening a terminal; the app executes them in order and stops at the first success.
public enum LaunchStep: Equatable, Sendable {
    case appleScript(source: String, bundleID: String)
    case open(args: [String])
    case command(name: String, args: [String])
    case writeFile(path: String, contents: String)
}

/// The agent command line to run in the new window.
public struct AgentLaunch: Equatable, Sendable {
    public var agent: AgentKind
    public var task: String?
    public var resume: String?
    public var model: String?

    public init(agent: AgentKind, task: String? = nil, resume: String? = nil, model: String? = nil) {
        self.agent = agent
        self.task = task
        self.resume = resume
        self.model = model
    }

    /// e.g. `claude 'fix the tests'`, `codex resume 019…`, `gemini -i 'add a README'`.
    public var commandLine: String {
        let q = TerminalLaunchPlanner.shellQuote
        var parts: [String] = []
        switch agent {
        case .codex:
            parts.append("codex")
            if let resume, !resume.isEmpty { parts.append("resume"); parts.append(q(resume)) }
            if let model, !model.isEmpty { parts.append("-m"); parts.append(q(model)) }
            if let task, !task.isEmpty { parts.append(q(task)) }
        case .gemini:
            parts.append("gemini")
            if let model, !model.isEmpty { parts.append("-m"); parts.append(q(model)) }
            if let resume, !resume.isEmpty { parts.append("--resume"); parts.append(q(resume)) }
            if let task, !task.isEmpty { parts.append("-i"); parts.append(q(task)) }
        default:
            parts.append("claude")
            if let model, !model.isEmpty { parts.append("--model"); parts.append(q(model)) }
            if let resume, !resume.isEmpty { parts.append("--resume"); parts.append(q(resume)) }
            if let task, !task.isEmpty { parts.append(q(task)) }
        }
        return parts.joined(separator: " ")
    }
}

/// Opens a new terminal window in a folder running a command (and keeps a shell afterwards).
public enum TerminalLaunchPlanner {
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func appleScriptQuote(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// The shell line that enters the folder and runs the command.
    public static func shellLine(cwd: String, command: String) -> String {
        "cd \(shellQuote(cwd)) && \(command)"
    }

    /// For terminals that run a program instead of a shell: run it, then keep a login shell open.
    static func wrapped(cwd: String, command: String) -> [String] {
        ["sh", "-lc", "\(shellLine(cwd: cwd, command: command)); exec \"${SHELL:-/bin/zsh}\" -l"]
    }

    public static func plan(terminal: TerminalApp, cwd: String, command: String, title: String) -> [LaunchStep] {
        let line = shellLine(cwd: cwd, command: command)
        switch terminal {
        case .terminal:
            let src = """
            tell application "Terminal"
                activate
                do script "\(appleScriptQuote(line))"
            end tell
            """
            return [.appleScript(source: src, bundleID: terminal.bundleID)]
        case .iterm:
            let src = """
            tell application "iTerm"
                activate
                set newWindow to (create window with default profile)
                tell current session of newWindow
                    write text "\(appleScriptQuote(line))"
                end tell
            end tell
            """
            return [.appleScript(source: src, bundleID: terminal.bundleID)]
        case .ghostty:
            let w = wrapped(cwd: cwd, command: command)
            return [.open(args: ["-na", "Ghostty", "--args", "--working-directory=\(cwd)", "--title=\(title)", "-e"] + w)]
        case .warp:
            let name = "mochlet-" + Slug.make(title, maxLength: 40)
            let yaml = """
            ---
            name: \(name)
            windows:
              - tabs:
                  - title: \(yamlQuote(title))
                    layout:
                      cwd: \(yamlQuote(cwd))
                      commands:
                        - exec: \(yamlQuote(command))
            """
            let path = "~/.warp/launch_configurations/\(name).yaml"
            return [.writeFile(path: path, contents: yaml + "\n"), .open(args: ["warp://launch/\(name)"])]
        case .kitty:
            return [.command(name: "kitty", args: ["--directory", cwd, "--title", title] + wrapped(cwd: cwd, command: command))]
        case .wezterm:
            return [.command(name: "wezterm", args: ["start", "--cwd", cwd, "--"] + wrapped(cwd: cwd, command: command))]
        case .alacritty:
            return [.command(name: "alacritty", args: ["--working-directory", cwd, "--title", title, "-e"] + wrapped(cwd: cwd, command: command))]
        }
    }

    static func yamlQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
