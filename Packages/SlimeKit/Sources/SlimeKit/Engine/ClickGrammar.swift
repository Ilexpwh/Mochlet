import Foundation
import simd

/// Pure click/hold/drag classifier with injected time. Counts clicks in a sliding window and
/// settles after `settleInterval` (the host passes NSEvent.doubleClickInterval). The 5th click
/// inside the window fires `splitNow` immediately; further clicks add droplets.
public struct ClickGrammar: Sendable, Equatable {
    public var holdThreshold: Double = 0.25
    /// In R units (the host converts its 6 pt threshold).
    public var dragThreshold: Double = 0.3
    public var settleInterval: Double = 0.5
    public var window: Double = 1.5
    public var splitCount: Int = 5

    public enum Output: Sendable, Equatable {
        case holdBegan
        case dragBegan
        case click(count: Int)
        case splitNow(extra: Int)
    }

    private var pressStart: Double?
    private var pressOrigin: SIMD2<Double> = .zero
    private var holdFired = false
    private var dragFired = false
    private var clicks: [Double] = []
    private var settleAt: Double?

    public init() {}

    public var isPressed: Bool { pressStart != nil }
    public var isHolding: Bool { holdFired && pressStart != nil }
    public var isDragging: Bool { dragFired && pressStart != nil }
    public var pendingClicks: Int { clicks.count }

    public mutating func pressBegan(at time: Double, position: SIMD2<Double>) -> [Output] {
        pressStart = time
        pressOrigin = position
        holdFired = false
        dragFired = false
        settleAt = nil
        return []
    }

    public mutating func pressMoved(at time: Double, position: SIMD2<Double>) -> [Output] {
        guard pressStart != nil, !holdFired, !dragFired else { return [] }
        if simd_length(position - pressOrigin) >= dragThreshold {
            dragFired = true
            clicks = []
            settleAt = nil
            return [.dragBegan]
        }
        return []
    }

    public mutating func pressEnded(at time: Double) -> [Output] {
        guard pressStart != nil else { return [] }
        pressStart = nil
        if holdFired || dragFired {
            holdFired = false
            dragFired = false
            return []
        }
        clicks.append(time)
        clicks.removeAll { time - $0 > window }
        if clicks.count >= splitCount {
            settleAt = nil
            return [.splitNow(extra: clicks.count - splitCount)]
        }
        settleAt = time + settleInterval
        return []
    }

    public mutating func cancel() {
        pressStart = nil
        holdFired = false
        dragFired = false
        clicks = []
        settleAt = nil
    }

    public mutating func advance(to time: Double) -> [Output] {
        var out: [Output] = []
        if let start = pressStart, !holdFired, !dragFired, time - start >= holdThreshold {
            holdFired = true
            clicks = []
            settleAt = nil
            out.append(.holdBegan)
        }
        if let s = settleAt, time >= s {
            settleAt = nil
            let n = clicks.count
            clicks = []
            if n > 0 { out.append(.click(count: n)) }
        }
        return out
    }
}
