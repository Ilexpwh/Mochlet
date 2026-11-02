import Foundation

/// Transient drag geometry. Cancellation suppresses late updates until release/reset.
public struct DockDrag: Sendable {
    private var start: (origin: CGPoint, pointer: CGPoint)?
    private var cancelled = false
    public init() {}
    public var isActive: Bool { start != nil }

    public mutating func update(origin: CGPoint, pointer: CGPoint, translation: CGSize) -> CGPoint? {
        guard !cancelled, [origin.x, origin.y, pointer.x, pointer.y, translation.width, translation.height].allSatisfy(\.isFinite) else { return nil }
        if start == nil {
            // SwiftUI's translation is down-positive; AppKit screen coordinates are up-positive.
            start = (origin, .init(x: pointer.x - translation.width, y: pointer.y + translation.height))
        }
        guard let start else { return nil }
        return .init(x: start.origin.x + pointer.x - start.pointer.x, y: start.origin.y + pointer.y - start.pointer.y)
    }

    @discardableResult public mutating func cancel() -> Bool {
        guard isActive else { return false }
        start = nil; cancelled = true
        return true
    }

    /// True only when a completed drag may commit a new placement. Duplicate ends are harmless.
    @discardableResult public mutating func finish() -> Bool {
        let commit = isActive
        start = nil; cancelled = false
        return commit
    }
}
