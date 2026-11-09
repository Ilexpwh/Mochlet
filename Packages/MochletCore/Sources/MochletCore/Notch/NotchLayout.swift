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
    public static let expandedContentLeading: Double = 190
    public static let expandedContentLeadingAway: Double = 28
    /// Main slime radius while the island is expanded, and where its contact point sits.
    public static let expandedSlimeRadius: Double = 56
    public static let expandedSlimeX: Double = 96
    /// Bottom strip of the expanded island where the mini slimes line up (badges included).
    public static let trayHeight: Double = 40
    /// Mini radius in the tray, in points, and the pitch between minis.
    public static let trayMiniRadius: Double = 14.5
    public static let trayPitch: Double = 36
    /// The compact ticker never grows past this; longer text truncates in the middle.
    public static let tickerMaxWidth: Double = 240
    /// Room kept between a left or right anchored island and the screen edge.
    public static let edgeMargin: Double = 16
    /// A dragged island within this distance of a preset anchor snaps to it.
    public static let snapDistance: Double = 72

    public var geometry: NotchGeometry
    /// The island is away from the notch (another anchor, or a screen without one): no notch slot
    /// in the strip, rounded top corners, and a small pill while hidden.
    public var detached: Bool

    public init(geometry: NotchGeometry, detached: Bool = false) {
        self.geometry = geometry
        self.detached = detached
    }

    /// The notch slot: the physical notch's width while the island sits over it, nothing otherwise.
    public var slotWidth: Double { detached ? 0 : geometry.width }

    /// Width of the expanded island per view: reading views (chat, diff, knowledge, signals,
    /// meeting, session detail, projects) get the wide island.
    public static func expandedWidth(_ view: NotchView) -> Double {
        switch view {
        case .chat, .diff, .knowledge, .signals, .meetingLive, .sessionDetail, .projects: return 720
        default: return Self.expandedWidth
        }
    }

    /// The smallest height of each expanded view; every card reports its content height and the
    /// island grows from here within `heightRange`.
    public static func viewHeight(_ view: NotchView) -> Double {
        switch view {
        case .greeting: return 120
        case .home: return 128
        case .ask: return 130
        case .menu: return 150
        case .approval: return 140
        case .question: return 150
        case .chat: return 176
        case .diff: return 200
        case .sessionDetail: return 160
        case .meetingLive: return 150
        case .ingest: return 130
        case .projects: return 170
        case .knowledge, .signals: return 160
        case .toast: return 92
        case .whatsNew: return 170
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
            return (detached ? NotchGeometry.noNotchWidth : geometry.width, geometry.height)
        case .compact:
            return (slotWidth + leftWing(mode: mode, mainAway: mainAway) + compactRightWing(miniCount: miniCount, rightContent: rightContent), geometry.height)
        case .expanded:
            let range = Self.heightRange(view)
            let natural = Self.viewHeight(view) + (miniCount > 0 ? Self.trayHeight : 0)
            return (Self.expandedWidth(view), measuredHeight.map { min(range.upperBound, max(range.lowerBound, $0)) } ?? natural)
        }
    }

    /// Left edge of the island inside the strip panel (`containerWidth` = the screen's width) for an
    /// anchor. Over the notch, the compact strip's notch slot stays on the camera whatever the
    /// right wing grows to; elsewhere the island keeps `edgeMargin` from the edge or sits at its
    /// custom fraction, always fully on the strip.
    public func islandMinX(anchor: IslandAnchor, mode: NotchMode, width: Double, mainAway: Bool, containerWidth: Double) -> Double {
        let x: Double
        switch anchor {
        case .center where geometry.hasNotch:
            let notchCenter = geometry.notchCenterX ?? containerWidth / 2
            switch mode {
            case .expanded: x = notchCenter - width / 2
            case .hidden, .compact: x = notchCenter - geometry.width / 2 - leftWing(mode: mode, mainAway: mainAway)
            }
        case .center:
            x = (containerWidth - width) / 2
        case .left:
            x = Self.edgeMargin
        case .right:
            x = containerWidth - Self.edgeMargin - width
        case .custom(let f):
            x = f * containerWidth - width / 2
        }
        return min(max(0, containerWidth - width), max(0, x))
    }

    /// The anchor a dragged island settles on: the nearest preset whose resting centre is within
    /// `snapDistance`, else a custom fraction where it was dropped.
    public func snapAnchor(forMinX minX: Double, width: Double, mode: NotchMode, mainAway: Bool, containerWidth: Double) -> IslandAnchor {
        let centre = minX + width / 2
        var best: (anchor: IslandAnchor, distance: Double)?
        for a in IslandAnchor.presets {
            let x = islandMinX(anchor: a, mode: mode, width: width, mainAway: mainAway, containerWidth: containerWidth)
            let d = abs(x + width / 2 - centre)
            if d <= Self.snapDistance, d < (best?.distance ?? .infinity) { best = (a, d) }
        }
        if let best { return best.anchor }
        return .custom(fraction: min(1, max(0, centre / max(1, containerWidth))))
    }

    /// Radius of the island's top corners: square against the notch, rounded when detached.
    public func topRadius(mode: NotchMode) -> Double {
        guard detached else { return 0 }
        return mode == .expanded ? Self.expandedCorner : Self.compactCorner
    }

    /// Where the compact ticker starts: after the notch slot, the main slime's wing and the mini row.
    public func tickerLeading(miniCount: Int, mainAway: Bool) -> Double {
        slotWidth + (mainAway ? 0 : Self.compactWing) + Self.miniRowWidth(miniCount: miniCount) + 6
    }

    /// Bounds for a measured (content-driven) height of each expanded view.
    public static func heightRange(_ view: NotchView) -> ClosedRange<Double> {
        let base = viewHeight(view)
        switch view {
        case .home: return base...220
        case .approval, .question: return base...360
        case .chat, .knowledge, .diff: return base...420
        case .meetingLive, .signals, .projects: return base...400
        case .toast: return base...160
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
            return (Self.trayMiniRadius / r, (Self.expandedContentLeading + 16 - Self.expandedSlimeX) / r, Self.trayPitch / r, 12)
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
        case .hidden where detached:
            return (NotchGeometry.noNotchWidth / 2, geometry.height - 2)
        case .hidden, .compact:
            return (Self.compactWing / 2, geometry.height - 2)
        case .expanded:
            return (Self.expandedSlimeX, islandSize.height - 12)
        }
    }

    /// Horizontal gap minis must skip over (the physical notch) while compact, in points.
    public func miniSlotOffset(mode: NotchMode) -> Double {
        switch mode {
        case .hidden, .compact: return slotWidth + Self.compactWing / 2 - 14
        case .expanded: return 0
        }
    }
}
