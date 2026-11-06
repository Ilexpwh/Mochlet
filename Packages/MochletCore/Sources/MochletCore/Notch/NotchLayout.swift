import Foundation

public enum NotchMode: String, Sendable, Codable, Equatable {
    case hidden, compact, expanded

    public var order: Int {
        switch self {
        case .hidden: return 0
        case .compact: return 1
        case .expanded: return 2
        }
    }
}

/// Island sizes per mode and view, and where the slime sits inside them.
public struct NotchLayout: Sendable, Equatable {
    public static let expandedWidth: Double = 640
    public static let compactWing: Double = 84
    public static let miniPitchPoints: Double = 26
    public static let compactCorner: Double = 14
    public static let expandedCorner: Double = 22
    public static let earRadius: Double = 14
    /// Where expanded content starts, leaving the hero slime its room on the left.
    public static let expandedContentLeading: Double = 206
    public static let expandedContentLeadingAway: Double = 28
    /// Main slime radius while the island is expanded.
    public static let expandedSlimeRadius: Double = 56
    /// Bottom strip of the expanded island where the mini slimes line up.
    public static let trayHeight: Double = 30
    /// Mini radius in the tray, in points, and the pitch between minis.
    public static let trayMiniRadius: Double = 14.5
    public static let trayPitch: Double = 36
    /// The compact ticker never grows past this; longer text truncates in the middle.
    public static let tickerMaxWidth: Double = 240

    public var geometry: NotchGeometry

    public init(geometry: NotchGeometry) {
        self.geometry = geometry
    }

    /// Height of each expanded view. `question` and `chat` can be taller (host passes a measured height).
    public static func viewHeight(_ view: NotchView) -> Double {
        switch view {
        case .greeting: return 150
        case .home: return 160
        case .ask: return 156
        case .menu: return 196
        case .approval: return 160
        case .question: return 180
        case .chat: return 260
        case .diff: return 320
        case .sessionDetail: return 220
        case .meetingLive: return 220
        case .ingest: return 150
        case .projects, .knowledge, .signals: return 240
        case .toast: return 120
        case .whatsNew: return 236
        }
    }

    /// Width of the mini row in the compact strip.
    public static func miniRowWidth(miniCount: Int) -> Double {
        miniCount == 0 ? 0 : 24 + Double(miniCount) * Self.miniPitchPoints
    }

    /// Right wing of the compact strip: the mini row, then whatever the strip overlay measured
    /// (ticker, chew ring, REC pill, plan pills), so nothing ever wraps or hides under the notch.
    public func compactRightWing(miniCount: Int, rightContent: Double = 0) -> Double {
        let extra = rightContent > 0 ? rightContent + 10 : 0
        return max(Self.compactWing, Self.miniRowWidth(miniCount: miniCount) + 12 + extra)
    }

    /// Left wing of the compact strip: the main slime's room, none while it is away on the desktop.
    public func leftWing(mode: NotchMode, mainAway: Bool) -> Double {
        mode == .compact && !mainAway ? Self.compactWing : 0
    }

    /// `mainAway`: the main slime lives on the desktop, so the island keeps no room for it.
    /// `measuredHeight` already includes paddings and the tray. `rightContent` is the measured
    /// natural width of the compact overlay right of the mini row.
    public func size(mode: NotchMode, view: NotchView, miniCount: Int = 0, measuredHeight: Double? = nil, mainAway: Bool = false,
                     rightContent: Double = 0) -> (width: Double, height: Double) {
        switch mode {
        case .hidden:
            return (geometry.width, geometry.height)
        case .compact:
            return (geometry.width + leftWing(mode: mode, mainAway: mainAway) + compactRightWing(miniCount: miniCount, rightContent: rightContent), geometry.height)
        case .expanded:
            let range = Self.heightRange(view)
            let natural = Self.viewHeight(view) + (miniCount > 0 ? Self.trayHeight : 0)
            return (Self.expandedWidth, measuredHeight.map { min(range.upperBound, max(range.lowerBound, $0)) } ?? natural)
        }
    }

    /// Left edge of the island inside a container of `containerWidth` whose centre is the notch:
    /// the notch slot of the compact strip stays on the camera whatever the right wing grows to.
    public func islandMinX(mode: NotchMode, width: Double, mainAway: Bool, containerWidth: Double) -> Double {
        guard geometry.hasNotch else { return (containerWidth - width) / 2 }
        switch mode {
        case .expanded:
            return (containerWidth - width) / 2
        case .hidden, .compact:
            return containerWidth / 2 - geometry.width / 2 - leftWing(mode: mode, mainAway: mainAway)
        }
    }

    /// Bounds for a measured (content-driven) height of each expanded view.
    public static func heightRange(_ view: NotchView) -> ClosedRange<Double> {
        let base = viewHeight(view)
        switch view {
        case .approval, .question: return base...360
        case .chat: return base...380
        case .knowledge: return base...360
        case .diff: return base...420
        default: return base...360
        }
    }

    /// Mini layout in main-R units for each mode: beside the main slime when compact, a tray under
    /// the content when expanded (`firstSlot` measured from the main contact point).
    public func miniLayout(mode: NotchMode) -> (scale: Double, firstSlot: Double, pitch: Double, perRow: Int) {
        switch mode {
        case .hidden, .compact:
            return (0.45, 2.1, 1.15, 4)
        case .expanded:
            let r = Self.expandedSlimeRadius
            return (Self.trayMiniRadius / r, (Self.expandedContentLeading + 16 - 104) / r, Self.trayPitch / r, 12)
        }
    }

    /// Radius of the main slime in points: it fills the compact strip, and becomes the hero of the
    /// expanded island.
    public func slimeRadius(mode: NotchMode) -> Double {
        switch mode {
        case .hidden, .compact: return max(10, (geometry.height - 4) / 1.86)
        case .expanded: return Self.expandedSlimeRadius
        }
    }

    /// Contact point of the main slime inside the island (y down, from the island's top-left).
    public func slimeOrigin(mode: NotchMode, view: NotchView, islandSize: (width: Double, height: Double)) -> (x: Double, y: Double) {
        switch mode {
        case .hidden, .compact:
            return (Self.compactWing / 2, geometry.height - 2)
        case .expanded:
            return (104, islandSize.height - 12)
        }
    }

    /// Horizontal gap minis must skip over (the physical notch) while compact, in points.
    public func miniSlotOffset(mode: NotchMode) -> Double {
        switch mode {
        case .hidden, .compact: return geometry.width + Self.compactWing / 2 - 14
        case .expanded: return 0
        }
    }
}
