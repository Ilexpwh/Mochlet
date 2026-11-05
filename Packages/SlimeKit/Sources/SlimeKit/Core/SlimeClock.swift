import Foundation

/// Fixed-step accumulator. The engine runs `steps` substeps of `step` seconds per rendered
/// frame and draws the ring interpolated by `alpha`, so motion is identical at 60 and 120 Hz
/// and never freezes or doubles when frame timing jitters.
public struct SlimeClock: Sendable, Equatable {
    public let step: Double
    public var maxFrameDt: Double = 0.1
    private var accumulator: Double = 0
    private var lastWall: Double?
    /// Total simulated time, in seconds.
    public private(set) var time: Double = 0

    public init(step: Double = 1.0 / 240.0) {
        self.step = step
    }

    /// True once a wall time has been seen.
    public var isPrimed: Bool { lastWall != nil }

    public mutating func advance(to wall: Double) -> (steps: Int, alpha: Double) {
        guard let last = lastWall else {
            lastWall = wall
            return (0, 0)
        }
        var dt = wall - last
        lastWall = wall
        if dt < 0 { dt = 0 }
        if dt > maxFrameDt { dt = maxFrameDt }
        accumulator += dt
        var n = 0
        while accumulator >= step {
            accumulator -= step
            n += 1
        }
        time += Double(n) * step
        return (n, accumulator / step)
    }

    /// Forget the previous wall time (after a pause) so the next frame does not catch up.
    public mutating func resume() {
        lastWall = nil
        accumulator = 0
    }
}

/// Engine-time actions with cancel tokens and tags. The engine never uses asyncAfter or
/// Task.sleep: everything timed is driven by the clock so filmstrips and tests are exact.
@MainActor
public final class Scheduler {
    public struct Token: Hashable, Sendable {
        let id: Int
    }

    private struct Entry {
        let id: Int
        let fireAt: Double
        let tag: String?
        let action: @MainActor () -> Void
    }

    private var entries: [Entry] = []
    private var nextID = 1

    public init() {}

    public var count: Int { entries.count }

    @discardableResult
    public func schedule(at time: Double, tag: String? = nil, _ action: @escaping @MainActor () -> Void) -> Token {
        let id = nextID
        nextID += 1
        entries.append(Entry(id: id, fireAt: time, tag: tag, action: action))
        return Token(id: id)
    }

    public func cancel(_ token: Token) {
        entries.removeAll { $0.id == token.id }
    }

    public func cancel(tag: String) {
        entries.removeAll { $0.tag == tag }
    }

    public func cancelAll() {
        entries.removeAll()
    }

    public func hasPending(tag: String) -> Bool {
        entries.contains { $0.tag == tag }
    }

    /// Runs every action due at or before `time`, earliest first. Actions may schedule more.
    public func fire(upTo time: Double) {
        while true {
            var bestIndex: Int?
            for (i, e) in entries.enumerated() where e.fireAt <= time {
                if let b = bestIndex {
                    if e.fireAt < entries[b].fireAt { bestIndex = i }
                } else {
                    bestIndex = i
                }
            }
            guard let i = bestIndex else { return }
            let entry = entries.remove(at: i)
            entry.action()
        }
    }
}
