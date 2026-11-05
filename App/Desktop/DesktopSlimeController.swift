import AppKit
import simd
import SlimeKit
import SlimeKitUI
import MochletCore

/// The main slime set loose on the desktop: its own floating panel wherever it was dropped (it
/// hugs screen edges and corners), eyes on the cursor, the same click grammar as in the notch,
/// dragged to move, dropped back on the notch to come home. It flies home for alerts and returns
/// when they clear (wired by milestone 4). Position and state persist across launches.
@MainActor
final class DesktopSlimeController {
    enum Phase: Equatable { case home, flyingOut, onDesktop, flyingHome }

    static let panelSize: CGFloat = 184
    static let radius: CGFloat = 56
    static let margin: CGFloat = 10
    static let snapDistance: CGFloat = 64
    /// Contact point inside the panel (y down).
    static var contact: CGPoint { CGPoint(x: panelSize / 2, y: panelSize - 22) }

    private unowned let app: AppCoordinator
    private(set) var phase: Phase = .home
    private(set) var panel: NSPanel?
    private var view: SlimeStageLayerView?
    private(set) var isDragging = false
    private var dragStart: NSPoint = .zero
    private var originAtStart: NSPoint = .zero
    private var keepEnabled = false

    var isActive: Bool { phase != .home }
    var panelFrame: NSRect? { panel?.frame }

    init(app: AppCoordinator) {
        self.app = app
    }

    // MARK: - Out and home

    /// At launch (after the greeting): fly out if the slime lived on the desktop last time.
    func restoreIfEnabled() {
        guard app.settings.desktopSlime, phase == .home else { return }
        flyOut(to: savedCenter() ?? defaultCenter(), from: app.window.mainSlimeScreenRect())
    }

    func savedCenter() -> NSPoint? {
        let s = app.settings
        guard s.desktopSlimeX >= 0, s.desktopSlimeY >= 0 else { return nil }
        return NSPoint(x: s.desktopSlimeX + Self.panelSize / 2, y: s.desktopSlimeY + Self.panelSize / 2)
    }

    func defaultCenter() -> NSPoint {
        let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return NSPoint(x: vf.maxX - Self.margin - Self.panelSize / 2, y: vf.minY + Self.margin + Self.panelSize / 2)
    }

    /// Lets the slime out, landing centred on `center` (screen coordinates). `from` is where the
    /// flight starts (the island slime, or the drag ghost).
    func flyOut(to center: NSPoint, from: NSRect?) {
        guard phase == .home else { return }
        phase = .flyingOut
        app.notch.slimeOnDesktop = true
        app.settings.desktopSlime = true
        let s = Self.panelSize
        let target = snap(clampToScreen(NSRect(x: center.x - s / 2, y: center.y - s / 2, width: s, height: s)))
        let p = makePanel(frame: from ?? target)
        panel = p
        p.orderFrontRegardless()
        let main = app.slime.stage.main
        main.setAway(false)
        main.setEyeOverride(.wide, for: 0.5)
        app.slime.sound.play(SoundCue(.jump))
        animate(p, to: target, duration: from == nil ? 0.25 : 0.5) { [weak self] in self?.landed() }
    }

    private func landed() {
        guard phase == .flyingOut else { return }
        phase = .onDesktop
        app.slime.stage.main.impulse(.landing(speed: 3))
        app.slime.stage.main.trigger(.happy)
        app.slime.sound.play(SoundCue(.land))
        persist()
    }

    /// Flies back into the notch. `forAlert` keeps the desktop preference so it comes back later.
    func flyHome(forAlert: Bool = false) {
        guard let p = panel, phase == .onDesktop || phase == .flyingOut else { return }
        phase = .flyingHome
        isDragging = false
        keepEnabled = forAlert
        if !forAlert { app.settings.desktopSlime = false }
        app.slime.stage.main.setEyeOverride(.happyArc, for: 0.6)
        app.slime.sound.play(SoundCue(.jump))
        animate(p, to: app.window.mainSlimeScreenRect(), duration: 0.45) { [weak self] in self?.arrivedHome() }
    }

    private func arrivedHome() {
        guard phase == .flyingHome else { return }
        panel?.orderOut(nil)
        panel = nil
        view = nil
        phase = .home
        app.notch.slimeOnDesktop = false
        app.slime.stage.main.impulse(.landing(speed: 2.5))
        app.slime.sound.play(SoundCue(.land))
        app.window.send(.userInteracted)
    }

    func retractForAlert() {
        if phase == .onDesktop { flyHome(forAlert: true) }
    }

    func returnAfterAlert() {
        guard phase == .home, keepEnabled else { return }
        keepEnabled = false
        restoreIfEnabled()
    }

    func move(toCenter c: NSPoint) {
        guard let p = panel, phase == .onDesktop else { return }
        let s = Self.panelSize
        let f = snap(clampToScreen(NSRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s)))
        animate(p, to: f, duration: 0.3, completion: nil)
        persist(frame: f)
    }

    func setPaused(_ paused: Bool) {
        view?.paused = paused
    }

    // MARK: - Dragging (the engine reports dragOutBegan; the coordinator routes it here)

    func beginDrag() {
        guard let p = panel, phase == .onDesktop, !isDragging else { return }
        isDragging = true
        dragStart = NSEvent.mouseLocation
        originAtStart = p.frame.origin
        app.slime.stage.main.setEyeOverride(.wide, for: 0.4)
        app.slime.sound.play(SoundCue(.blip))
    }

    func dragMoved(screen m: NSPoint) {
        guard let p = panel, isDragging else { return }
        let dx = m.x - dragStart.x
        let dy = m.y - dragStart.y
        p.setFrameOrigin(NSPoint(x: originAtStart.x + dx, y: originAtStart.y + dy))
        app.slime.stage.main.setLean(clamp(Double(dx) * 0.0015, -0.25, 0.25), duration: 0.12)
    }

    func dragEnded(screen m: NSPoint) {
        guard let p = panel, isDragging else { return }
        isDragging = false
        app.slime.stage.main.setLean(0, duration: 0.35)
        if app.window.islandScreenRect().insetBy(dx: -40, dy: -40).contains(m) {
            flyHome()
            return
        }
        if NSEvent.modifierFlags.contains(.option), let target = WindowProbe.windowUnder(m) {
            app.attachWindow(target)
        }
        let snapped = snap(clampToScreen(p.frame))
        if snapped != p.frame { animate(p, to: snapped, duration: 0.22, completion: nil) }
        app.slime.stage.main.impulse(.landing(speed: 2))
        app.slime.sound.play(SoundCue(.plip))
        persist(frame: snapped)
    }

    // MARK: - Geometry

    /// Screen point → main R units relative to the slime's contact point (y down).
    func localPoint(_ screen: NSPoint) -> SIMD2<Double> {
        guard let p = panel else { return .zero }
        let scale = p.frame.height / Self.panelSize
        let R = Double(Self.radius * scale)
        let contact = NSPoint(x: p.frame.minX + Self.contact.x * scale, y: p.frame.minY + (Self.panelSize - Self.contact.y) * scale)
        return SIMD2(Double(screen.x - contact.x) / R, -Double(screen.y - contact.y) / R)
    }

    /// Whether a screen point is on the slime's body.
    func hit(_ screen: NSPoint) -> Bool {
        guard let p = panel, p.frame.contains(screen) else { return false }
        return app.slime.stage.hitTest(localPoint(screen)) == .main
    }

    private func viewPoint(_ screen: NSPoint) -> CGPoint? {
        guard let p = panel else { return nil }
        return CGPoint(x: screen.x - p.frame.minX, y: p.frame.maxY - screen.y)
    }

    private func clampToScreen(_ r: NSRect) -> NSRect {
        let centre = NSPoint(x: r.midX, y: r.midY)
        let vf = (WindowProbe.screen(containing: centre) ?? NSScreen.screens[0]).visibleFrame
        let m = Self.margin
        var out = r
        out.origin.x = min(max(r.minX, vf.minX + m), vf.maxX - r.width - m)
        out.origin.y = min(max(r.minY, vf.minY + m), vf.maxY - r.height - m)
        return out
    }

    /// Hugs the nearest screen edges, so a drop near a corner lands exactly in it.
    private func snap(_ r: NSRect) -> NSRect {
        let centre = NSPoint(x: r.midX, y: r.midY)
        let vf = (WindowProbe.screen(containing: centre) ?? NSScreen.screens[0]).visibleFrame
        let m = Self.margin
        var out = r
        if r.minX - vf.minX < Self.snapDistance { out.origin.x = vf.minX + m }
        else if vf.maxX - r.maxX < Self.snapDistance { out.origin.x = vf.maxX - m - r.width }
        if r.minY - vf.minY < Self.snapDistance { out.origin.y = vf.minY + m }
        else if vf.maxY - r.maxY < Self.snapDistance { out.origin.y = vf.maxY - m - r.height }
        return out
    }

    private func persist(frame: NSRect? = nil) {
        guard let f = frame ?? panel?.frame else { return }
        app.settings.desktopSlimeX = f.minX
        app.settings.desktopSlimeY = f.minY
        app.settings.desktopSlime = true
    }

    // MARK: - Panel

    private func makePanel(frame: NSRect) -> NSPanel {
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = .floating
        p.depthLimit = .twentyfourBitRGB
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.isMovableByWindowBackground = false
        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.autoresizingMask = [.width, .height]
        let v = SlimeStageLayerView(stage: app.slime.stage, radius: Self.radius, origin: { size in
            let scale = size.height / Self.panelSize
            return CGPoint(x: Self.contact.x * scale, y: Self.contact.y * scale)
        })
        v.include = { $0.id == nil }
        v.drainsCues = false
        v.pointer = { [weak self] in self?.viewPoint(NSEvent.mouseLocation) }
        v.onTick = { [weak self] view, _ in self?.tick(view) }
        v.frame = container.bounds
        v.autoresizingMask = [.width, .height]
        let hit = DesktopHitView(app: app, controller: self)
        hit.frame = container.bounds
        hit.autoresizingMask = [.width, .height]
        container.addSubview(v)
        container.addSubview(hit)
        p.contentView = container
        view = v
        return p
    }

    private func tick(_ v: SlimeStageLayerView) {
        guard let p = panel else { return }
        v.radius = Self.radius * v.bounds.height / Self.panelSize
        let mouse = NSEvent.mouseLocation
        let wants = isDragging || hit(mouse)
        if p.ignoresMouseEvents == wants { p.ignoresMouseEvents = !wants }
        let near = isDragging || phase != .onDesktop || p.frame.insetBy(dx: -120, dy: -120).contains(mouse)
        let interval = near ? 1.0 / 30.0 : 1.0 / 15.0
        if v.idleInterval != interval { v.idleInterval = interval }
    }

    private func animate(_ p: NSPanel, to frame: NSRect, duration: Double, completion: (@MainActor @Sendable () -> Void)?) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0.05, 0.25, 1.0)
            p.animator().setFrame(frame, display: true)
        }, completionHandler: {
            MainActor.assumeIsolated { completion?() }
        })
    }
}

/// Mouse events on the desktop panel, only when the pointer is on the slime's body.
final class DesktopHitView: NSView {
    unowned let app: AppCoordinator
    unowned let controller: DesktopSlimeController
    private var pressing = false

    init(app: AppCoordinator, controller: DesktopSlimeController) {
        self.app = app
        self.controller = controller
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        pressing || controller.hit(NSEvent.mouseLocation) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        pressing = true
        app.slime.stage.main.pressBegan(at: controller.localPoint(NSEvent.mouseLocation))
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressing else { return }
        if controller.isDragging {
            controller.dragMoved(screen: NSEvent.mouseLocation)
        } else {
            app.slime.stage.main.pressMoved(to: controller.localPoint(NSEvent.mouseLocation))
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard pressing else { return }
        pressing = false
        if controller.isDragging {
            controller.dragEnded(screen: NSEvent.mouseLocation)
        } else {
            app.slime.stage.main.pressEnded()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(app.contextMenu(), with: event, for: self)
    }
}
