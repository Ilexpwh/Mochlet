import Foundation

/// Where the island sits along the top edge of its screen. Remembered per display.
public enum IslandAnchor: Hashable, Sendable {
    case left
    /// Over the notch on a notch screen, the middle of the top edge elsewhere.
    case center
    case right
    /// Anywhere else along the edge: the island's centre as a fraction of the screen width.
    case custom(fraction: Double)

    public static let presets: [IslandAnchor] = [.left, .center, .right]

    public init(storageValue: String) {
        switch storageValue {
        case "left": self = .left
        case "right": self = .right
        case "center": self = .center
        default:
            if storageValue.hasPrefix("custom:"), let f = Double(storageValue.dropFirst(7)) {
                self = .custom(fraction: min(1, max(0, f)))
            } else {
                self = .center
            }
        }
    }

    public var storageValue: String {
        switch self {
        case .left: return "left"
        case .center: return "center"
        case .right: return "right"
        case .custom(let f): return "custom:" + String(format: "%.3f", f)
        }
    }

    public var isCenter: Bool { if case .center = self { return true } else { return false } }
    public var isCustom: Bool { if case .custom = self { return true } else { return false } }

    /// Menu and settings label.
    public func title(hasNotch: Bool) -> String {
        switch self {
        case .left: return "Left"
        case .center: return hasNotch ? "Over the notch" : "Centre"
        case .right: return "Right"
        case .custom: return "Custom"
        }
    }
}
