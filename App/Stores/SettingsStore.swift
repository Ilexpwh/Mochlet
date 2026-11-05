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
    var openOnHover: Bool { didSet { defaults.set(openOnHover, forKey: "openOnHover") } }
    var autoCloseSeconds: Double { didSet { defaults.set(autoCloseSeconds, forKey: "autoCloseSeconds") } }
    var soundEnabled: Bool { didSet { defaults.set(soundEnabled, forKey: "soundEnabled") } }
    var soundVolume: Double { didSet { defaults.set(soundVolume, forKey: "soundVolume") } }
    var themeName: String { didSet { defaults.set(themeName, forKey: "themeName") } }
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        displayChoice = DisplayChoice(storageValue: defaults.string(forKey: "displayChoice") ?? "notch")
        openOnHover = defaults.object(forKey: "openOnHover") as? Bool ?? false
        autoCloseSeconds = defaults.object(forKey: "autoCloseSeconds") as? Double ?? 15
        soundEnabled = defaults.object(forKey: "soundEnabled") as? Bool ?? true
        soundVolume = defaults.object(forKey: "soundVolume") as? Double ?? 0.5
        themeName = defaults.string(forKey: "themeName") ?? "rimuru"
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
    }

    // MARK: Login item

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("login item: \(error.localizedDescription)")
            }
        }
    }

    var launchAtLoginNeedsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }
}
