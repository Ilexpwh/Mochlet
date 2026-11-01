import Foundation

/// Interaction policy independent of window geometry and animation timers.
public struct IslandInteraction: Equatable, Sendable {
    public enum Mode: String, Sendable { case hidden, compact, expanded }
    public private(set) var mode: Mode = .compact
    public private(set) var hovered = false
    public private(set) var openedByHover = false
    public var pinned = false
    public init() {}

    public mutating func enter(openOnHover: Bool) {
        hovered = true
        if mode != .expanded {
            mode = openOnHover ? .expanded : .compact
            openedByHover = openOnHover
        }
    }
    public mutating func leave() { hovered = false }
    public mutating func open() { mode = .expanded; openedByHover = false }
    public mutating func interact() { openedByHover = false }
    public mutating func collapse() { mode = .compact; openedByHover = false; pinned = false }
    public mutating func reveal() { if mode == .hidden { mode = .compact } }

    public func dismissalDelay(held: Bool, autoHide: Bool) -> TimeInterval? {
        guard !hovered, !held, !pinned else { return nil }
        switch mode {
        case .expanded: return openedByHover ? 0.6 : 15
        case .compact: return autoHide ? 60 : nil
        case .hidden: return nil
        }
    }
    public mutating func timeout(held: Bool, autoHide: Bool) {
        guard dismissalDelay(held: held, autoHide: autoHide) != nil else { return }
        if mode == .expanded { collapse() }
        else if autoHide { mode = .hidden }
    }
}
