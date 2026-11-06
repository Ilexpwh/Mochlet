import AppKit

/// Sits above the SwiftUI island. It takes mouse events when the pointer is on a slime
/// (hit-tested through the stage), when ⌘ is held anywhere on the island, or on the bare compact
/// strip, so buttons underneath keep working while the island can still be dragged along the edge.
final class SlimeHitView: NSView {
    unowned let app: AppCoordinator
    unowned let controller: NotchWindowController
    private var pressing = false
    /// A press that may become an island move: where it started (window x) and whether it has.
    private var moveStartX: CGFloat?
    private var moving = false
    private static let moveThreshold: CGFloat = 4

    init(app: AppCoordinator, controller: NotchWindowController) {
        self.app = app
        self.controller = controller
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func islandPoint(_ windowPoint: NSPoint) -> CGPoint? {
        let r = controller.islandRect
        guard r.contains(windowPoint) || pressing || moveStartX != nil else { return nil }
        return CGPoint(x: windowPoint.x - r.minX, y: r.maxY - windowPoint.y)
    }

    private var commandDown: Bool { NSEvent.modifierFlags.contains(.command) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let w = convert(point, from: superview)
        guard let p = islandPoint(convert(w, to: nil)) else { return nil }
        if commandDown { return self }
        if app.hitSlime(atIsland: p) != .none { return self }
        // The bare strip (hidden or compact) has no controls: dragging it moves the island.
        return app.notch.mode != .expanded ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let p = islandPoint(event.locationInWindow) else { return }
        controller.send(.userInteracted)
        if commandDown || app.hitSlime(atIsland: p) == .none {
            moveStartX = event.locationInWindow.x
            moving = false
            return
        }
        pressing = true
        app.slimePressed(atIsland: p)
    }

    override func mouseDragged(with event: NSEvent) {
        if let start = moveStartX {
            let x = event.locationInWindow.x
            if !moving, abs(x - start) >= Self.moveThreshold {
                moving = true
                controller.beginIslandMove(panelX: Double(start))
            }
            if moving { controller.islandMoveUpdated(panelX: Double(x)) }
            return
        }
        guard pressing else { return }
        let r = controller.islandRect
        let w = event.locationInWindow
        app.slimeMoved(toIsland: CGPoint(x: w.x - r.minX, y: r.maxY - w.y), screen: NSEvent.mouseLocation)
    }

    override func mouseUp(with event: NSEvent) {
        if moveStartX != nil {
            moveStartX = nil
            if moving { controller.endIslandMove(panelX: Double(event.locationInWindow.x)) }
            moving = false
            return
        }
        guard pressing else { return }
        pressing = false
        app.slimeReleased(screen: NSEvent.mouseLocation)
    }

    override func rightMouseDown(with event: NSEvent) {
        controller.send(.userInteracted)
        NSMenu.popUpContextMenu(app.contextMenu(), with: event, for: self)
    }
}
