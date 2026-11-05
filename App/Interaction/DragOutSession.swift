import AppKit
import SwiftUI
import simd
import SlimeKit
import SlimeKitUI

/// Dragging the slime out of the notch. A ghost copy follows the pointer in its own panel.
/// Drop it anywhere and it moves there as the desktop companion; drop it back on the notch (or
/// cancel) and it springs home; hold ⌥ over a window to attach that window as context instead.
@MainActor
final class DragOutSession {
    private unowned let app: AppCoordinator
    private unowned let controller: NotchWindowController
    private var ghostPanel: NSPanel?
    private var highlightPanel: NSPanel?
    private var highlighted: WindowProbe.TargetWindow?
    private(set) var isReturning = false
    private let ghostSize: CGFloat = 260
    private var ghostRadius: CGFloat = 30

    var isFinished: Bool { app.slime.stage.ghost == nil && ghostPanel == nil }

    init(app: AppCoordinator, controller: NotchWindowController) {
        self.app = app
        self.controller = controller
    }

    func begin(screen: NSPoint) {
        ghostRadius = max(24, app.slime.radius)
        app.slime.stage.beginDragOut(at: controller.stagePoint(fromScreen: screen))
        let panel = NSPanel(contentRect: NSRect(x: screen.x - ghostSize / 2, y: screen.y - ghostSize / 2, width: ghostSize, height: ghostSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 4)
        panel.depthLimit = .twentyfourBitRGB
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let view = GhostView(stage: app.slime.stage, radius: ghostRadius, size: ghostSize)
        panel.contentView = NSHostingView(rootView: view)
        panel.orderFrontRegardless()
        ghostPanel = panel
    }

    func update(screen: NSPoint) {
        app.slime.stage.updateDragOut(target: controller.stagePoint(fromScreen: screen))
        let target = NSEvent.modifierFlags.contains(.option) ? WindowProbe.windowUnder(screen) : nil
        if target != highlighted {
            highlighted = target
            showHighlight(target)
        }
    }

    func end(screen: NSPoint) {
        showHighlight(nil)
        let homeZone = controller.islandScreenRect().insetBy(dx: -24, dy: -24)
        if NSEvent.modifierFlags.contains(.option), let target = WindowProbe.windowUnder(screen) {
            isReturning = true
            app.slime.stage.endDragOut(dropped: false)
            app.attachWindow(target)
        } else if homeZone.contains(screen) {
            isReturning = true
            app.slime.stage.endDragOut(dropped: false)
        } else {
            let from = ghostScreenRect()
            app.slime.stage.endDragOut(dropped: true)
            closeGhost()
            app.desktop.flyOut(to: screen, from: from)
        }
    }

    /// Where the ghost is on screen, as a desktop-panel sized square around it.
    private func ghostScreenRect() -> NSRect {
        let S = DesktopSlimeController.panelSize
        let size = S * ghostRadius / DesktopSlimeController.radius
        let centre: NSPoint
        if let ghost = app.slime.stage.ghost {
            let o = controller.mainOriginOnScreen()
            let R = app.slime.radius
            centre = NSPoint(x: o.x + CGFloat(ghost.body.root.x) * R, y: o.y - CGFloat(ghost.body.root.y) * R)
        } else {
            centre = NSEvent.mouseLocation
        }
        let contactFromBottom = (S - DesktopSlimeController.contact.y) * size / S
        return NSRect(x: centre.x - size / 2, y: centre.y - contactFromBottom, width: size, height: size)
    }

    /// Per poll frame: the ghost panel follows the spring; the panel closes once the ghost is gone.
    func tick() {
        guard let panel = ghostPanel else { return }
        guard let ghost = app.slime.stage.ghost else {
            closeGhost()
            return
        }
        let o = controller.mainOriginOnScreen()
        let R = app.slime.radius
        let root = ghost.body.root
        let centre = NSPoint(x: o.x + CGFloat(root.x) * R, y: o.y - CGFloat(root.y) * R)
        panel.setFrameOrigin(NSPoint(x: centre.x - ghostSize / 2, y: centre.y - ghostSize / 2))
    }

    private func closeGhost() {
        ghostPanel?.orderOut(nil)
        ghostPanel = nil
        highlightPanel?.orderOut(nil)
        highlightPanel = nil
    }

    private func showHighlight(_ target: WindowProbe.TargetWindow?) {
        guard let target else {
            highlightPanel?.orderOut(nil)
            highlightPanel = nil
            return
        }
        let panel = highlightPanel ?? {
            let p = NSPanel(contentRect: target.bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            p.contentView = NSHostingView(rootView: HighlightView())
            return p
        }()
        panel.setFrame(target.bounds, display: true)
        panel.orderFrontRegardless()
        highlightPanel = panel
    }
}

struct HighlightView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color.white.opacity(0.9), lineWidth: 3)
            .padding(2)
            .shadow(color: .black.opacity(0.4), radius: 6)
    }
}

/// Draws the stage's ghost at the centre of its own panel. The stage itself is advanced by the
/// island view; this only reads the ghost's current frame.
struct GhostView: View {
    let stage: SlimeStage
    let radius: CGFloat
    let size: CGFloat

    var body: some View {
        TimelineView(.animation) { _ in
            Canvas(rendersAsynchronously: false) { ctx, _ in
                guard let ghost = stage.ghost else { return }
                let frame = ghost.frame()
                let centre = CGPoint(x: size / 2, y: size / 2)
                let origin = CGPoint(x: centre.x - CGFloat(frame.root.x) * radius, y: centre.y - CGFloat(frame.root.y) * radius)
                SlimeRenderer.draw(frame, theme: stage.theme, in: &ctx, origin: origin, radius: radius)
            }
        }
        .frame(width: size, height: size)
    }
}
