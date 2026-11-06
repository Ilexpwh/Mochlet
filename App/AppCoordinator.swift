import AppKit
import SwiftUI
import simd
import SlimeKit
import SlimeKitUI
import MochletCore
import MochletServices

enum MenuAction: String, CaseIterable, Identifiable {
    case jumpToTerminal, newSession, projects, knowledge, signals, meetings, attachWindow, saveWindow, desktop, sound, dressUp, settings, pauseObservation, quit

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
        case .saveWindow: return "Save window to knowledge"
        case .desktop: return "Let me out"
        case .sound: return "Sound"
        case .dressUp: return "Dress up"
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
        case .saveWindow: return "square.and.arrow.down.on.square"
        case .desktop: return "arrow.up.left.and.arrow.down.right"
        case .sound: return "speaker.wave.2"
        case .dressUp: return "tshirt"
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
    let permissions = PermissionCenter()
    private(set) var sessions: SessionStore!
    private(set) var approvals: ApprovalCenter!
    private(set) var questions: QuestionCenter!
    private(set) var hooks: HookCenter!
    private(set) var installers: AgentInstallerController!
    private(set) var terminal: TerminalJumper!
    private(set) var projects: ProjectsController!
    private(set) var chat: ChatController!
    private(set) var headless: HeadlessRunner!
    private(set) var knowledge: KnowledgeController!
    private(set) var ingest: IngestController!
    private(set) var voice: VoiceController!
    private(set) var meetings: MeetingController!
    private(set) var signals: SignalsController!
    private(set) var window: NotchWindowController!
    private(set) var desktop: DesktopSlimeController!
    private(set) var statusItem: StatusItemController!
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
        MochletLogger(category: "app").notice("Mochlet \(WhatsNew.version) (\(Bundle.main.infoDictionary?["MochletGitHash"] as? String ?? "dev")) starting on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
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
        knowledge = KnowledgeController(app: self)
        ingest = IngestController(app: self)
        voice = VoiceController(app: self)
        meetings = MeetingController(app: self)
        signals = SignalsController(app: self)
        installers = AgentInstallerController(app: self)
        hooks = HookCenter(app: self)
        statusItem = StatusItemController(app: self)
        statusItem.install()
        sessions.start()
        projects.start()
        chat.start()
        knowledge.start()
        meetings.start()
        signals.start()
        hooks.start()
        installers.refresh()
        // Thermal pressure melts the slime (the reference's とけている puddle).
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let s = ProcessInfo.processInfo.thermalState
                if s == .serious || s == .critical { AppCoordinator.shared.slime.stage.main.trigger(.melt) }
            }
        }
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
        Diagnostics.startJanitor()
        if settings.lastSeenVersion != WhatsNew.version {
            DispatchQueue.main.asyncAfter(deadline: .now() + (settings.greetOnLaunch ? 4.2 : 1.2)) {
                MainActor.assumeIsolated { AppCoordinator.shared.openWhatsNew() }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppCoordinator.shared.applySettings() }
        }
    }

    func stop() {
        MochletLogger(category: "app").notice("Mochlet stopping")
        hooks?.stop()
        knowledge?.stop()
        HotKeyCenter.shared.stop()
    }

    /// Expanded views that belong to a session.
    func openSession(_ id: String?) {
        if let id { notch.focusedSessionID = id }
        window.send(.open(.sessionDetail))
    }

    func openDiff(_ id: String) {
        notch.focusedDiffID = id
        window.send(.open(.diff))
    }

    /// ⌃⌥A: the card that needs the user, else the most recent session.
    func goToPending() {
        if approvals.count > 0 { window.send(.open(.approval)); return }
        if questions.pending != nil { window.send(.open(.question)); return }
        if let c = sessions.pending.first ?? sessions.mostRecent { openSession(c.id) } else { toast("Nothing is waiting for you.", symbol: "checkmark.circle") }
    }

    func applySettings() {
        slime.apply(settings: settings)
        window?.applySettings()
        HotKeyCenter.shared.setEnabled(settings.hotkeysEnabled)
        statusItem?.refresh()
    }

    // MARK: - Opening things

    func reveal() {
        window.send(.open(.home))
    }

    func openAsk() {
        if notch.mode == .expanded, notch.view == .ask {
            window.send(.collapse)
            return
        }
        notch.askSuggestions = askSuggestions()
        window.send(.open(.ask))
        slime.stage.main.startQuestion()
        window.focusInput()
    }

    func openMenu() {
        window.send(.open(.menu))
    }

    func openChat() {
        window.send(.open(.chat))
        window.focusInput()
    }

    func openProjects(focusNew: Bool = false) {
        notch.projectsFocus = focusNew ? "new" : nil
        window.send(.open(.projects))
    }

    func openSettings(tab: String? = nil) {
        if settingsWindow == nil { settingsWindow = SettingsWindowController(app: self) }
        settingsWindow?.show(tab: tab)
    }

    func openKnowledge(question: String? = nil) {
        window.send(.open(.knowledge))
        window.focusInput()
        if let question { knowledge.ask(question) }
    }

    func quit() {
        NSApp.terminate(nil)
    }

    func toast(_ text: String, symbol: String? = nil, seconds: Double = 2.6) {
        if notch.mode == .expanded, notch.view != .toast, window.heldOpen || Date().timeIntervalSince(window.lastInteraction) < 3 {
            notch.showNote(text)
            return
        }
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
            openKnowledge()
            return
        }
        if let q = KnowledgeController.question(in: text) {
            openKnowledge(question: q)
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
        if settings.headlessTasks, !project.trusted {
            // A cloned repo can carry project-level hooks; the first run happens where the user can see it.
            toast("\(project.name) is a clone you have not trusted yet, so this opens a terminal. Trust it from the Projects card for background runs.", symbol: "lock")
        }
        if settings.headlessTasks, project.trusted {
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
        case .dressUp:
            window.send(.collapse)
            openSettings(tab: "character")
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
            openKnowledge()
        case .saveWindow:
            saveWindowContext()
        case .meetings:
            openMeetings()
        case .signals:
            openSignals()
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
        voice.begin()
    }

    private func endPushToTalk() {
        guard pushToTalkActive else { return }
        pushToTalkActive = false
        window.hold("ptt", false)
        window.send(.voiceEnd)
        voice.end()
    }

    func toggleMeetingNotes() {
        meetings.toggle()
    }

    func openMeetings() {
        window.send(.open(.meetingLive))
    }

    func openSignals() {
        window.send(.open(.signals))
    }

    /// The What's new card (once per version after the greeting; any time from Settings → General).
    func openWhatsNew() {
        guard !(approvals.count > 0) else { return }      // never over an approval
        window.send(.open(.whatsNew))
    }

    func dismissWhatsNew() {
        settings.lastSeenVersion = WhatsNew.version
        window.send(.collapse)
    }

    func openGuide() {
        NSWorkspace.shared.open(URL(string: "https://github.com/Ilexpwh/Mochlet#readme")!)
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
            if a == .dressUp {
                for item in appearanceMenuItems() { menu.addItem(item) }
                menu.addItem(positionMenuItem())
                continue
            }
            let item = NSMenuItem(title: title(for: a), action: #selector(MenuTarget.fire(_:)), keyEquivalent: "")
            item.representedObject = a.rawValue
            item.target = MenuTarget.shared
            item.image = NSImage(systemSymbolName: symbol(for: a), accessibilityDescription: nil)
            menu.addItem(item)
        }
        return menu
    }

    /// "Island position ▸": left, over the notch, right (and the custom spot when dragged there),
    /// shared by the right-click menu and the status item.
    func positionMenuItem() -> NSMenuItem {
        let root = NSMenuItem(title: "Island position", action: nil, keyEquivalent: "")
        root.image = NSImage(systemSymbolName: "arrow.left.and.right", accessibilityDescription: nil)
        let sub = NSMenu()
        let current = window?.currentAnchor ?? .center
        var anchors = IslandAnchor.presets
        if current.isCustom { anchors.append(current) }
        for a in anchors {
            let item = NSMenuItem(title: a.title(hasNotch: notch.geometry.hasNotch), action: #selector(PositionMenuTarget.fire(_:)), keyEquivalent: "")
            item.representedObject = a.storageValue
            item.target = PositionMenuTarget.shared
            item.state = a == current ? .on : .off
            sub.addItem(item)
        }
        root.submenu = sub
        return root
    }

    /// "Dress up ▸" (outfit sets) and "Look ▸" (species presets) submenus, shared by the
    /// right-click menu and the status item.
    func appearanceMenuItems() -> [NSMenuItem] {
        let dress = NSMenuItem(title: "Dress up", action: nil, keyEquivalent: "")
        dress.image = NSImage(systemSymbolName: "tshirt", accessibilityDescription: nil)
        let dressMenu = NSMenu()
        for set in SlimeOutfit.sets {
            let item = NSMenuItem(title: set.label, action: #selector(AppearanceMenuTarget.fire(_:)), keyEquivalent: "")
            item.representedObject = "set:" + set.name
            item.target = AppearanceMenuTarget.shared
            item.state = settings.character.outfit == set.outfit ? .on : .off
            dressMenu.addItem(item)
        }
        dressMenu.addItem(.separator())
        let more = NSMenuItem(title: "Wardrobe…", action: #selector(AppearanceMenuTarget.fire(_:)), keyEquivalent: "")
        more.representedObject = "wardrobe"
        more.target = AppearanceMenuTarget.shared
        dressMenu.addItem(more)
        dress.submenu = dressMenu

        let look = NSMenuItem(title: "Look", action: nil, keyEquivalent: "")
        look.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        let lookMenu = NSMenu()
        for name in SlimeLook.names {
            let item = NSMenuItem(title: SlimeLook.label(name), action: #selector(AppearanceMenuTarget.fire(_:)), keyEquivalent: "")
            item.representedObject = "look:" + name
            item.target = AppearanceMenuTarget.shared
            item.state = settings.character.lookName == name ? .on : .off
            lookMenu.addItem(item)
        }
        look.submenu = lookMenu
        return [dress, look]
    }

    func chooseOutfitSet(_ name: String) {
        guard let outfit = SlimeOutfit.set(named: name) else { return }
        settings.character.outfit = outfit
        applySettings()
        slime.stage.main.trigger(.happy)
        toast(name == "none" ? "Undressed" : "Dressed as \(SlimeOutfit.sets.first { $0.name == name }?.label ?? name)", symbol: "tshirt")
    }

    func chooseLook(_ name: String) {
        settings.character.selectLook(name)
        applySettings()
        slime.stage.main.trigger(.excited)
        toast("Now a \(SlimeLook.label(name)) slime", symbol: "sparkles")
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
        window.send(.open(.home))
    }

    func dragExited() {
        notch.fileDragOver = false
        slime.stage.main.dragExited()
        window.hold("drag", false)
    }

    /// Folders become projects; files, links and text are eaten into the knowledge base. While the
    /// chat card is open, a drop becomes a chat attachment instead.
    func dropped(urls: [URL], text: String?) {
        notch.fileDragOver = false
        window.hold("drag", false)
        let isFolder = urls.first.map { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false } ?? false
        if isFolder, let url = urls.first {
            slime.stage.main.drop()
            chewWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.slime.stage.main.ingestionFinished(success: true)
                self.projects.offer(folder: url)
                self.openProjects()
            }
            chewWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
            return
        }
        if notch.mode == .expanded, notch.view == .chat {
            if let url = urls.first, url.isFileURL { chat.attachFile(url) }
            else if let url = urls.first { chat.attach(ChatAttachment(kind: .text, title: url.host ?? "link", text: url.absoluteString)) }
            else if let text, !text.isEmpty { chat.attach(ChatAttachment(kind: .text, title: String(OneLine.collapse(text, limit: 30)), text: text)) }
            openChat()
            return
        }
        let resources: [KnowledgeController.Resource]
        if !urls.isEmpty {
            resources = urls.map { $0.isFileURL ? .file($0) : .link($0) }
        } else if let text, !text.isEmpty {
            if let u = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), u.scheme?.hasPrefix("http") == true, !text.contains(" ") {
                resources = [.link(u)]
            } else {
                resources = [.text(text, title: nil)]
            }
        } else {
            toast("Nothing to chew there.", symbol: "doc.text")
            return
        }
        Task { [weak self] in
            guard let self else { return }
            for r in resources { _ = await self.knowledge.add(r, project: self.projectSlug(forDrop: r)) }
        }
    }

    /// "Save this window": the front window's title, URL and (with Screen Recording) its text, filed as a report.
    func saveWindowContext() {
        guard let target = WindowContextCapture.frontmostWindow() else {
            toast("Bring the window to the front, then choose Save window.", symbol: "square.and.arrow.down.on.square")
            return
        }
        slime.stage.main.trigger(.happy)
        Task { @MainActor in
            let a = await WindowContextCapture.capture(target, screenshot: true)
            var text = ""
            if let b64 = a.imageBase64, let data = Data(base64Encoded: b64), let src = CGImageSourceCreateWithData(data as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                text = (try? await OCR.recognise(cgImage: img)) ?? ""
            }
            let url = a.text.split(separator: "\n").first { $0.hasPrefix("URL: ") }.map { String($0.dropFirst(5)) }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let url, let u = URL(string: url) { _ = await knowledge.add(.link(u), from: "window"); return }
                toast("Allow Screen Recording (System Settings → Privacy) so I can read the window, or drop its file or link on me.", symbol: "eye.slash", seconds: 5)
                return
            }
            _ = await ingest.ingest(.window(title: target.title, app: target.owner, url: url, text: text), project: nil, from: "window")
        }
    }

    /// A file dropped from inside a registered project folder is filed under that project.
    private func projectSlug(forDrop r: KnowledgeController.Resource) -> String? {
        guard case .file(let url) = r else { return nil }
        return projects.projects.first { p in p.primaryPath.map { url.path.hasPrefix($0 + "/") } ?? false }?.slug
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

@MainActor final class PositionMenuTarget: NSObject {
    static let shared = PositionMenuTarget()

    @objc func fire(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        AppCoordinator.shared.window?.setAnchor(IslandAnchor(storageValue: raw))
    }
}

@MainActor final class AppearanceMenuTarget: NSObject {
    static let shared = AppearanceMenuTarget()

    @objc func fire(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let app = AppCoordinator.shared
        if raw.hasPrefix("set:") { app.chooseOutfitSet(String(raw.dropFirst(4))) }
        else if raw.hasPrefix("look:") { app.chooseLook(String(raw.dropFirst(5))) }
        else if raw == "wardrobe" { app.openSettings(tab: "character") }
    }
}
