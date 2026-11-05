import AppKit
import ApplicationServices
import MochletCore

/// Executes `TerminalJumpPlanner` steps until one brings the session's terminal forward.
@MainActor
final class TerminalJumper {
    private unowned let app: AppCoordinator
    private(set) var lastResult = ""

    init(app: AppCoordinator) {
        self.app = app
    }

    @discardableResult
    func jump(to card: SessionCard?) -> Bool {
        guard let card else {
            NSSound.beep()
            return false
        }
        let steps = TerminalJumpPlanner.plan(terminal: card.terminal, agent: card.agent, cwd: card.cwd)
        for step in steps {
            if run(step) {
                lastResult = "\(step)"
                return true
            }
        }
        lastResult = "no terminal found"
        return false
    }

    private func run(_ step: JumpStep) -> Bool {
        switch step {
        case .tmux(let socket, let pane):
            var args: [String] = []
            if let socket { args += ["-S", socket] }
            _ = shell("tmux", args + ["select-window", "-t", pane])
            _ = shell("tmux", args + ["select-pane", "-t", pane])
            return false // keep going to the host app
        case .appleScript(let source, let bundleID):
            guard isRunning(bundleID) else { return false }
            var error: NSDictionary?
            let script = NSAppleScript(source: source)
            let result = script?.executeAndReturnError(&error)
            if let error { MochletLogger(category: "terminal").error("jump applescript: \(error)") }
            return result?.booleanValue == true
        case .command(let name, let args, let bundleID):
            guard isRunning(bundleID) else { return false }
            let ok = shell(name, args)
            if ok { activate(bundleID) }
            return ok
        case .openFolder(let bundleID, let path):
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
            if !path.isEmpty, FileManager.default.fileExists(atPath: path) {
                NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
                return true
            }
            return activate(bundleID)
        case .raiseWindow(let bundleID, let title):
            return raise(bundleID: bundleID, titleContains: title)
        case .activate(let bundleID):
            return activate(bundleID)
        case .openTerminalApp:
            let url = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            return true
        }
    }

    private func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    @discardableResult
    private func activate(_ bundleID: String) -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return false }
        return app.activate(options: [.activateIgnoringOtherApps])
    }

    private func shell(_ name: String, _ args: [String]) -> Bool {
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/Applications/WezTerm.app/Contents/MacOS", "/Applications/kitty.app/Contents/MacOS",
                    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path]
        guard let path = dirs.map({ "\($0)/\(name)" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch { return false }
        let deadline = Date().addingTimeInterval(2)
        while p.isRunning, Date() < deadline { usleep(10_000) }
        if p.isRunning { p.terminate(); return false }
        return p.terminationStatus == 0
    }

    /// Accessibility: raise the window whose title contains the text. Needs the Accessibility permission.
    private func raise(bundleID: String, titleContains needle: String) -> Bool {
        guard AXIsProcessTrusted(), let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return false }
        let axApp = AXUIElementCreateApplication(running.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success, let windows = value as? [AXUIElement] else { return false }
        for w in windows {
            var t: CFTypeRef?
            guard AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t) == .success, let title = t as? String, title.localizedCaseInsensitiveContains(needle) else { continue }
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            running.activate(options: [.activateIgnoringOtherApps])
            return true
        }
        return false
    }
}
