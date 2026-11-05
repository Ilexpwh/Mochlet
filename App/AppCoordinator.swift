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
    let plans = PlanStore()
    private(set) var sessions: SessionStore!
    private(set) var approvals: ApprovalCenter!
    private(set) var questions: QuestionCenter!
    private(set) var hooks: HookCenter!
    private(set) var installers: AgentInstallerController!
    private(set) var terminal: TerminalJumper!
    private(set) var projects: ProjectsController!
    private(set) var chat: ChatController!
    private(set) var headless: HeadlessRunner!
    private(set) var window: NotchWindowController!
    private(set) var desktop: DesktopSlimeController!
    private var statusItem: StatusItemController!
    private(set) var settingsWindow: SettingsWindowController?
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
        sessions = SessionStore(app: self)
        approvals = ApprovalCenter(app: self)
        questions = QuestionCenter(app: self)
        terminal = TerminalJumper(app: self)
        projects = ProjectsController(app: self)
        chat = ChatController(app: self)
        headless = HeadlessRunner(app: self)
        installers = AgentInstallerController(app: self)
        hooks = HookCenter(app: self)
        statusItem = StatusItemController(app: self)
        statusItem.install()
        sessions.start()
        projects.start()
        chat.start()
        hooks.start()
        installers.refresh()
        #if DEBUG
        _ = DebugCommands.token
        #endif
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
        hooks?.stop()
        HotKeyCenter.shared.stop()
    }

    /// Expanded views that belong to a session.
    func openSession(_ id: String?) {
        if let id { notch.focusedSessionID = id }
        window.send(.openExternally(.sessionDetail))
    }

    func openDiff(_ id: String) {
        notch.focusedDiffID = id
        window.send(.openExternally(.diff))
    }

    /// ⌃⌥A: the card that needs the user, else the most recent session.
    func goToPending() {
        if approvals.count > 0 { window.send(.openExternally(.approval)); return }
        if questions.pending != nil { window.send(.openExternally(.question)); return }
        if let c = sessions.pending.first ?? sessions.mostRecent { openSession(c.id) } else { toast("Nothing is waiting for you.", symbol: "checkmark.circle") }
    }

    /// How many plan pills the compact strip shows (its width reserves room for them).
    func updatePills() {
        var n = 0
        if settings.showClaudePlan, plans.claude != nil { n += 1 }
        if settings.showCodexPlan, plans.codex != nil { n += 1 }
        if notch.pillCount != n { notch.pillCount = n }
    }

    func applySettings() {
        updatePills()
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

    func openChat() {
        window.send(.openExternally(.chat))
        window.focusInput()
    }

    func openProjects(focusNew: Bool = false) {
        notch.projectsFocus = focusNew ? "new" : nil
        window.send(.openExternally(.projects))
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
        var out: [String] = []
        if approvals.count > 0 || questions.pending != nil { out.append("What needs my approval?") }
        if let c = sessions.mostRecent { out.append("Summarise what \(c.label) is doing") }
        if let p = projects.projects.first { out.append("Work on \(p.name): ") }
        out.append("Ask the knowledge base…")
        return Array(out.prefix(3))
    }

    /// The ask bubble: project commands are carried out, everything else goes to the chat.
    func submitAsk() {
        let text = notch.askText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        notch.askText = ""
        if let intent = ProjectIntentParser.parse(text) {
            handle(intent)
            return
        }
        if text.hasPrefix("Ask the knowledge base") {
            toast("The knowledge base arrives with milestone 6.", symbol: "books.vertical")
            return
        }
        openChat()
        chat.send(text)
    }

    func handle(_ intent: ProjectIntent) {
        switch intent {
        case .makeProject(let path, let name):
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
                toast("No folder at \(path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).", symbol: "folder.badge.questionmark")
                return
            }
            let p = projects.add(path: path, name: name)
            slime.stage.main.trigger(.happy)
            toast("\(p.name) is now a project.", symbol: "folder.badge.plus")
        case .clone(let url, let name):
            openProjects()
            projects.clone(url: url, name: name)
        case .workOn(let name, let task, let agentTag):
            guard let p = projects.match(name) else { unknownProject(name); return }
            let agent = agentTag.flatMap { AgentKind(tag: $0, bundleID: nil, termProgram: nil) } ?? p.defaultAgent.flatMap { AgentKind(tag: $0, bundleID: nil, termProgram: nil) } ?? AgentKind(tag: settings.defaultAgent, bundleID: nil, termProgram: nil)
            startWork(project: p, task: task, agent: agent)
        case .resume(let name, let agentTag):
            guard let p = projects.match(name) else { unknownProject(name); return }
            resumeProject(p, agent: agentTag.flatMap { AgentKind(tag: $0, bundleID: nil, termProgram: nil) })
        case .open(let name, let terminal):
            guard let p = projects.match(name) else { unknownProject(name); return }
            if projects.open(project: p, in: terminal) { slime.stage.main.trigger(.happy); window.send(.collapse) } else { toast("Could not open \(p.name).", symbol: "terminal") }
        case .listProjects:
            openProjects()
        }
    }

    private func unknownProject(_ name: String) {
        let known = projects.projects.map(\.name).prefix(4).joined(separator: ", ")
        toast(known.isEmpty ? "No project called “\(name)”. Drop a folder on me to add one." : "No project called “\(name)”. I know: \(known).", symbol: "folder.badge.questionmark")
    }

    /// "Work on X: task": a terminal window by default, a background run when the setting says so.
    func startWork(project: Project, task: String, agent: AgentKind) {
        guard let cwd = project.primaryPath else { return }
        var p = project
        if p.defaultAgent != agent.id { p.defaultAgent = agent.id; projects.update(p) }
        if settings.headlessTasks {
            headless.start(agent: agent, project: project, cwd: cwd, task: task, resume: nil)
            window.send(.collapse)
            toast("\(agent.displayName) is working on \(project.name).", symbol: "bolt")
        } else {
            if projects.launch(project: project, agent: agent, task: task, resume: nil) {
                window.send(.collapse)
            } else {
                toast(projects.note ?? "Could not open a terminal.", symbol: "terminal")
            }
        }
    }

    func resumeProject(_ project: Project, agent: AgentKind?) {
        let candidates: [AgentKind] = agent.map { [$0] } ?? [.claude, .codex, .gemini]
        guard let a = candidates.first(where: { project.lastSessions[$0.id] != nil }), let id = project.lastSessions[a.id] else {
            toast("No earlier \(agent?.displayName ?? "agent") session for \(project.name) yet.", symbol: "arrow.counterclockwise")
            return
        }
        if settings.headlessTasks {
            toast("Resume opens a terminal so you can keep talking to the agent.", symbol: "terminal")
        }
        if projects.launch(project: project, agent: a, task: nil, resume: id) { window.send(.collapse) } else { toast(projects.note ?? "Could not open a terminal.", symbol: "terminal") }
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
            if settings.observationPaused {
                approvals.releaseAll()
                questions.handBack(note: "Observation paused.")
                sessions.endAll()
            }
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
        case .jumpToTerminal:
            window.send(.collapse)
            if !terminal.jump(to: sessions.focused) { toast("No agent session to jump to yet.", symbol: "terminal") }
        case .newSession:
            openProjects(focusNew: true)
        case .projects:
            openProjects()
        case .attachWindow:
            if let target = WindowContextCapture.frontmostWindow() {
                attachWindow(target)
            } else {
                toast("Bring the window to the front, then choose Attach window (or ⌥-drag me onto it).", symbol: action.symbol)
            }
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
        guard case .clickClassified(let n) = e else { return }
        window.send(.userInteracted)
        if n >= 2 {
            terminal.jump(to: sessions.card(id))
        } else {
            openSession(id)
        }
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
            if down, !terminal.jump(to: sessions.focused) { toast("No agent session to jump to yet.", symbol: "terminal") }
        case .pendingAlert:
            if down { goToPending() }
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
            slime.stage.mini(id)?.engine.pressBegan(at: SIMD2(0, -0.9))
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

    /// ⌥-drop of the slime on another app's window: its title, URL and (optionally) a screenshot
    /// become context for the next chat message.
    func attachWindow(_ target: WindowProbe.TargetWindow) {
        slime.stage.main.trigger(.happy)
        let wantShot = settings.windowScreenshots
        Task { @MainActor in
            let a = await WindowContextCapture.capture(target, screenshot: wantShot)
            chat.attach(a)
            openChat()
        }
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
            if isFolder, let url = urls.first {
                self.projects.offer(folder: url)
                self.openProjects()
            } else if let url = urls.first, url.isFileURL {
                // Text-like files become chat context now; the knowledge base (M6) files everything.
                self.chat.attachFile(url)
                self.openChat()
            } else if let url = urls.first {
                self.chat.attach(ChatAttachment(kind: .text, title: url.host ?? "link", text: url.absoluteString))
                self.openChat()
            } else if let text, !text.isEmpty {
                self.chat.attach(ChatAttachment(kind: .text, title: String(OneLine.collapse(text, limit: 30)), text: text))
                self.openChat()
            } else {
                self.toast("Chewed “\(name)”.", symbol: "doc.text")
            }
        }
        chewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
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
