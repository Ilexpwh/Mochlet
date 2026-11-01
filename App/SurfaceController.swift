import AppKit
import SwiftUI
import SlimeCore

final class CompanionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor final class SurfaceController: NSObject {
    let model: AppModel
    let island = NotchModel()
    private let statusItem: NSStatusItem
    private var workspace: NSWindow?
    private let panel: NSPanel
    private var monitor: Any?
    private var outsideMonitor: Any?
    private var dismissal: Task<Void, Never>?
    private var screen: NSScreen?
    private var pointerMonitor: Any?
    private var dragStart: (origin: CGPoint, pointer: CGPoint)?

    init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        panel = CompanionPanel(contentRect: .init(x: 0, y: 0, width: 680, height: 480), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.title = "Mochlet Companion"
        statusItem.button?.image = NSImage(systemSymbolName: "eyes", accessibilityDescription: "Open Mochlet")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .init(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovableByWindowBackground = false; panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: NotchView(
            model: model, island: island,
            hover: { [weak self] in self?.hover($0) },
            open: { [weak self] in self?.openIsland() },
            collapse: { [weak self] in self?.collapse() },
            interact: { [weak self] in self?.interact() },
            workspace: { [weak self] in self?.showWorkspace() },
            stateChanged: { [weak self] in self?.workChanged() },
            placementChanged: { [weak self] in self?.reposition() },
            dragChanged: { [weak self] in self?.drag($0) },
            dragEnded: { [weak self] in self?.endDrag() }))
        // Coucou's fixed transparent host avoids resizing AppKit around an animating
        // SwiftUI tree. Only the island shape changes size; empty space passes clicks.
        let container = NSView(frame: .init(origin: .zero, size: panel.frame.size))
        container.autoresizingMask = [.width, .height]
        hosting.sizingOptions = []
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        let dropView = FileDropNSView(frame: container.bounds)
        dropView.autoresizingMask = [.width, .height]
        dropView.acceptsPoint = { [weak self] point in
            guard let self else { return false }
            return self.islandFrame.contains(self.panel.convertPoint(toScreen: point))
        }
        dropView.hover = { [weak self] inside in
            guard let self else { return }; self.model.files.hovering = inside
            if inside { self.island.interaction.open(); self.render() }
            self.scheduleDismissal()
        }
        dropView.receive = { [weak self] urls in self?.model.files.ingest(urls) }
        container.addSubview(dropView)
        panel.contentView = container
        panel.ignoresMouseEvents = true
        NotificationCenter.default.addObserver(self, selector: #selector(reposition), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .mouseMoved, .leftMouseDragged]) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self else { return false }
                self.updateHitRegion()
                if event.type == .leftMouseDown {
                    if event.window === self.panel { self.interact() }
                    else { self.outsideClick() }
                }
                if event.type == .keyDown {
                    if event.keyCode == 53, self.panel.isKeyWindow { self.collapse(); return true }
                    if event.modifierFlags.contains([.command, .shift]), event.keyCode == 49 { self.togglePanel(); return true }
                    if event.window === self.panel { self.interact() }
                }
                return false
            }
            return handled ? nil : event
        }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.outsideClick() }
        }
        pointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHitRegion() }
        }
        reposition()
        panel.orderFrontRegardless()
        updateHitRegion()
        scheduleDismissal()
    }

    private var heldOpen: Bool { island.dragging || model.meetings.active || model.files.busy || model.files.hovering || model.speech.active || !model.draft.isEmpty || !model.pendingInputs.isEmpty }
    private var heldVisible: Bool { heldOpen || model.isBusy }

    private func hover(_ inside: Bool) {
        guard !island.dragging, island.interaction.hovered != inside else { return }
        dismissal?.cancel()
        if inside { island.interaction.enter(openOnHover: model.openOnHover) }
        else { island.interaction.leave() }
        render()
        scheduleDismissal()
    }
    private func interact() { island.interaction.interact(); scheduleDismissal() }
    private func openIsland() {
        island.interaction.open(); render()
        panel.makeKeyAndOrderFront(nil)
        scheduleDismissal()
    }
    func openForVoice() { openIsland() }
    private func collapse() {
        island.interaction.collapse(); render()
        panel.resignKey(); scheduleDismissal()
    }
    private func outsideClick() {
        guard island.interaction.mode == .expanded, !heldOpen, !island.interaction.pinned,
              !islandFrame.contains(NSEvent.mouseLocation) else { return }
        collapse()
    }
    private func workChanged() {
        if heldVisible { island.interaction.reveal() }
        render(); scheduleDismissal()
    }
    private func scheduleDismissal() {
        dismissal?.cancel()
        let held = island.interaction.mode == .expanded ? heldOpen : heldVisible
        guard let delay = island.interaction.dismissalDelay(held: held, autoHide: model.hideWhenIdle) else { return }
        dismissal = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            let held = self.island.interaction.mode == .expanded ? self.heldOpen : self.heldVisible
            self.island.interaction.timeout(held: held, autoHide: self.model.hideWhenIdle)
            self.render(); self.scheduleDismissal()
        }
    }

    // Adapted from Coucou's fixed-panel / animated-island arrangement and timings.
    // See LICENSES/Coucou-MIT.txt. No frame timer runs while idle.
    private func render(animated: Bool = true) {
        let mode = island.interaction.mode
        let side = island.edge != .top
        let width: CGFloat = mode == .expanded ? 640 : side ? (mode == .compact ? 48 : 8) : mode == .compact ? island.notchWidth + 112 : island.notchWidth + 12
        let height: CGFloat = mode == .expanded ? 400 + island.topInset : side ? (mode == .compact ? 84 : 56) : mode == .compact ? max(38, island.notchHeight + 4) : island.notchHeight
        let shrinking = width < island.width || height < island.height
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let animation: Animation? = !animated || reduceMotion ? nil : shrinking
            ? .timingCurve(0.45, 0, 0.2, 1, duration: 0.34)
            : .spring(response: 0.5, dampingFraction: 0.72)
        withAnimation(animation) {
            island.width = width; island.height = height
            island.cornerRadius = mode == .expanded ? 24 : 14
            island.topRadius = side ? (mode == .expanded ? 24 : 14) : mode == .expanded ? 0 : -6
        }
        panel.ignoresMouseEvents = !islandFrame.contains(NSEvent.mouseLocation)
    }
    private var islandFrame: CGRect {
        let x = island.edge == .top ? panel.frame.midX - island.width / 2 : island.edge == .left ? panel.frame.minX : panel.frame.maxX - island.width
        let y = island.edge == .top ? panel.frame.maxY - island.height : panel.frame.midY - island.height / 2
        return .init(x: x, y: y, width: island.width, height: island.height)
    }
    private func updateHitRegion() {
        guard !island.dragging else { panel.ignoresMouseEvents = false; return }
        let inside = islandFrame.contains(NSEvent.mouseLocation)
        panel.ignoresMouseEvents = !inside
        hover(inside)
    }
    @objc func reposition() {
        guard !island.dragging else { return }
        screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue == model.dockDisplayID })
            ?? NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first
        island.edge = model.dockEdge
        guard let screen else { return }
        island.hasNotch = screen.safeAreaInsets.top > 0
        island.notchHeight = island.hasNotch ? screen.safeAreaInsets.top : 26
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            island.notchWidth = max(160, screen.frame.width - left.width - right.width)
        } else { island.notchWidth = 170 }
        render(animated: false)
        panel.setFrameOrigin(DockPlacement(edge: model.dockEdge, fraction: model.dockFraction).panelOrigin(in: screen.frame, size: panel.frame.size))
        updateHitRegion()
    }
    private func drag(_ translation: CGSize) {
        let pointer = NSEvent.mouseLocation
        if dragStart == nil {
            dragStart = (panel.frame.origin, .init(x: pointer.x - translation.width, y: pointer.y + translation.height))
            island.dragging = true; dismissal?.cancel()
        }
        guard let start = dragStart else { return }
        panel.ignoresMouseEvents = false
        panel.setFrameOrigin(.init(x: start.origin.x + pointer.x - start.pointer.x, y: start.origin.y + pointer.y - start.pointer.y))
    }
    private func endDrag() {
        guard dragStart != nil else { return }
        dragStart = nil; island.dragging = false
        let pointer = NSEvent.mouseLocation
        guard let destination = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? screen else { return }
        let placement = DockPlacement.nearest(to: pointer, in: destination.frame)
        model.dockDisplayID = (destination.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0
        model.dockEdge = placement.edge; model.dockFraction = placement.fraction
        reposition(); scheduleDismissal()
    }
    @objc func togglePanel() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Open workspace", action: #selector(showWorkspace), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Mochlet", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = menu; statusItem.button?.performClick(nil); statusItem.menu = nil
            return
        }
        if island.interaction.mode == .expanded { collapse() }
        else { openIsland() }
    }
    @objc func showWorkspace() {
        if workspace == nil {
            let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 1000, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "Mochlet"; w.minSize = .init(width: 760, height: 560); w.isReleasedWhenClosed = false
            w.titlebarAppearsTransparent = true
            w.contentView = NSHostingView(rootView: WorkspaceView(model: model)); w.center(); workspace = w
        }
        workspace?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}
