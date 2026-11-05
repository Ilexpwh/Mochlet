import Foundation

/// When is the Mac in a call? Three signals, combined here without touching the system:
/// A. which apps hold the microphone (Core Audio process list), B. known call apps by bundle id,
/// C. the window title or browser URL. `likely = micInUse(app) && (knownApp || titleMatch)`;
/// browsers need the title.
public enum MeetingDetectionRules {
    public struct KnownApp: Sendable, Equatable {
        public var bundleID: String
        public var name: String
        /// Browsers and all-purpose apps: the microphone alone is not a call, the title must say so.
        public var needsTitle: Bool
    }

    public static let knownApps: [KnownApp] = [
        KnownApp(bundleID: "us.zoom.xos", name: "Zoom", needsTitle: false),
        KnownApp(bundleID: "com.microsoft.teams2", name: "Microsoft Teams", needsTitle: false),
        KnownApp(bundleID: "com.microsoft.teams", name: "Microsoft Teams", needsTitle: false),
        KnownApp(bundleID: "com.cisco.webexmeetingsapp", name: "Webex", needsTitle: false),
        KnownApp(bundleID: "com.webex.meetingmanager", name: "Webex", needsTitle: false),
        KnownApp(bundleID: "com.hnc.Discord", name: "Discord", needsTitle: false),
        KnownApp(bundleID: "com.larksuite.macos.lark", name: "Lark", needsTitle: true),
        KnownApp(bundleID: "com.bytedance.macos.feishu", name: "Feishu", needsTitle: true),
        KnownApp(bundleID: "com.electron.lark", name: "Lark", needsTitle: true),
        KnownApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", needsTitle: true),
        KnownApp(bundleID: "com.apple.FaceTime", name: "FaceTime", needsTitle: false),
        KnownApp(bundleID: "notion.id", name: "Notion", needsTitle: true),
        KnownApp(bundleID: "com.google.Chrome", name: "Chrome", needsTitle: true),
        KnownApp(bundleID: "com.apple.Safari", name: "Safari", needsTitle: true),
        KnownApp(bundleID: "company.thebrowser.Browser", name: "Arc", needsTitle: true),
        KnownApp(bundleID: "org.mozilla.firefox", name: "Firefox", needsTitle: true),
        KnownApp(bundleID: "com.microsoft.edgemac", name: "Edge", needsTitle: true),
        KnownApp(bundleID: "com.brave.Browser", name: "Brave", needsTitle: true),
        KnownApp(bundleID: "com.google.meet", name: "Google Meet", needsTitle: false),
        KnownApp(bundleID: "com.skype.skype", name: "Skype", needsTitle: false),
        KnownApp(bundleID: "com.tencent.meeting", name: "Tencent Meeting", needsTitle: false),
        KnownApp(bundleID: "com.tencent.xinWeChat", name: "WeChat", needsTitle: true),
        KnownApp(bundleID: "com.alibaba.DingTalkMac", name: "DingTalk", needsTitle: true),
    ]

    /// Window titles (or URLs) that say a call is on.
    public static let titlePatterns: [(pattern: String, name: String)] = [
        (#"^Zoom (Meeting|Webinar)"#, "Zoom"),
        (#"(?i)\bzoom\.us/j/"#, "Zoom"),
        (#"(?i)^(.*\| )?Microsoft Teams"#, "Microsoft Teams"),
        (#"(?i)teams\.(microsoft|live)\.com"#, "Microsoft Teams"),
        (#"(?i)meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}"#, "Google Meet"),
        (#"^Meet [–-] [a-z]{3}-[a-z]{4}-[a-z]{3}"#, "Google Meet"),
        (#"(?i)\b(Lark Meeting|视频会议|飞书会议|Lark 会议)\b"#, "Lark"),
        (#"(?i)vc\.(larksuite|feishu)\.(com|cn)/j/"#, "Lark"),
        (#"(?i)\bwebex\b"#, "Webex"),
        (#"(?i)AI Meeting Notes"#, "Notion"),
        (#"(?i)\bhuddle\b"#, "Slack"),
        (#"(?i)\b(Voice|Video) (Call|Chat)\b"#, "Call"),
        (#"(?i)\bDiscord\b.*\bvoice\b"#, "Discord"),
        (#"(?i)腾讯会议|Tencent Meeting"#, "Tencent Meeting"),
        (#"(?i)whereby\.com/"#, "Whereby"),
        (#"(?i)app\.around\.co|gather\.town"#, "Call"),
    ]

    public struct Signal: Sendable, Equatable {
        /// Bundle ids of the processes recording from the microphone.
        public var micApps: [String]
        public var frontBundleID: String?
        public var frontName: String?
        public var windowTitle: String?
        public var browserURL: String?
        public init(micApps: [String], frontBundleID: String? = nil, frontName: String? = nil, windowTitle: String? = nil, browserURL: String? = nil) {
            self.micApps = micApps
            self.frontBundleID = frontBundleID
            self.frontName = frontName
            self.windowTitle = windowTitle
            self.browserURL = browserURL
        }
    }

    public struct Detection: Sendable, Equatable {
        public var bundleID: String
        public var appName: String
        public var title: String
        public var reason: String
    }

    public static func known(_ bundleID: String) -> KnownApp? { knownApps.first { $0.bundleID == bundleID } }

    public static func titleMatch(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        for (p, name) in titlePatterns where text.range(of: p, options: .regularExpression) != nil { return name }
        return nil
    }

    /// The call going on, if any. The app holding the microphone comes first; the front app's title can
    /// confirm a browser or Lark.
    public static func evaluate(_ s: Signal) -> Detection? {
        for mic in s.micApps {
            guard let app = known(mic) else { continue }
            let isFront = s.frontBundleID == mic
            let text = isFront ? [s.browserURL, s.windowTitle].compactMap { $0 }.joined(separator: " ") : ""
            let byTitle = titleMatch(text)
            if !app.needsTitle {
                let title = isFront ? (s.windowTitle ?? "") : ""
                return Detection(bundleID: mic, appName: byTitle ?? app.name, title: title.isEmpty ? app.name : title, reason: "microphone in use by \(app.name)")
            }
            if let byTitle {
                return Detection(bundleID: mic, appName: byTitle, title: s.windowTitle ?? byTitle, reason: "microphone in use by \(app.name), window says \(byTitle)")
            }
        }
        // A call app recording from the microphone that we do not know by name, with a telling title.
        if let front = s.frontBundleID, s.micApps.contains(front), let byTitle = titleMatch([s.browserURL, s.windowTitle].compactMap { $0 }.joined(separator: " ")) {
            return Detection(bundleID: front, appName: byTitle, title: s.windowTitle ?? byTitle, reason: "microphone in use, window says \(byTitle)")
        }
        return nil
    }
}

/// Per-app answers and quiet hours, `~/Mochlet/Meetings/prefs.json`.
public struct MeetingPrefs: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable { case ask, always, never }

    public var apps: [String: Mode] = [:]
    /// Minutes after midnight; a window that wraps (22:00 → 08:00) is fine. nil = no quiet hours.
    public var quietStart: Int?
    public var quietEnd: Int?
    /// "bundle|title" → until when the ask is snoozed.
    public var snoozed: [String: Date] = [:]
    public var autoDetect: Bool = true

    public init() {}

    public static let snooze: TimeInterval = 30 * 60

    public enum Verdict: Equatable, Sendable { case capture, ask, ignore }

    public func isQuiet(at date: Date, calendar: Calendar = .current) -> Bool {
        guard let s = quietStart, let e = quietEnd, s != e else { return false }
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return s < e ? (m >= s && m < e) : (m >= s || m < e)
    }

    public static func key(_ d: MeetingDetectionRules.Detection) -> String { "\(d.bundleID)|\(d.title)" }

    public func verdict(for d: MeetingDetectionRules.Detection, at date: Date = Date()) -> Verdict {
        guard autoDetect else { return .ignore }
        switch apps[d.bundleID] ?? .ask {
        case .never: return .ignore
        case .always: return isQuiet(at: date) ? .ignore : .capture
        case .ask:
            if isQuiet(at: date) { return .ignore }
            if let until = snoozed[Self.key(d)], until > date { return .ignore }
            return .ask
        }
    }

    public mutating func snooze(_ d: MeetingDetectionRules.Detection, at date: Date = Date()) {
        snoozed[Self.key(d)] = date.addingTimeInterval(Self.snooze)
        snoozed = snoozed.filter { $0.value > date }
    }
}
