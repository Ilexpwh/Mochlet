import AppKit
import SwiftUI
import simd
import SlimeKit
import SlimeKitUI
import MochletCore

/// Owns the panel over the notch: the FSM and its timers, the island's size springs, the AppKit
/// slime view, the pointer poll that toggles click-through, keyboard monitors, screen choice and
/// the drag-out session.
@MainActor
final class NotchWindowController: NSWindowController {
    struct DebugCounters {
        var ticks: Int
        var redraws: Int
        var paused: Bool
    }

    /// The panel is a strip across the top of its screen; the island slides along it.
    static let panelHeight: CGFloat = 560
    private static let fastPoll: TimeInterval = 1.0 / 60.0
    private static let nearPoll: TimeInterval = 1.0 / 20.0
    private static let idlePoll: TimeInterval = 1.0 / 8.0

    private unowned let app: AppCoordinator
    private var fsm: NotchFSM
    private var timers: [NotchFSM.TimerID: DispatchWorkItem] = [:]
    private var pollTimer: Timer?
    private var pollInterval: TimeInterval = 0
    private var screenOff = false
    private var wasInIsland = false
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private(set) var currentScreen: NSScreen?
    private var heldOpenFlags: [String: NotchFSM.Hold.Scope] = [:]
    /// When each armed FSM timer fires (for the countdown and the debug dump).
    private var timerDeadlines: [NotchFSM.TimerID: Date] = [:]
    /// Last click, key or acknowledged action on the island.
    private(set) var lastInteraction = Date.distantPast
    /// Notifications that arrived while the user was busy with a card; shown once it folds.
    private var pendingReveals: [NotchView] = []
    private var revealWork: DispatchWorkItem?
    private(set) var dragOut: DragOutSession?
    private var greetingWork: DispatchWorkItem?
    private var hitView: SlimeHitView!
    private var dropView: FileDropNSView!
    private var slimeView: SlimeStageLayerView!
    private let maskLayer = CAShapeLayer()
    private var panel: NotchPanel { window as! NotchPanel }

    // Island motion: one spring per animated quantity, advanced on the slime view's display link.
    private var wSpring = Spring1D(value: NotchGeometry.fallbackNotchWidth, response: 0.5, dampingFraction: 0.72)
    private var hSpring = Spring1D(value: 32, response: 0.5, dampingFraction: 0.72)
    private var cSpring = Spring1D(value: NotchLayout.compactCorner, response: 0.5, dampingFraction: 0.72)
    private var rSpring = Spring1D(value: 15, response: 0.5, dampingFraction: 0.72)
    private var oSpring = Spring2D(value: SIMD2(NotchLayout.compactWing / 2, 30), response: 0.5, dampingFraction: 0.72)
    private var xSpring = Spring1D(value: 0, response: 0.5, dampingFraction: 0.72)
    private var motionSettled = true

    init(app: AppCoordinator) {
        self.app = app
        fsm = NotchFSM(config: app.fsmConfig)
        let screen = Self.targetScreen(for: app.settings.displayChoice)
        let frame = Self.panelFrame(on: screen)
        let panel = NotchPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init(window: panel)
        currentScreen = screen
        app.notch.geometry = Self.geometry(for: screen)
        app.notch.containerWidth = Double(frame.width)
        setupPanel()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupPanel() {
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        panel.depthLimit = .twentyfourBitRGB
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.isMovableByWindowBackground = false

        let size = panel.contentRect(forFrameRect: panel.frame).size
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.autoresizingMask = [.width, .height]

        let hosting = NSHostingView(rootView: NotchRootView(app: app))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]

        slimeView = SlimeStageLayerView(stage: app.slime.stage, radius: app.slime.radius, origin: { [weak self] _ in
            guard let self else { return .zero }
            let o = self.app.notch.liveSlimeOrigin
            return CGPoint(x: o.x, y: o.y)
        })
        slimeView.sink = app.slime.sound
        slimeView.probe = app.slime.probe
        slimeView.include = { [weak self] p in
            guard p.id != "ghost" else { return false }
            if p.id == nil, self?.app.notch.slimeOnDesktop == true { return false }
            return true
        }
        slimeView.pointer = { [weak self] in self?.app.slime.pointer }
        slimeView.onTick = { [weak self] _, dt in self?.tickLayout(dt) }
        slimeView.layer?.mask = maskLayer
        slimeView.paused = true

        hitView = SlimeHitView(app: app, controller: self)
        hitView.frame = container.bounds
        hitView.autoresizingMask = [.width, .height]

        dropView = FileDropNSView(frame: container.bounds)
        dropView.autoresizingMask = [.width, .height]
        dropView.accepts = { [weak self] p in self?.islandRect.insetBy(dx: -8, dy: -8).contains(p) ?? false }
        dropView.onDragEntered = { [weak self] p in
            guard let self else { return }
            self.app.dragEntered(atIsland: self.toIsland(p))
        }
        dropView.onDragExited = { [weak self] in self?.app.dragExited() }
        dropView.onDropped = { [weak self] urls, text in self?.app.dropped(urls: urls, text: text) }

        container.addSubview(hosting)
        container.addSubview(slimeView)
        container.addSubview(hitView)
        container.addSubview(dropView)
        panel.contentView = container

        app.slime.apply(mode: .hidden, layout: app.notch.layout)
        snapLayout()

        startPolling(interval: Self.idlePoll)
        observeScreenState()
        startKeyMonitors()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppCoordinator.shared.window?.relocateToChosenScreen() }
        }
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func applySettings() {
        fsm.config = app.fsmConfig
        slimeView.invalidate()
        relocateToChosenScreen()
    }

    var debugCounters: DebugCounters {
        DebugCounters(ticks: slimeView.ticks, redraws: slimeView.redraws, paused: slimeView.paused)
    }

    // MARK: - Geometry

    /// The island rectangle as currently drawn, in panel coordinates (AppKit, origin bottom-left).
    var islandRect: CGRect {
        let w = app.notch.liveWidth
        let h = app.notch.liveHeight
        let pf = panel.frame
        return CGRect(x: app.notch.liveX, y: pf.height - h, width: w, height: h)
    }

    /// The island rectangle in screen coordinates.
    func islandScreenRect() -> NSRect {
        islandRect.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
    }

    /// Window point → island coordinates (points, y down from the island's top-left).
    func toIsland(_ windowPoint: CGPoint) -> CGPoint {
        let r = islandRect
        return CGPoint(x: windowPoint.x - r.minX, y: r.maxY - windowPoint.y)
    }

    /// Screen position of the main slime's contact point (AppKit coordinates).
    func mainOriginOnScreen() -> NSPoint {
        let r = islandRect
        let pf = panel.frame
        let o = app.notch.slimeOrigin
        return NSPoint(x: pf.minX + r.minX + o.x, y: pf.minY + r.maxY - o.y)
    }

    /// A desktop-panel sized square around the main slime, so a flight out or home starts and
    /// ends with the slime exactly where the island draws it.
    func mainSlimeScreenRect() -> NSRect {
        let o = mainOriginOnScreen()
        let S = DesktopSlimeController.panelSize
        let size = S * app.slime.radius / DesktopSlimeController.radius
        let contactFromBottom = (S - DesktopSlimeController.contact.y) * size / S
        return NSRect(x: o.x - size / 2, y: o.y - contactFromBottom, width: size, height: size)
    }

    /// Screen point → main R units relative to the main slime's contact point (y down).
    func stagePoint(fromScreen p: NSPoint) -> SIMD2<Double> {
        let o = mainOriginOnScreen()
        let R = Double(app.slime.radius)
        return SIMD2(Double(p.x - o.x) / R, -Double(p.y - o.y) / R)
    }

    // MARK: - Island motion

    private func retarget(closing: Bool) {
        let store = app.notch
        let s = store.islandSize
        let o = store.targetSlimeOrigin
        let corner = store.mode == .expanded ? NotchLayout.expandedCorner : NotchLayout.compactCorner
        let response = closing ? 0.36 : 0.5
        let zeta = closing ? 1.0 : 0.72
        let omega = 2 * Double.pi / response
        func tune(_ sp: inout Spring1D, _ target: Double) {
            sp.omega = omega
            sp.zeta = zeta
            sp.target = target
        }
        slimeView.idleInterval = 0
        tune(&wSpring, s.width)
        tune(&hSpring, s.height)
        tune(&cSpring, corner)
        tune(&rSpring, Double(app.slime.targetRadius))
        tune(&xSpring, store.islandTargetX)
        oSpring.omega = omega
        oSpring.zeta = zeta
        oSpring.target = SIMD2(o.x, o.y)
        motionSettled = false
    }

    private func snapLayout() {
        retarget(closing: false)
        wSpring.value = wSpring.target; wSpring.velocity = 0
        hSpring.value = hSpring.target; hSpring.velocity = 0
        cSpring.value = cSpring.target; cSpring.velocity = 0
        rSpring.value = rSpring.target; rSpring.velocity = 0
        xSpring.value = xSpring.target; xSpring.velocity = 0
        oSpring.value = oSpring.target; oSpring.velocity = .zero
        motionSettled = true
        publishLayout()
    }

    private func targetsDrifted() -> Bool {
        let store = app.notch
        let s = store.islandSize
        let o = store.targetSlimeOrigin
        return abs(wSpring.target - s.width) > 0.01 || abs(hSpring.target - s.height) > 0.01
            || abs(oSpring.target.x - o.x) > 0.01 || abs(oSpring.target.y - o.y) > 0.01
            || abs(rSpring.target - Double(app.slime.targetRadius)) > 0.01
            || abs(xSpring.target - store.islandTargetX) > 0.01
    }

    private func tickLayout(_ dt: Double) {
        if targetsDrifted() { retarget(closing: false) }
        if !motionSettled {
            let steps = max(1, Int((dt * 240).rounded(.up)))
            let h = dt / Double(steps)
            for _ in 0..<steps {
                wSpring.advance(h); hSpring.advance(h); cSpring.advance(h); rSpring.advance(h); xSpring.advance(h); oSpring.advance(h)
            }
            func done(_ sp: Spring1D) -> Bool { abs(sp.value - sp.target) < 0.15 && abs(sp.velocity) < 2 }
            let oDone = simd_distance(oSpring.value, oSpring.target) < 0.15 && simd_length(oSpring.velocity) < 2
            if done(wSpring), done(hSpring), done(cSpring), done(rSpring), done(xSpring), oDone {
                snapLayout()
            } else {
                publishLayout()
            }
        }
        slimeView.updatesPointer = !app.notch.slimeOnDesktop
        if motionSettled, app.notch.mode == .hidden, !app.notch.slimeOnDesktop {
            slimeView.paused = true
        }
    }

    private func publishLayout() {
        let store = app.notch
        let w = wSpring.value
        let h = hSpring.value
        let c = cSpring.value
        if abs(store.liveWidth - w) > 0.01 { store.liveWidth = w }
        if abs(store.liveHeight - h) > 0.01 { store.liveHeight = h }
        if abs(store.liveCorner - c) > 0.01 { store.liveCorner = c }
        let x = xSpring.value
        if abs(store.liveX - x) > 0.01 { store.liveX = x }
        let o = oSpring.value
        if abs(store.liveSlimeOrigin.x - o.x) > 0.01 || abs(store.liveSlimeOrigin.y - o.y) > 0.01 {
            store.liveSlimeOrigin = (o.x, o.y)
        }
        app.slime.radius = CGFloat(rSpring.value)
        slimeView.radius = app.slime.radius
        let r = islandRect
        if slimeView.frame != r { slimeView.frame = r }
        maskLayer.frame = slimeView.bounds
        maskLayer.path = NotchShape(width: w, height: h, cornerRadius: c, topRadius: 0)
            .path(in: CGRect(x: 0, y: 0, width: w, height: h)).cgPath
    }

    // MARK: - FSM

    var fsmState: NotchFSM.State { fsm.state }

    /// Everything keeping the island open right now, scoped (see `NotchFSM.Hold`).
    var holds: Set<NotchFSM.Hold> {
        var h = Set(heldOpenFlags.map { NotchFSM.Hold($0.key, $0.value) })
        if app.notch.isPinned { h.insert(NotchFSM.Hold("pin")) }
        if dragOut != nil { h.insert(NotchFSM.Hold("dragout")) }
        return h
    }

    /// Whether a hold applies in the current state (the global Esc and the debug dump ask).
    var heldOpen: Bool { fsm.isHeld(holds) }

    /// The card waiting on the user, if any.
    var pendingCard: NotchView? { fsm.pendingCard(holds) }

    /// `scope`: `.any` for push-to-talk and drags, `.view(v)` for a focused field or a stream that
    /// only matters while `v` shows, `.card(v)` for a card that waits on the user.
    func hold(_ key: String, _ on: Bool, scope: NotchFSM.Hold.Scope = .any) {
        if on { heldOpenFlags[key] = scope } else { heldOpenFlags[key] = nil }
        if !on, !heldOpen, !wasInIsland, fsm.state.isExpanded, timers.isEmpty {
            send(.pointerLeft)
        }
    }

    /// Seconds left on each armed timer.
    var timerRemaining: [NotchFSM.TimerID: Double] {
        let now = Date()
        return timerDeadlines.mapValues { max(0, $0.timeIntervalSince(now)) }
    }

    func send(_ input: NotchFSM.Input) {
        switch input {
        case .userInteracted, .acknowledged, .click, .open: lastInteraction = Date()
        default: break
        }
        apply(fsm.handle(input, holds: holds))
    }

    /// A notification wants the island. While the user is busy with a card (a hold on it, or an
    /// interaction in the last three seconds) it waits and shows once the island folds.
    func reveal(_ view: NotchView) {
        let busy = fsm.state.isExpanded && (heldOpen || Date().timeIntervalSince(lastInteraction) < 3)
        if busy, app.notch.view != view {
            if !pendingReveals.contains(view) { pendingReveals.append(view) }
            return
        }
        send(.openExternally(view))
    }

    /// A pending card, a queued notification, or nothing: what the island opens next.
    private func presentPendingReveal() {
        guard !pendingReveals.isEmpty, app.notch.mode != .expanded else { return }
        revealWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.app.notch.mode != .expanded, !self.pendingReveals.isEmpty else { return }
            let v = self.pendingReveals.removeFirst()
            self.send(.openExternally(v))
        }
        revealWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func apply(_ effects: [NotchFSM.Effect]) {
        for e in effects {
            switch e {
            case .setState(let s):
                switch s {
                case .hidden: setMode(.hidden, view: app.notch.view)
                case .compact: setMode(.compact, view: .home)
                case .expanded(let v): setMode(.expanded, view: v)
                case .listening: setMode(.expanded, view: .ask)
                }
            case .schedule(let id, let delay):
                timers[id]?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.timers[id] = nil
                    self.timerDeadlines[id] = nil
                    self.send(.timer(id))
                }
                timers[id] = work
                timerDeadlines[id] = Date().addingTimeInterval(delay)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            case .cancel(let id):
                timers[id]?.cancel()
                timers[id] = nil
                timerDeadlines[id] = nil
            case .cancelAll:
                for (_, w) in timers { w.cancel() }
                timers.removeAll()
                timerDeadlines.removeAll()
            case .peek:
                app.slime.sound.play(SoundCue(.hover, rate: 0.9, gain: 0.5))
            }
        }
    }

    private func setMode(_ mode: NotchMode, view: NotchView) {
        let store = app.notch
        let prev = store.mode
        if store.view != view || mode != .expanded {
            // A height measured by one card never carries into the next.
            if store.measuredHeight != nil { store.measuredHeight = nil }
        }
        if store.view != view { store.view = view }
        guard mode != prev else { return }
        store.mode = mode
        app.slime.apply(mode: mode, layout: store.layout)
        retarget(closing: mode.order < prev.order)
        slimeView.paused = false
        if mode == .expanded {
            app.slime.sound.play(SoundCue(.pop, rate: 0.8, gain: 0.35))
        }
        if prev == .expanded {
            app.slime.sound.play(SoundCue(.plip, rate: 0.7, gain: 0.3))
            if !heldOpen { store.isPinned = false }
            if panel.isKeyWindow { panel.resignKey() }
        }
        if mode == .hidden {
            app.slime.pointer = nil
        }
        if mode == .expanded, view == .greeting {
            app.slime.stage.main.greet()
        }
        if prev == .expanded { presentPendingReveal() }
    }

    func launchGreeting() {
        send(.launch)
        greetingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.send(.greetingComplete) }
        greetingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }

    func focusInput() {
        panel.makeKey()
    }

    // MARK: - Polling (click-through and hover)

    private func startPolling(interval: TimeInterval) {
        pollTimer?.invalidate()
        pollTimer = nil
        pollInterval = interval
        guard !screenOff else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { AppCoordinator.shared.window?.pollFrame() }
        }
        timer.tolerance = interval == Self.idlePoll ? 0.04 : interval == Self.nearPoll ? 0.01 : 0.004
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func pollFrame() {
        let mouse = NSEvent.mouseLocation
        followMouseIfNeeded(mouse)
        let pf = panel.frame
        let local = CGPoint(x: mouse.x - pf.minX, y: mouse.y - pf.minY)
        let rect = islandRect
        let hoverRect = !app.notch.geometry.hasNotch && app.notch.mode != .expanded ? rect : rect.insetBy(dx: -6, dy: -6)
        let inIsland = hoverRect.contains(local)

        let shouldAccept = inIsland || dragOut != nil
        if panel.ignoresMouseEvents == shouldAccept {
            panel.ignoresMouseEvents = !shouldAccept
            if shouldAccept, let cv = panel.contentView { panel.invalidateCursorRects(for: cv) }
        }

        // The slime looks at the pointer wherever it is (the gaze fades with distance).
        if app.notch.mode != .hidden {
            let p = toIsland(local)
            if let cur = app.slime.pointer, abs(cur.x - p.x) < 0.5, abs(cur.y - p.y) < 0.5 {
            } else {
                app.slime.pointer = p
            }
        }

        let previously = wasInIsland
        wasInIsland = inIsland
        if app.notch.pointerInside != inIsland { app.notch.pointerInside = inIsland }
        // The mini under the pointer takes over the ticker.
        let hovered: String? = inIsland && app.notch.miniCount > 0 ? { if case .mini(let id) = app.hitSlime(atIsland: toIsland(local)) { return id } else { return nil } }() : nil
        if app.notch.hoveredMiniID != hovered {
            app.notch.hoveredMiniID = hovered
            app.sessions?.publish()
        }
        if inIsland, !previously, dragOut == nil { send(.pointerEntered) }
        if !inIsland, previously { send(.pointerLeft) }

        if let d = dragOut {
            d.tick()
            if d.isFinished {
                dragOut = nil
                hold("dragout", false)
            }
        }

        adjustPollRate(mouse: mouse, panelFrame: pf, islandRect: rect)
    }

    private func adjustPollRate(mouse: NSPoint, panelFrame: NSRect, islandRect: NSRect) {
        let island = islandRect.offsetBy(dx: panelFrame.minX, dy: panelFrame.minY)
        let nearIsland = island.insetBy(dx: -200, dy: -160).contains(mouse)
        // The panel spans the screen, so the "near" band is measured from the island, not the panel.
        let inBand = island.insetBy(dx: -360, dy: -240).contains(mouse)
        let busy = app.notch.mode == .expanded || dragOut != nil || nearIsland
        let wanted = busy ? Self.fastPoll : inBand ? Self.nearPoll : Self.idlePoll
        if wanted != pollInterval { startPolling(interval: wanted) }
        // Nobody near: the quiescent slime breathes at 15 Hz (processed ticks are the idle cost).
        let interval = !motionSettled ? 0 : busy ? 1.0 / 30.0 : 1.0 / 15.0
        if slimeView.idleInterval != interval { slimeView.idleInterval = interval }
    }

    private func observeScreenState() {
        let wc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            wc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AppCoordinator.shared.window?.setScreenOff(true) }
            }
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            wc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AppCoordinator.shared.window?.setScreenOff(false) }
            }
        }
        let dc = DistributedNotificationCenter.default()
        dc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppCoordinator.shared.window?.setScreenOff(true) }
        }
        dc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppCoordinator.shared.window?.setScreenOff(false) }
        }
    }

    private func setScreenOff(_ off: Bool) {
        guard off != screenOff else { return }
        screenOff = off
        if off {
            pollTimer?.invalidate()
            pollTimer = nil
            slimeView.paused = true
            app.desktop?.setPaused(true)
        } else {
            app.slime.stage.resume()
            slimeView.paused = false
            app.desktop?.setPaused(false)
            startPolling(interval: Self.idlePoll)
        }
    }

    // MARK: - Keyboard

    private func startKeyMonitors() {
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return }
            MainActor.assumeIsolated {
                guard let wc = AppCoordinator.shared.window else { return }
                let voice = wc.app.voice!
                if voice.isActive || voice.state == .waiting { voice.cancel(); wc.send(.collapse); return }
                if wc.app.notch.mode == .expanded, !wc.heldOpen { wc.send(.collapse) }
            }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled: Bool = MainActor.assumeIsolated {
                guard let wc = AppCoordinator.shared.window, wc.panel.isKeyWindow else { return false }
                return wc.handleKey(event)
            }
            return handled ? nil : event
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 53 {
            if app.voice.isActive || app.voice.state == .waiting { app.voice.cancel() }
            send(.collapse)
            panel.resignKey()
            return true
        }
        if mods == .command, event.keyCode == 36 {
            app.submitAsk()
            return true
        }
        if mods == .command, event.charactersIgnoringModifiers == "," {
            app.openSettings()
            return true
        }
        if mods == .command, event.charactersIgnoringModifiers == "p" {
            app.notch.isPinned.toggle()
            send(.userInteracted)
            return true
        }
        return false
    }

    // MARK: - Screens

    static func targetScreen(for choice: DisplayChoice) -> NSScreen {
        let screens = NSScreen.screens
        let mouse = NSEvent.mouseLocation
        let candidates = screens.map {
            DisplayCandidate(uuid: displayUUID($0), hasNotch: $0.safeAreaInsets.top > 0, containsMouse: $0.frame.contains(mouse))
        }
        if let i = DisplayResolver.index(for: choice, in: candidates) { return screens[i] }
        return screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? screens[0]
    }

    static func displayUUID(_ screen: NSScreen) -> String? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    static func panelFrame(on screen: NSScreen) -> NSRect {
        let sf = screen.frame
        return NSRect(x: sf.minX, y: sf.maxY - Self.panelHeight, width: sf.width, height: Self.panelHeight)
    }

    static func geometry(for screen: NSScreen) -> NotchGeometry {
        let visibleMenuBar = screen.frame.maxY - screen.visibleFrame.maxY
        let menuBarHeight = visibleMenuBar > 0 ? visibleMenuBar : NSStatusBar.system.thickness
        return NotchGeometry(screenWidth: screen.frame.width, safeAreaTop: screen.safeAreaInsets.top,
                             auxiliaryLeftWidth: screen.auxiliaryTopLeftArea.map { Double($0.width) },
                             auxiliaryRightWidth: screen.auxiliaryTopRightArea.map { Double($0.width) },
                             menuBarHeight: menuBarHeight)
    }

    func relocateToChosenScreen() {
        guard dragOut == nil else { return }
        relocate(to: Self.targetScreen(for: app.settings.displayChoice))
    }

    private func relocate(to screen: NSScreen) {
        currentScreen = screen
        app.notch.geometry = Self.geometry(for: screen)
        let frame = Self.panelFrame(on: screen)
        app.notch.containerWidth = Double(frame.width)
        panel.setFrame(frame, display: true)
        app.slime.apply(mode: app.notch.mode, layout: app.notch.layout)
        if app.notch.mode == .hidden { snapLayout() } else { retarget(closing: false); slimeView.paused = false }
    }

    private func followMouseIfNeeded(_ mouse: NSPoint) {
        guard app.settings.displayChoice == .followMouse, app.notch.mode != .expanded, dragOut == nil else { return }
        if let current = currentScreen, current.frame.contains(mouse) { return }
        guard let target = NSScreen.screens.first(where: { $0.frame.contains(mouse) }), target != currentScreen else { return }
        relocate(to: target)
    }

    // MARK: - Drag-out

    var isDraggingOut: Bool { dragOut != nil && !(dragOut?.isReturning ?? true) }

    func beginDragOut() {
        guard dragOut == nil else { return }
        let session = DragOutSession(app: app, controller: self)
        dragOut = session
        hold("dragout", true)
        session.begin(screen: NSEvent.mouseLocation)
    }

    func dragMoved(screen: NSPoint) {
        dragOut?.update(screen: screen)
    }

    func dragEnded(screen: NSPoint) {
        dragOut?.end(screen: screen)
    }
}
