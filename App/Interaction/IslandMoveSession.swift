import AppKit
import MochletCore

/// Dragging the island along the top edge of its screen. The island follows the pointer, pulls
/// toward the three preset anchors as it comes near them, and on release settles on the nearest
/// preset (or a custom spot) which is then remembered for the display.
@MainActor
final class IslandMoveSession {
    private unowned let app: AppCoordinator
    private unowned let controller: NotchWindowController
    /// Pointer x minus the island's left edge at the grab, so the island does not jump.
    private let grabOffset: Double
    private(set) var moved = false

    init(app: AppCoordinator, controller: NotchWindowController, panelX: Double) {
        self.app = app
        self.controller = controller
        grabOffset = panelX - app.notch.liveX
    }

    private var presetMinXs: [(anchor: IslandAnchor, minX: Double)] {
        let n = app.notch
        let width = n.islandSize.width
        return IslandAnchor.presets.map { a in
            (a, n.layout.islandMinX(anchor: a, mode: n.mode, width: width, mainAway: n.slimeOnDesktop, containerWidth: n.containerWidth))
        }
    }

    func update(panelX: Double) {
        moved = true
        let n = app.notch
        let width = n.islandSize.width
        var x = min(max(0, n.containerWidth - width), max(0, panelX - grabOffset))
        // Magnetic presets: inside the snap distance the island eases onto the anchor.
        if let near = presetMinXs.min(by: { abs($0.minX - x) < abs($1.minX - x) }), abs(near.minX - x) < NotchLayout.snapDistance {
            let pull = 1 - abs(near.minX - x) / NotchLayout.snapDistance
            x = x + (near.minX - x) * pull * 0.7
        }
        controller.setMoveX(x)
    }

    func end(panelX: Double) {
        let n = app.notch
        let width = n.islandSize.width
        let x = min(max(0, n.containerWidth - width), max(0, panelX - grabOffset))
        let anchor = n.layout.snapAnchor(forMinX: x, width: width, mode: n.mode, mainAway: n.slimeOnDesktop, containerWidth: n.containerWidth)
        controller.setAnchor(moved ? anchor : n.anchor, persist: moved)
    }
}
