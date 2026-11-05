import AppKit
import ApplicationServices
import Foundation
import MochletCore
import MochletServices

/// Polls every 5 s for a call: who holds the microphone (Core Audio), which app is in front, and its
/// window title or browser URL. Two polls in a row with the same detection → the controller is offered
/// the meeting. While recording, the microphone being released for 60 s stops the recording.
@MainActor
final class MeetingDetector {
    private unowned let app: AppCoordinator
    private var timer: Timer?
    private var pending: MeetingDetectionRules.Detection?
    private var pendingSince: Date?
    private var micIdleSince: Date?
    private(set) var lastSignal: MeetingDetectionRules.Signal?
    private(set) var lastDetection: MeetingDetectionRules.Detection?

    init(app: AppCoordinator) { self.app = app }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in Task { @MainActor in self?.poll() } }
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// What the detector sees right now (debug and the Settings status line).
    func signal() -> MeetingDetectionRules.Signal {
        let me = ProcessInfo.processInfo.processIdentifier
        let micApps = MicUsageMonitor.processesUsingInput().filter { $0.pid != me && !$0.bundleID.isEmpty }.map(\.bundleID)
        let front = NSWorkspace.shared.frontmostApplication
        let frontID = front?.bundleIdentifier
        var title: String?
        var url: String?
        if let frontID, micApps.contains(frontID) || MeetingDetectionRules.known(frontID) != nil {
            title = Self.focusedWindowTitle(pid: front?.processIdentifier)
            if micApps.contains(frontID), let script = WindowContextCapture.browserScripts[frontID] {
                var error: NSDictionary?
                if let r = NSAppleScript(source: script)?.executeAndReturnError(&error), let s = r.stringValue, !s.isEmpty { url = s }
            }
        }
        return MeetingDetectionRules.Signal(micApps: micApps, frontBundleID: frontID, frontName: front?.localizedName, windowTitle: title, browserURL: url)
    }

    private func poll() {
        let m = app.meetings!
        if m.isRecording {
            let micApps = MicUsageMonitor.processesUsingInput().map(\.bundleID)
            let callApp = m.current?.app.bundleID
            let stillOn = callApp == nil || micApps.contains(callApp!) || micApps.contains { MeetingDetectionRules.known($0) != nil }
            if stillOn { micIdleSince = nil } else {
                if micIdleSince == nil { micIdleSince = Date() }
                if let since = micIdleSince, Date().timeIntervalSince(since) >= 60 {
                    micIdleSince = nil
                    app.toast("The call ended; writing the notes.", symbol: "waveform")
                    m.stop()
                }
            }
            return
        }
        micIdleSince = nil
        guard m.prefs.autoDetect, m.state == .idle || m.state == .review || m.state == .failed else { return }
        let s = signal()
        lastSignal = s
        let d = MeetingDetectionRules.evaluate(s)
        lastDetection = d
        guard let d else { pending = nil; pendingSince = nil; return }
        if pending?.bundleID == d.bundleID, let since = pendingSince {
            if Date().timeIntervalSince(since) >= 8 {
                pending = nil
                pendingSince = nil
                m.offer(d)
            }
        } else {
            pending = d
            pendingSince = Date()
        }
    }

    /// The focused window's title through Accessibility (nil without the permission).
    static func focusedWindowTitle(pid: pid_t?) -> String? {
        guard let pid, AXIsProcessTrusted() else { return nil }
        let axApp = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success, let windowRef else { return nil }
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(windowRef as! AXUIElement, kAXTitleAttribute as CFString, &titleRef) == .success, let t = titleRef as? String, !t.isEmpty else { return nil }
        return t
    }
}
