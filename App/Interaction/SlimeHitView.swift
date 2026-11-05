import AppKit

/// Sits above the SwiftUI island and takes mouse events only when the pointer is on a slime
/// (hit-tested through the stage), so buttons underneath keep working.
final class SlimeHitView: NSView {
    unowned let app: AppCoordinator
    unowned let controller: NotchWindowController
    private var pressing = false

    init(app: AppCoordinator, controller: NotchWindowController) {
        self.app = app
        self.controller = controller
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func islandPoint(_ windowPoint: NSPoint) -> CGPoint? {
        let r = controller.islandRect
        guard r.contains(windowPoint) || pressing else { return nil }
        return CGPoint(x: windowPoint.x - r.minX, y: r.maxY - windowPoint.y)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let w = convert(point, from: superview)
        guard let p = islandPoint(convert(w, to: nil)) else { return nil }
        return app.hitSlime(atIsland: p) != .none ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let p = islandPoint(event.locationInWindow) else { return }
        pressing = true
        controller.send(.userInteracted)
        app.slimePressed(atIsland: p)
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressing else { return }
        let r = controller.islandRect
        let w = event.locationInWindow
        app.slimeMoved(toIsland: CGPoint(x: w.x - r.minX, y: r.maxY - w.y), screen: NSEvent.mouseLocation)
    }

    override func mouseUp(with event: NSEvent) {
        guard pressing else { return }
        pressing = false
        app.slimeReleased(screen: NSEvent.mouseLocation)
    }

    override func rightMouseDown(with event: NSEvent) {
        controller.send(.userInteracted)
        NSMenu.popUpContextMenu(app.contextMenu(), with: event, for: self)
    }
}
