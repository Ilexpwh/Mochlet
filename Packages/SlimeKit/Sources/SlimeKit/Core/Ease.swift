import Foundation

public enum Ease: Sendable, Equatable, Codable {
    case linear, inQuad, outQuad, inOutQuad, outCubic, inOutCubic, inOutSine, outBack, outExpo, outElastic

    public func apply(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        switch self {
        case .linear: return t
        case .inQuad: return t * t
        case .outQuad: return 1 - (1 - t) * (1 - t)
        case .inOutQuad: return t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        case .outCubic: return 1 - pow(1 - t, 3)
        case .inOutCubic: return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        case .inOutSine: return -(cos(.pi * t) - 1) / 2
        case .outBack:
            let c1 = 1.70158
            let c3 = c1 + 1
            return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
        case .outExpo: return t >= 1 ? 1 : 1 - pow(2, -10 * t)
        case .outElastic:
            if t == 0 || t == 1 { return t }
            let c4 = (2 * Double.pi) / 3
            return pow(2, -10 * t) * sin((t * 10 - 0.75) * c4) + 1
        }
    }
}

/// A scalar that can be tweened through keyframes. Every animation starts from the
/// current value, so re-targeting mid-flight never snaps.
public struct AnimatedValue: Sendable, Equatable {
    public struct Key: Sendable, Equatable {
        public var to: Double
        public var duration: Double
        public var ease: Ease
        public init(to: Double, duration: Double, ease: Ease = .outCubic) {
            self.to = to; self.duration = duration; self.ease = ease
        }
    }

    public private(set) var value: Double
    private var keys: [Key] = []
    private var from: Double = 0
    private var startTime: Double = 0

    public init(_ value: Double) { self.value = value }

    public var isAnimating: Bool { !keys.isEmpty }
    public var target: Double { keys.last?.to ?? value }

    public mutating func set(_ v: Double) {
        value = v
        keys = []
    }

    public mutating func animate(to: Double, duration: Double, ease: Ease = .outCubic, at time: Double) {
        animate(keys: [Key(to: to, duration: duration, ease: ease)], at: time)
    }

    public mutating func animate(keys: [Key], at time: Double) {
        self.keys = keys
        from = value
        startTime = time
    }

    public mutating func advance(to time: Double) {
        while let k = keys.first {
            let d = max(k.duration, 1e-6)
            let t = (time - startTime) / d
            if t >= 1 {
                value = k.to
                keys.removeFirst()
                from = value
                startTime += d
                continue
            }
            value = from + (k.to - from) * k.ease.apply(max(0, t))
            return
        }
    }
}

/// Exponential approach with time constant tau (seconds).
@inlinable
public func approach(_ value: Double, toward target: Double, tau: Double, dt: Double) -> Double {
    guard tau > 0 else { return target }
    let k = 1 - exp(-dt / tau)
    return value + (target - value) * k
}

@inlinable
public func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, x)) }

@inlinable
public func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
    let t = clamp((x - edge0) / max(1e-9, edge1 - edge0), 0, 1)
    return t * t * (3 - 2 * t)
}
