import AppKit
import SwiftUI
import simd
import SlimeKit
import SlimeKitUI
import MochletCore

enum MenuAction: String, CaseIterable, Identifiable {
    case jumpToTerminal, newSession, projects, knowledge, signals, meetings, attachWindow, desktop, sound, settings, pauseObservation, quit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .jumpToTerminal: return "Jump to terminal"
        case .newSession: return "New session"
        case .projects: return "Projects"
        case .knowledge: return "Knowledge"
        case .signals: return "Signals"
        case .meetings: return "Meeting notes"
        case .attachWindow: return "Attach window"
        case .desktop: return "Let me out"
        case .sound: return "Sound"
        case .settings: return "Settings"
        case .pauseObservation: return "Pause observation"
        case .quit: return "Quit"
        }
    }

    var symbol: String {
        switch self {
        case .jumpToTerminal: return "terminal"
        case .newSession: return "plus.bubble"
        case .projects: return "folder"
        case .knowledge: return "books.vertical"
        case .signals: return "antenna.radiowaves.left.and.right"
        case .meetings: return "waveform"
        case .attachWindow: return "macwindow.badge.plus"
        case .desktop: return "arrow.up.left.and.arrow.down.right"
        case .sound: return "speaker.wave.2"
        case .settings: return "gearshape"
        case .pauseObservation: return "pause.circle"
        case .quit: return "power"
        }
    }
}

/// One coordinator, several small stores. Slime events, hot keys, menus and drops all land here
/// and are turned into store changes and window-controller inputs.
@MainActor
final class AppCoordinator {
    static let shared = AppCoordinator()

    let settings = SettingsStore()
    let notch = NotchStore()
    let slime = SlimeBridge()
    private(set) var window: NotchWindowController!
    private(set) var desktop: DesktopSlimeController!
    private var statusItem: StatusItemController!
    private var settingsWindow: SettingsWindowController?
    private var toastWork: DispatchWorkItem?
    private var pushToTalkActive = false
    private var chewWork: DispatchWorkItem?

    private init() {}

    var fsmConfig: NotchFSM.Config {
        var c = NotchFSM.Config()
        c.openOnHover = settings.openOnHover
        c.expandedIdle = settings.autoCloseSeconds
        return c
    }

    func start() {
        slime.apply(settings: settings)
        slime.sound.preload()
        slime.onEvent = { [weak self] e in self?.handle(e) }
        slime.onMiniEvent = { [weak self] id, e in self?.handleMini(id, e) }
        window = NotchWindowController(app: self)
        desktop = DesktopSlimeController(app: self)
        statusItem = StatusItemController(app: self)
        statusItem.install()
        HotKeyCenter.shared.start(enabled: settings.hotkeysEnabled) { [weak self] key, down in
            self?.hotKey(key, down: down)
        }
        window.show()
        if settings.greetOnLaunch {
            window.launchGreeting()
        } else {
            window.send(.reveal)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (settings.greetOnLaunch ? 2.8 : 0.6)) {
            MainActor.assumeIsolated { AppCoordinator.shared.desktop.restoreIfEnabled() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppCoordinator.shared.applySettings() }
        }
    }

    func stop() {
        HotKeyCenter.shared.stop()
    }

    func applySettings() {
        slime.apply(settings: settings)
        window?.applySettings()
        HotKeyCenter.shared.setEnabled(settings.hotkeysEnabled)
        statusItem?.refresh()
    }

    // MARK: - Opening things

    func reveal() {
        window.send(.openExternally(.home))
    }

    func openAsk() {
        if notch.mode == .expanded, notch.view == .ask {
            window.send(.collapse)
            return
        }
        notch.askSuggestions = askSuggestions()
        window.send(.openExternally(.ask))
        slime.stage.main.startQuestion()
        window.focusInput()
    }

    func openMenu() {
        window.send(.openExternally(.menu))
    }

    func openSettings() {
        if settingsWindow == nil { settingsWindow = SettingsWindowController(app: self) }
        settingsWindow?.show()
    }

    func quit() {
        NSApp.terminate(nil)
    }

    func toast(_ text: String, symbol: String? = nil, seconds: Double = 2.6) {
        notch.toast = Toast(text: text, symbol: symbol)
        window.send(.openExternally(.toast))
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.notch.view == .toast else { return }
            self.notch.toast = nil
            self.window.send(.collapse)
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func askSuggestions() -> [String] {
        ["What needs my approval?", "Summarise what my sessions are doing", "Ask the knowledge base…"]
    }

    func submitAsk() {
        let text = notch.askText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        notch.askText = ""
        slime.stage.main.trigger(.happy)
        toast("“\(text)” noted. Chat with Claude, Codex and the API providers arrives with milestone 5.", symbol: "bubble.left")
    }

    func menu(_ action: MenuAction) {
        window.send(.userInteracted)
        switch action {
        case .sound:
            settings.soundEnabled.toggle()
            applySettings()
            toast(settings.soundEnabled ? "Sounds on" : "Sounds off", symbol: settings.soundEnabled ? "speaker.wave.2" : "speaker.slash")
        case .settings:
            window.send(.collapse)
            openSettings()
        case .pauseObservation:
            settings.observationPaused.toggle()
            statusItem.refresh()
            toast(settings.observationPaused ? "Observation paused" : "Observation resumed", symbol: action.symbol)
        case .quit:
            quit()
        case .desktop:
            if desktop.isActive {
                desktop.flyHome()
            } else {
                window.send(.collapse)
                desktop.flyOut(to: desktop.savedCenter() ?? desktop.defaultCenter(), from: window.mainSlimeScreenRect())
            }
        case .jumpToTerminal, .newSession:
            toast("\(action.title) arrives with milestone 4 (agent observation).", symbol: action.symbol)
        case .projects, .attachWindow:
            toast("\(action.title) arrives with milestone 5 (projects and chat).", symbol: action.symbol)
        case .knowledge:
            toast("Knowledge base arrives with milestone 6.", symbol: action.symbol)
        case .meetings:
            toggleMeetingNotes()
        case .signals:
            toast("AI signals arrive with milestone 10.", symbol: action.symbol)
        }
    }

    // MARK: - Slime events

    private func handle(_ e: SlimeEvent) {
        switch e {
        case .clickClassified(let n):
            window.send(.userInteracted)
            switch n {
            case 1: openAsk()
            case 2: openMenu()
            case 3, 4: toggleMeetingNotes()
            default: break
            }
        case .holdBegan:
            beginPushToTalk()
        case .holdEnded:
            endPushToTalk()
        case .dragOutBegan:
            if desktop.isActive { desktop.beginDrag() } else { window.beginDragOut() }
        case .splitRequested:
            window.send(.userInteracted)
        case .stateChanged, .emoteTriggered, .landed, .dropAccepted, .wokeUp:
            break
        }
    }

    private func handleMini(_ id: String, _ e: SlimeEvent) {
        if case .clickClassified = e { toast("Session \(id)", symbol: "terminal") }
    }

    private func beginPushToTalk() {
        guard !pushToTalkActive else { return }
        pushToTalkActive = true
        window.hold("ptt", true)
        slime.stage.main.startListening()
        window.send(.voiceStart)
        notch.askText = ""
    }

    private func endPushToTalk() {
        guard pushToTalkActive else { return }
        pushToTalkActive = false
        slime.stage.main.stopListening(hadSpeech: false)
        window.hold("ptt", false)
        window.send(.voiceEnd)
        toast("Push-to-talk with on-device speech arrives with milestone 8.", symbol: "mic")
    }

    private func toggleMeetingNotes() {
        slime.stage.main.trigger(.confused)
        toast("The meeting note-taker arrives with milestone 9.", symbol: "waveform")
    }

    // MARK: - Hot keys

    private func hotKey(_ key: HotKeyCenter.Key, down: Bool) {
        switch key {
        case .ask:
            if down { openAsk() }
        case .pushToTalk:
            if down {
                slime.stage.main.pressBegan(at: SIMD2(0, -0.9))
                beginPushToTalk()
            } else {
                slime.stage.main.pressEnded()
                endPushToTalk()
            }
        case .jumpToTerminal:
            if down { toast("Jump to terminal arrives with milestone 4.", symbol: "terminal") }
        case .pendingAlert:
            if down { toast("Nothing is waiting for you.", symbol: "checkmark.circle") }
        }
    }

    // MARK: - Pointer and presses on slimes (from SlimeHitView)

    func hitSlime(atIsland p: CGPoint) -> StageHit {
        let o = notch.slimeOrigin
        return slime.stage.hitTest(slime.toStage(p, origin: CGPoint(x: o.x, y: o.y)))
    }

    func slimePressed(atIsland p: CGPoint) {
        let o = notch.slimeOrigin
        let local = slime.toStage(p, origin: CGPoint(x: o.x, y: o.y))
        switch slime.stage.hitTest(local) {
        case .main:
            slime.stage.main.pressBegan(at: local)
        case .mini(let id):
            slime.stage.mini(id)?.engine.impulse(.wobble(angle: -.pi / 2, strength: 0.3))
            toast("Session \(id) · details arrive with milestone 4.", symbol: "terminal")
        case .none:
            break
        }
    }

    func slimeMoved(toIsland p: CGPoint, screen: NSPoint) {
        if window.isDraggingOut {
            window.dragMoved(screen: screen)
        } else {
            let o = notch.slimeOrigin
            slime.stage.main.pressMoved(to: slime.toStage(p, origin: CGPoint(x: o.x, y: o.y)))
        }
    }

    func slimeReleased(screen: NSPoint) {
        if window.isDraggingOut {
            window.dragEnded(screen: screen)
        } else {
            slime.stage.main.pressEnded()
        }
    }

    /// Menu labels that depend on state.
    func title(for a: MenuAction) -> String {
        switch a {
        case .sound: return settings.soundEnabled ? "Mute" : "Unmute"
        case .pauseObservation: return settings.observationPaused ? "Resume observation" : "Pause observation"
        case .desktop: return desktop?.isActive == true ? "Back to the notch" : "Let me out"
        default: return a.title
        }
    }

    func symbol(for a: MenuAction) -> String {
        switch a {
        case .sound: return settings.soundEnabled ? "speaker.slash" : "speaker.wave.2"
        case .desktop: return desktop?.isActive == true ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
        default: return a.symbol
        }
    }

    func contextMenu() -> NSMenu {
        let menu = NSMenu()
        for a in MenuAction.allCases {
            if a == .quit || a == .settings { menu.addItem(.separator()) }
            let item = NSMenuItem(title: title(for: a), action: #selector(MenuTarget.fire(_:)), keyEquivalent: "")
            item.representedObject = a.rawValue
            item.target = MenuTarget.shared
            item.image = NSImage(systemSymbolName: symbol(for: a), accessibilityDescription: nil)
            menu.addItem(item)
        }
        return menu
    }

    /// ⌥-drop of the slime on another app's window. Context capture lands with milestone 5.
    func attachWindow(_ target: WindowProbe.TargetWindow) {
        slime.stage.main.trigger(.happy)
        toast("Attached \(target.owner)\(target.title.isEmpty ? "" : " · \(target.title)"). Window context arrives with milestone 5.", symbol: "macwindow.badge.plus")
    }

    // MARK: - Drops

    func dragEntered(atIsland p: CGPoint) {
        notch.fileDragOver = true
        let o = notch.slimeOrigin
        slime.stage.main.dragEntered(fromDirection: p.x >= o.x ? 1 : -1)
        window.hold("drag", true)
        window.send(.openExternally(.home))
    }

    func dragExited() {
        notch.fileDragOver = false
        slime.stage.main.dragExited()
        window.hold("drag", false)
    }

    func dropped(urls: [URL], text: String?) {
        notch.fileDragOver = false
        window.hold("drag", false)
        slime.stage.main.drop()
        let name = urls.first?.lastPathComponent ?? (text.map { String($0.prefix(40)) } ?? "that")
        let isFolder = urls.first.map { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false } ?? false
        chewWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.slime.stage.main.ingestionFinished(success: true)
            if isFolder {
                self.toast("“\(name)” can become a project with milestone 5.", symbol: "folder")
            } else {
                self.toast("Chewed “\(name)”. Filing into the knowledge base arrives with milestone 6.", symbol: "doc.text")
            }
        }
        chewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }
}

/// Objective-C target for NSMenu items built from `MenuAction`.
@MainActor
final class MenuTarget: NSObject {
    static let shared = MenuTarget()

    @objc func fire(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let a = MenuAction(rawValue: raw) else { return }
        AppCoordinator.shared.menu(a)
    }
}
