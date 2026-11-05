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
    var miniCount = 0
    var overflowCount = 0
    /// Height measured by a view that grows with its content (question, chat).
    var measuredHeight: Double?
    var isPinned = false
    var pointerInside = false
    var toast: Toast?
    var askText = ""
    var askSuggestions: [String] = []
    var tickerText = ""
    var chewProgress: Double?
    var fileDragOver = false
    /// Live island size and corner, driven by the window controller's springs every frame.
    var liveWidth: Double = NotchGeometry.fallback.width
    var liveHeight: Double = NotchGeometry.fallback.height
    var liveCorner: Double = NotchLayout.compactCorner
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

    /// Plan pills shown in the compact strip (the coordinator keeps it current).
    var pillCount = 0
    /// Selected Settings tab (so the debug channel and deep links can open one).
    var settingsTab = "general"

    var layout: NotchLayout { NotchLayout(geometry: geometry) }

    /// Target island size for the current mode and view (the live size springs toward it).
    var islandSize: (width: Double, height: Double) {
        layout.size(mode: mode, view: view, miniCount: min(miniCount, 6), measuredHeight: mode == .expanded ? measuredHeight : nil, mainAway: slimeOnDesktop,
                    ticker: !tickerText.isEmpty, pills: pillCount)
    }

    /// Bottom padding of expanded content: leaves the tray free when minis are around.
    var contentBottom: Double { 12 + (miniCount > 0 ? NotchLayout.trayHeight : 0) }
    /// Where the compact ticker starts: after the notch, the main slime's wing and the mini row.
    var tickerLeading: Double { geometry.width + (slimeOnDesktop ? 0 : NotchLayout.compactWing) + NotchLayout.miniRowWidth(miniCount: min(miniCount, 6)) + 6 }

    /// Target contact point of the main slime for the current mode.
    var targetSlimeOrigin: (x: Double, y: Double) {
        layout.slimeOrigin(mode: mode, view: view, islandSize: islandSize)
    }

    /// Where the main slime is right now: hit tests, drags and drawing all use this.
    var slimeOrigin: (x: Double, y: Double) { liveSlimeOrigin }

    var contentLeading: Double { slimeOnDesktop ? NotchLayout.expandedContentLeadingAway : NotchLayout.expandedContentLeading }
}
