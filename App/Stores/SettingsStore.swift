import Foundation
import Observation
import ServiceManagement
import MochletCore

/// Non-secret preferences, persisted in UserDefaults. Secrets live in the Keychain (M5+).
@MainActor
@Observable
final class SettingsStore {
    @ObservationIgnored private let defaults: UserDefaults

    var displayChoice: DisplayChoice { didSet { defaults.set(displayChoice.storageValue, forKey: "displayChoice") } }
    /// Island anchor per display UUID ("default" for a display without one).
    var islandAnchors: [String: String] { didSet { defaults.set(islandAnchors, forKey: "islandAnchors") } }
    var openOnHover: Bool { didSet { defaults.set(openOnHover, forKey: "openOnHover") } }
    var autoCloseSeconds: Double { didSet { defaults.set(autoCloseSeconds, forKey: "autoCloseSeconds") } }
    var soundEnabled: Bool { didSet { defaults.set(soundEnabled, forKey: "soundEnabled") } }
    var soundVolume: Double { didSet { defaults.set(soundVolume, forKey: "soundVolume") } }
    /// The slime's look, colour, outfit and sound choices (Settings → Character).
    var character: CharacterConfig {
        didSet { if let d = try? JSONEncoder().encode(character) { defaults.set(d, forKey: "character") } }
    }
    var hotkeysEnabled: Bool { didSet { defaults.set(hotkeysEnabled, forKey: "hotkeysEnabled") } }
    /// nil follows the system Reduce Motion setting.
    var reduceMotionOverride: Bool? { didSet { defaults.set(reduceMotionOverride.map { $0 ? "on" : "off" } ?? "system", forKey: "reduceMotion") } }
    var maxVisibleMinis: Int { didSet { defaults.set(maxVisibleMinis, forKey: "maxVisibleMinis") } }
    var observationPaused: Bool { didSet { defaults.set(observationPaused, forKey: "observationPaused") } }
    var greetOnLaunch: Bool { didSet { defaults.set(greetOnLaunch, forKey: "greetOnLaunch") } }
    var lastSeenVersion: String { didSet { defaults.set(lastSeenVersion, forKey: "lastSeenVersion") } }
    /// The main slime lives on the desktop (set loose by dragging it out of the notch).
    var desktopSlime: Bool { didSet { defaults.set(desktopSlime, forKey: "desktopSlime") } }
    var desktopSlimeX: Double { didSet { defaults.set(desktopSlimeX, forKey: "desktopSlimeX") } }
    var desktopSlimeY: Double { didSet { defaults.set(desktopSlimeY, forKey: "desktopSlimeY") } }
    /// Approval and question cards for sessions running in a terminal (the agent waits for the notch).
    var terminalCardsEnabled: Bool { didSet { defaults.set(terminalCardsEnabled, forKey: "terminalCardsEnabled") } }
    var showClaudePlan: Bool { didSet { defaults.set(showClaudePlan, forKey: "showClaudePlan") } }
    var showCodexPlan: Bool { didSet { defaults.set(showCodexPlan, forKey: "showCodexPlan") } }
    /// Mini slimes that finished go back to idle after this many seconds.
    var finishedLinger: Double { didSet { defaults.set(finishedLinger, forKey: "finishedLinger") } }
    /// Chat backend (`ChatProviderKind` raw value) and model.
    var chatProvider: String { didSet { defaults.set(chatProvider, forKey: "chatProvider") } }
    var chatModel: String { didSet { defaults.set(chatModel, forKey: "chatModel") } }
    /// "auto" or a `TerminalApp` raw value.
    var preferredTerminal: String { didSet { defaults.set(preferredTerminal, forKey: "preferredTerminal") } }
    var defaultAgent: String { didSet { defaults.set(defaultAgent, forKey: "defaultAgent") } }
    /// "work on" tasks run as background processes instead of opening a terminal window.
    var headlessTasks: Bool { didSet { defaults.set(headlessTasks, forKey: "headlessTasks") } }
    var windowScreenshots: Bool { didSet { defaults.set(windowScreenshots, forKey: "windowScreenshots") } }
    /// Knowledge base: on-device vectors, git history, and an optional folder other than ~/Mochlet/Knowledge (needs a relaunch).
    var knowledgeEmbeddings: Bool { didSet { defaults.set(knowledgeEmbeddings, forKey: "knowledgeEmbeddings") } }
    var knowledgeGit: Bool { didSet { defaults.set(knowledgeGit, forKey: "knowledgeGit") } }
    var knowledgeRoot: String { didSet { defaults.set(knowledgeRoot, forKey: "knowledgeRoot") } }
    var knowledgeOCR: Bool { didSet { defaults.set(knowledgeOCR, forKey: "knowledgeOCR") } }
    var knowledgeTranscribe: Bool { didSet { defaults.set(knowledgeTranscribe, forKey: "knowledgeTranscribe") } }
    var knowledgeDescribeImages: Bool { didSet { defaults.set(knowledgeDescribeImages, forKey: "knowledgeDescribeImages") } }
    var knowledgeIntegrate: Bool { didSet { defaults.set(knowledgeIntegrate, forKey: "knowledgeIntegrate") } }
    var knowledgeRobots: Bool { didSet { defaults.set(knowledgeRobots, forKey: "knowledgeRobots") } }
    /// Voice: "auto" or a BCP-47 language (zh-CN, zh-TW, en-US); short spoken confirmations.
    var voiceLocale: String { didSet { defaults.set(voiceLocale, forKey: "voiceLocale") } }
    var voiceSpeakReplies: Bool { didSet { defaults.set(voiceSpeakReplies, forKey: "voiceSpeakReplies") } }
    var meetingRetention: MeetingRetention { didSet { defaults.set(meetingRetention.rawValue, forKey: "meetingRetention") } }
    /// Signals: the engine, the digest time ("HH:mm"), brain calls per day, slime reactions, the inbox watch folder.
    var signalsEnabled: Bool { didSet { defaults.set(signalsEnabled, forKey: "signalsEnabled") } }
    var signalsDigestTime: String { didSet { defaults.set(signalsDigestTime, forKey: "signalsDigestTime") } }
    var signalsDailyBudget: Int { didSet { defaults.set(signalsDailyBudget, forKey: "signalsDailyBudget") } }
    var signalsReactions: Bool { didSet { defaults.set(signalsReactions, forKey: "signalsReactions") } }
    var signalsWatchFolder: Bool { didSet { defaults.set(signalsWatchFolder, forKey: "signalsWatchFolder") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        displayChoice = DisplayChoice(storageValue: defaults.string(forKey: "displayChoice") ?? "notch")
        islandAnchors = defaults.dictionary(forKey: "islandAnchors") as? [String: String] ?? [:]
        openOnHover = defaults.object(forKey: "openOnHover") as? Bool ?? false
        autoCloseSeconds = defaults.object(forKey: "autoCloseSeconds") as? Double ?? 15
        soundEnabled = defaults.object(forKey: "soundEnabled") as? Bool ?? true
        soundVolume = defaults.object(forKey: "soundVolume") as? Double ?? 0.5
        if let d = defaults.data(forKey: "character"), let c = try? JSONDecoder().decode(CharacterConfig.self, from: d) {
            character = c
        } else {
            // 2.0 stored only a palette name.
            var c = CharacterConfig()
            if let old = defaults.string(forKey: "themeName") { c.selectPalette(old) }
            character = c
        }
        hotkeysEnabled = defaults.object(forKey: "hotkeysEnabled") as? Bool ?? true
        switch defaults.string(forKey: "reduceMotion") {
        case "on": reduceMotionOverride = true
        case "off": reduceMotionOverride = false
        default: reduceMotionOverride = nil
        }
        maxVisibleMinis = defaults.object(forKey: "maxVisibleMinis") as? Int ?? 4
        observationPaused = defaults.object(forKey: "observationPaused") as? Bool ?? false
        greetOnLaunch = defaults.object(forKey: "greetOnLaunch") as? Bool ?? true
        lastSeenVersion = defaults.string(forKey: "lastSeenVersion") ?? ""
        desktopSlime = defaults.bool(forKey: "desktopSlime")
        desktopSlimeX = defaults.object(forKey: "desktopSlimeX") as? Double ?? -1
        desktopSlimeY = defaults.object(forKey: "desktopSlimeY") as? Double ?? -1
        terminalCardsEnabled = defaults.object(forKey: "terminalCardsEnabled") as? Bool ?? true
        showClaudePlan = defaults.object(forKey: "showClaudePlan") as? Bool ?? true
        showCodexPlan = defaults.object(forKey: "showCodexPlan") as? Bool ?? true
        finishedLinger = defaults.object(forKey: "finishedLinger") as? Double ?? 6
        chatProvider = defaults.string(forKey: "chatProvider") ?? "claude-cli"
        chatModel = defaults.string(forKey: "chatModel") ?? ""
        preferredTerminal = defaults.string(forKey: "preferredTerminal") ?? "auto"
        defaultAgent = defaults.string(forKey: "defaultAgent") ?? "claude"
        headlessTasks = defaults.object(forKey: "headlessTasks") as? Bool ?? false
        windowScreenshots = defaults.object(forKey: "windowScreenshots") as? Bool ?? false
        knowledgeEmbeddings = defaults.object(forKey: "knowledgeEmbeddings") as? Bool ?? true
        knowledgeGit = defaults.object(forKey: "knowledgeGit") as? Bool ?? false
        knowledgeRoot = defaults.string(forKey: "knowledgeRoot") ?? ""
        knowledgeOCR = defaults.object(forKey: "knowledgeOCR") as? Bool ?? true
        knowledgeTranscribe = defaults.object(forKey: "knowledgeTranscribe") as? Bool ?? true
        knowledgeDescribeImages = defaults.object(forKey: "knowledgeDescribeImages") as? Bool ?? true
        knowledgeIntegrate = defaults.object(forKey: "knowledgeIntegrate") as? Bool ?? true
        knowledgeRobots = defaults.object(forKey: "knowledgeRobots") as? Bool ?? true
        voiceLocale = defaults.string(forKey: "voiceLocale") ?? "auto"
        voiceSpeakReplies = defaults.object(forKey: "voiceSpeakReplies") as? Bool ?? false
        meetingRetention = MeetingRetention(rawValue: defaults.string(forKey: "meetingRetention") ?? "") ?? .mixed7d
        signalsEnabled = defaults.object(forKey: "signalsEnabled") as? Bool ?? true
        signalsDigestTime = defaults.string(forKey: "signalsDigestTime") ?? "08:00"
        signalsDailyBudget = defaults.object(forKey: "signalsDailyBudget") as? Int ?? 200
        signalsReactions = defaults.object(forKey: "signalsReactions") as? Bool ?? true
        signalsWatchFolder = defaults.object(forKey: "signalsWatchFolder") as? Bool ?? true
    }

    // MARK: Provider base URLs

    func baseURLOverride(for kind: ChatProviderKind) -> String? {
        let v = defaults.string(forKey: "baseURL.\(kind.rawValue)") ?? ""
        return v.isEmpty ? nil : v
    }

    func baseURL(for kind: ChatProviderKind) -> String {
        baseURLOverride(for: kind) ?? kind.defaultBaseURL ?? ""
    }

    func setBaseURL(_ url: String, for kind: ChatProviderKind) {
        let v = url.trimmingCharacters(in: .whitespaces)
        if v.isEmpty { defaults.removeObject(forKey: "baseURL.\(kind.rawValue)") } else { defaults.set(v, forKey: "baseURL.\(kind.rawValue)") }
    }

    // MARK: Login item

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                MochletLogger(category: "app").error("login item: \(error.localizedDescription)")
            }
        }
    }

    var launchAtLoginNeedsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    func islandAnchor(forDisplay uuid: String?) -> IslandAnchor {
        IslandAnchor(storageValue: islandAnchors[uuid ?? "default"] ?? "center")
    }

    func setIslandAnchor(_ anchor: IslandAnchor, forDisplay uuid: String?) {
        islandAnchors[uuid ?? "default"] = anchor.storageValue
    }
}
