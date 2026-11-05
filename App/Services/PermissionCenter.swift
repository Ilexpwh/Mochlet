import AppKit
import AVFoundation
import ApplicationServices
import CoreServices
import ServiceManagement
import Observation

/// Every macOS permission Mochlet may need, with its current state, a way to ask for it and the
/// System Settings pane that holds it. Permissions are requested lazily by the feature that needs
/// them; this is the one place that shows where things stand (Settings → General → Permissions).
@MainActor
@Observable
final class PermissionCenter {
    enum Status: Equatable {
        case granted, denied, notAsked, notRunning, unknown
        var label: String {
            switch self {
            case .granted: return "allowed"
            case .denied: return "denied"
            case .notAsked: return "not asked yet"
            case .notRunning: return "not running"
            case .unknown: return "asked when first needed"
            }
        }
        var colour: NSColor {
            switch self {
            case .granted: return .systemGreen
            case .denied: return .systemRed
            case .notAsked, .unknown: return .systemGray
            case .notRunning: return .systemGray
            }
        }
    }

    enum Kind: String, CaseIterable, Identifiable {
        case microphone, systemAudio, accessibility, screenRecording, automation, loginItem
        var id: String { rawValue }
        var name: String {
            switch self {
            case .microphone: return "Microphone"
            case .systemAudio: return "System audio recording"
            case .accessibility: return "Accessibility"
            case .screenRecording: return "Screen recording"
            case .automation: return "Automation"
            case .loginItem: return "Launch at login"
            }
        }
        var purpose: String {
            switch self {
            case .microphone: return "Hold the slime to talk; your side of a noted meeting."
            case .systemAudio: return "The other side of a meeting (what the Mac plays)."
            case .accessibility: return "Window titles for drag-out context, meeting detection and terminal jumps."
            case .screenRecording: return "Optional window screenshots as chat context (Settings → Chat)."
            case .automation: return "Asking Terminal, iTerm and your browser to show a window or its URL."
            case .loginItem: return "Mochlet starts with your Mac."
            }
        }
        /// The System Settings pane (deep link) for this permission.
        var pane: URL {
            switch self {
            case .microphone: return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
            case .systemAudio: return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
            case .accessibility: return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            case .screenRecording: return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            case .automation: return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
            case .loginItem: return URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
            }
        }
        /// Can Mochlet put the system prompt up itself?
        var canRequest: Bool {
            switch self {
            case .microphone, .accessibility, .screenRecording, .automation: return true
            case .systemAudio, .loginItem: return false
            }
        }
    }

    struct Row: Identifiable {
        var kind: Kind
        var status: Status
        var detail: String
        var id: String { kind.id }
    }

    /// Automation targets worth reporting: the terminals and browsers Mochlet scripts.
    static let automationTargets: [(name: String, bundleID: String)] = [
        ("Terminal", "com.apple.Terminal"), ("iTerm2", "com.googlecode.iterm2"), ("Safari", "com.apple.Safari"),
        ("Google Chrome", "com.google.Chrome"), ("System Events", "com.apple.systemevents"),
    ]

    private(set) var rows: [Row] = []
    private(set) var refreshedAt: Date?

    /// Recomputes every row. Cheap (no prompts, no lookups that block), safe to call on every appearance.
    func refresh() {
        var out: [Row] = []
        let mic: Status
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: mic = .granted
        case .denied, .restricted: mic = .denied
        case .notDetermined: mic = .notAsked
        @unknown default: mic = .unknown
        }
        out.append(Row(kind: .microphone, status: mic, detail: Kind.microphone.purpose))

        let audio = UserDefaults.standard.string(forKey: "systemAudioOutcome")
        let audioStatus: Status = audio == "granted" ? .granted : audio == "denied" ? .denied : .unknown
        out.append(Row(kind: .systemAudio, status: audioStatus, detail: audio == "denied" ? "Refused the last time a meeting was noted; allow it under Screen & System Audio Recording." : Kind.systemAudio.purpose))

        out.append(Row(kind: .accessibility, status: AXIsProcessTrusted() ? .granted : .notAsked, detail: Kind.accessibility.purpose))
        out.append(Row(kind: .screenRecording, status: CGPreflightScreenCaptureAccess() ? .granted : .notAsked, detail: Kind.screenRecording.purpose))

        var parts: [String] = []
        var worst: Status = .notRunning
        for t in Self.automationTargets {
            let s = Self.automationStatus(bundleID: t.bundleID)
            if s != .notRunning { parts.append("\(t.name): \(s.label)") }
            switch (worst, s) {
            case (_, .denied): worst = .denied
            case (.notRunning, .granted), (.notRunning, .notAsked), (.notRunning, .unknown): worst = s
            case (.granted, .notAsked): worst = .notAsked
            default: break
            }
        }
        out.append(Row(kind: .automation, status: worst, detail: parts.isEmpty ? "No terminal or browser is running; asked the first time Mochlet talks to one." : parts.joined(separator: " · ")))

        let login: Status
        var loginDetail = Kind.loginItem.purpose
        switch SMAppService.mainApp.status {
        case .enabled: login = .granted
        case .requiresApproval: login = .notAsked; loginDetail = "Approve Mochlet under System Settings → General → Login Items."
        case .notRegistered, .notFound: login = .unknown; loginDetail = "Off. Turn it on under System above."
        @unknown default: login = .unknown
        }
        out.append(Row(kind: .loginItem, status: login, detail: loginDetail))
        rows = out
        refreshedAt = Date()
    }

    /// Apple-event permission for one running app, without prompting. Not running → `.notRunning`.
    nonisolated static func automationStatus(bundleID: String, ask: Bool = false) -> Status {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let desc = target.aeDesc else { return .unknown }
        let status = AEDeterminePermissionToAutomateTarget(desc, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
        switch Int(status) {
        case 0: return .granted
        case -1743: return .denied                      // errAEEventNotPermitted
        case -1744: return .notAsked                    // errAEEventWouldRequireUserConsent
        case -600: return .notRunning                   // procNotFound
        default: return .unknown
        }
    }

    /// Puts the system prompt up where macOS has one; otherwise opens the pane.
    func request(_ kind: Kind) {
        switch kind {
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in self.refresh() }
            }
        case .accessibility:
            let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary    // kAXTrustedCheckOptionPrompt
            _ = AXIsProcessTrustedWithOptions(opts)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MainActor.assumeIsolated { self.refresh() } }
        case .screenRecording:
            if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MainActor.assumeIsolated { self.refresh() } }
        case .automation:
            // Asking blocks the calling thread while the dialog is up: never on main.
            let targets = Self.automationTargets
            Task.detached {
                for t in targets where NSRunningApplication.runningApplications(withBundleIdentifier: t.bundleID).isEmpty == false {
                    _ = Self.automationStatus(bundleID: t.bundleID, ask: true)
                }
                await MainActor.run { self.refresh() }
            }
        case .systemAudio, .loginItem:
            open(kind)
        }
    }

    func open(_ kind: Kind) { NSWorkspace.shared.open(kind.pane) }

    /// Records how the system-audio tap went the last time a meeting was noted (there is no query API).
    nonisolated static func recordSystemAudio(granted: Bool) {
        UserDefaults.standard.set(granted ? "granted" : "denied", forKey: "systemAudioOutcome")
    }
}
