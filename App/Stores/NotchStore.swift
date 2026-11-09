import Foundation
import Observation
import MochletCore

struct Toast: Equatable {
    var text: String
    var symbol: String?
}

/// What the island shows: mode, view, geometry and transient content. Views observe it.
@MainActor
@Observable
final class NotchStore {
    var mode: NotchMode = .hidden
    var view: NotchView = .home
    var geometry: NotchGeometry = .fallback
    /// Width of the strip panel the island slides along (the screen's width).
    var containerWidth: Double = 720
    /// Where the island sits along the top edge of the current screen.
    var anchor: IslandAnchor = .center
    /// Away from the notch: another anchor, or a screen without one.
    var detached: Bool { !geometry.hasNotch || !anchor.isCenter }
    var miniCount = 0
    var overflowCount = 0
    /// Height measured by a view that grows with its content (question, chat).
    var measuredHeight: Double?
    /// A pinned island ignores every auto-close until unpinned (⌘P, the header pin).
    var isPinned = false
    var pointerInside = false
    var toast: Toast?
    var askText = ""
    var askSuggestions: [String] = []
    var tickerText = ""
    var chewProgress: Double?
    var fileDragOver = false
    /// Natural width of the compact overlay right of the mini row (ticker, ring, pills), measured
    /// by the view so the strip is always wide enough.
    var compactRightWidth: Double = 0
    /// Live island size, corner and left edge, driven by the window controller's springs every frame.
    var liveWidth: Double = NotchGeometry.fallback.width
    var liveHeight: Double = NotchGeometry.fallback.height
    var liveCorner: Double = NotchLayout.compactCorner
    var liveX: Double = 0
    /// Radius of the top corners (0 against the notch, rounded when detached).
    var liveTopRadius: Double = 0
    /// Live contact point of the main slime (island coordinates, y down), springing between modes.
    var liveSlimeOrigin: (x: Double, y: Double) = (NotchLayout.compactWing / 2, NotchGeometry.fallback.height - 2)
    /// The main slime is away on the desktop (or flying there and back).
    var slimeOnDesktop = false
    /// Session shown by the detail/diff views and the ticker.
    var focusedSessionID: String?
    /// Mini slime under the pointer (its session takes over the ticker).
    var hoveredMiniID: String?
    var focusedDiffID: String?
    /// Short note shown on cards ("Handled in iTerm."), cleared after a few seconds.
    var cardNote: String?
    @ObservationIgnored private var noteWork: DispatchWorkItem?

    func showNote(_ text: String, seconds: Double = 3) {
        cardNote = text
        noteWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.cardNote = nil }
        noteWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    /// Selected Settings tab (so the debug channel and deep links can open one).
    var settingsTab = "general"
    /// "new" asks the projects card to open the task field on the first project.
    var projectsFocus: String?

    var layout: NotchLayout { NotchLayout(geometry: geometry, detached: detached) }

    /// Target island size for the current mode and view (the live size springs toward it).
    var islandSize: (width: Double, height: Double) {
        layout.size(mode: mode, view: view, miniCount: min(miniCount, 6), measuredHeight: mode == .expanded ? measuredHeight : nil, mainAway: slimeOnDesktop,
                    rightContent: compactRightWidth)
    }

    /// Target left edge of the island inside the panel.
    var islandTargetX: Double {
        layout.islandMinX(anchor: anchor, mode: mode, width: islandSize.width, mainAway: slimeOnDesktop, containerWidth: containerWidth)
    }

    var targetTopRadius: Double { layout.topRadius(mode: mode) }

    /// A card reports the height of its content; the island height follows within the view's range.
    func setMeasured(content: Double, for view: NotchView) {
        guard view == self.view else { return }
        let total = content + geometry.height + 4 + contentBottom
        let range = NotchLayout.heightRange(view)
        let clamped = min(range.upperBound, max(range.lowerBound, total))
        if measuredHeight != clamped { measuredHeight = clamped }
    }

    /// Bottom padding of expanded content: leaves the tray free when minis are around.
    var contentBottom: Double { 12 + (miniCount > 0 ? NotchLayout.trayHeight : 0) }
    /// The tallest a card's content can be before the island hits the view's ceiling.
    func contentMaxHeight(for view: NotchView) -> Double {
        NotchLayout.heightRange(view).upperBound - (geometry.height + 4) - contentBottom
    }
    /// Where the compact ticker starts: after the notch, the main slime's wing and the mini row.
    var tickerLeading: Double { layout.tickerLeading(miniCount: min(miniCount, 6), mainAway: slimeOnDesktop) }

    /// Target contact point of the main slime for the current mode.
    var targetSlimeOrigin: (x: Double, y: Double) {
        layout.slimeOrigin(mode: mode, view: view, islandSize: islandSize)
    }

    /// Where the main slime is right now: hit tests, drags and drawing all use this.
    var slimeOrigin: (x: Double, y: Double) { liveSlimeOrigin }

    var contentLeading: Double { slimeOnDesktop ? NotchLayout.expandedContentLeadingAway : NotchLayout.expandedContentLeading }
}
