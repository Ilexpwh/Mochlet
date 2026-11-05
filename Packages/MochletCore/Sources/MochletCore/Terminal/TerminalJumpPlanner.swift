import Foundation

/// One attempt at bringing the session's terminal forward. The app runs them in order until one succeeds.
public enum JumpStep: Equatable, Sendable {
    /// `tmux [-S socket] select-window -t pane && select-pane -t pane`, then carry on to the host.
    case tmux(socket: String?, pane: String)
    /// AppleScript returning `true` when it selected something.
    case appleScript(source: String, bundleID: String)
    /// A CLI (wezterm, kitten) found on PATH or in the usual folders.
    case command(name: String, args: [String], bundleID: String)
    /// Open a folder in an editor app and bring it forward.
    case openFolder(bundleID: String, path: String)
    /// Accessibility: raise the window of that app whose title contains the text.
    case raiseWindow(bundleID: String, titleContains: String)
    case activate(bundleID: String)
    case openTerminalApp
}

public enum TerminalJumpPlanner {
    public static let vscodeBundles = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium.codium"]
    public static let knownTerminals = ["com.apple.Terminal", "com.googlecode.iterm2", "net.kovidgoyal.kitty", "com.mitchellh.ghostty",
                                        "com.cmuxterm.app", "dev.warp.Warp-Stable", "com.github.wez.wezterm", "org.alacritty"]

    public static func plan(terminal t: TerminalIdentity, agent: AgentKind, cwd: String) -> [JumpStep] {
        var steps: [JumpStep] = []
        let ttyPath = t.tty.map { $0.hasPrefix("/dev/") ? $0 : "/dev/\($0)" }
        let host = t.terminalBundleID ?? t.bundleID ?? ""
        if let pane = t.tmuxPane, !pane.isEmpty { steps.append(.tmux(socket: t.tmuxSocket, pane: pane)) }
        if agent == .cursor || t.isCursor {
            steps.append(.openFolder(bundleID: AgentKind.cursorBundleID, path: cwd))
        } else if agent == .claudeDesktop {
            steps.append(.activate(bundleID: "com.anthropic.claudefordesktop"))
        } else if t.isVSCode {
            for b in vscodeBundles { steps.append(.openFolder(bundleID: b, path: cwd)) }
        }
        switch host {
        case "com.apple.Terminal":
            if let tty = ttyPath { steps.append(.appleScript(source: terminalAppScript(tty: tty), bundleID: host)) }
        case "com.googlecode.iterm2":
            if let id = t.itermSessionID { steps.append(.appleScript(source: itermScript(sessionID: id, tty: ttyPath), bundleID: host)) }
            else if let tty = ttyPath { steps.append(.appleScript(source: itermScript(sessionID: nil, tty: tty), bundleID: host)) }
        case "com.github.wez.wezterm":
            if let pane = t.weztermPane { steps.append(.command(name: "wezterm", args: ["cli", "activate-pane", "--pane-id", pane], bundleID: host)) }
        case "net.kovidgoyal.kitty":
            if let w = t.kittyWindowID { steps.append(.command(name: "kitten", args: ["@", "focus-window", "--match", "id:\(w)"], bundleID: host)) }
        case "com.mitchellh.ghostty":
            let base = (cwd as NSString).lastPathComponent
            if !base.isEmpty { steps.append(.raiseWindow(bundleID: host, titleContains: base)) }
        default:
            break
        }
        if t.ghostty, host != "com.mitchellh.ghostty" {
            let base = (cwd as NSString).lastPathComponent
            if !base.isEmpty { steps.append(.raiseWindow(bundleID: "com.mitchellh.ghostty", titleContains: base)) }
        }
        if !host.isEmpty { steps.append(.activate(bundleID: host)) }
        for b in knownTerminals where b != host { steps.append(.activate(bundleID: b)) }
        steps.append(.openTerminalApp)
        return steps
    }

    public static func terminalAppScript(tty: String) -> String {
        """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        set selected tab of w to t
                        set index of w to 1
                        activate
                        return true
                    end if
                end repeat
            end repeat
        end tell
        return false
        """
    }

    /// iTerm2: `ITERM_SESSION_ID` is `w0t1p0:<UUID>`; match the UUID, else the tty.
    public static func itermScript(sessionID: String?, tty: String?) -> String {
        let uuid = sessionID.map { $0.split(separator: ":").last.map(String.init) ?? $0 }
        var cond: [String] = []
        if let u = uuid, !u.isEmpty { cond.append("unique id of s is \"\(u)\"") }
        if let t = tty { cond.append("tty of s is \"\(t)\"") }
        let test = cond.isEmpty ? "false" : cond.joined(separator: " or ")
        return """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if \(test) then
                            tell w to select
                            tell t to select
                            tell s to select
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return false
        """
    }
}
