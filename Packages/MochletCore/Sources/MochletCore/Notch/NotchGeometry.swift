import Foundation

/// Resting island dimensions: the physical notch when the screen has one, else a small bar.
/// Screen-space geometry of the notch island.
public struct NotchGeometry: Sendable, Equatable {
    public static let fallbackNotchWidth: Double = 184
    public static let noNotchWidth: Double = 80
    public static let noNotchHeight: Double = 24

    public let hasNotch: Bool
    public let width: Double
    public let height: Double

    public init(hasNotch: Bool, width: Double, height: Double) {
        self.hasNotch = hasNotch
        self.width = width
        self.height = height
    }

    public init(screenWidth: Double, safeAreaTop: Double, auxiliaryLeftWidth: Double?, auxiliaryRightWidth: Double?, menuBarHeight: Double) {
        hasNotch = safeAreaTop > 0
        if hasNotch {
            if let left = auxiliaryLeftWidth, let right = auxiliaryRightWidth {
                let measured = screenWidth - left - right
                width = measured > 0 && measured < screenWidth ? measured : Self.fallbackNotchWidth
            } else {
                width = Self.fallbackNotchWidth
            }
            height = safeAreaTop
        } else {
            width = Self.noNotchWidth
            height = min(Self.noNotchHeight, menuBarHeight)
        }
    }

    public static let fallback = NotchGeometry(hasNotch: true, width: fallbackNotchWidth, height: 32)
}

/// Which screen hosts the island. Persisted as `storageValue`.
public enum DisplayChoice: Equatable, Hashable, Sendable {
    case notch
    case menuBar
    case followMouse
    case display(uuid: String)

    private static let displayPrefix = "display:"

    public init(storageValue: String) {
        switch storageValue {
        case "menuBar": self = .menuBar
        case "followMouse": self = .followMouse
        default:
            if storageValue.hasPrefix(Self.displayPrefix) {
                let uuid = String(storageValue.dropFirst(Self.displayPrefix.count))
                self = uuid.isEmpty ? .notch : .display(uuid: uuid)
            } else {
                self = .notch
            }
        }
    }

    public var storageValue: String {
        switch self {
        case .notch: return "notch"
        case .menuBar: return "menuBar"
        case .followMouse: return "followMouse"
        case .display(let uuid): return Self.displayPrefix + uuid
        }
    }
}

public struct DisplayCandidate: Sendable, Equatable {
    public let uuid: String?
    public let hasNotch: Bool
    public let containsMouse: Bool

    public init(uuid: String?, hasNotch: Bool, containsMouse: Bool) {
        self.uuid = uuid
        self.hasNotch = hasNotch
        self.containsMouse = containsMouse
    }
}

public enum DisplayResolver {
    /// Index of the screen that should host the island, or nil for the default.
    public static func index(for choice: DisplayChoice, in candidates: [DisplayCandidate]) -> Int? {
        guard !candidates.isEmpty else { return nil }
        let notchIndex = candidates.firstIndex { $0.hasNotch }
        switch choice {
        case .notch: return notchIndex
        case .menuBar: return 0
        case .followMouse: return candidates.firstIndex { $0.containsMouse } ?? notchIndex
        case .display(let uuid): return candidates.firstIndex { $0.uuid == uuid } ?? notchIndex
        }
    }
}
