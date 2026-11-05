import Foundation

/// Tunable constants of the jelly. Units are normalised: rest radius R = 1, floor at y = 0,
/// y grows downward (screen space), time in seconds.
public struct SoftBodyParams: Sendable, Codable, Equatable {
    public var pointCount: Int = 24
    public var anchorStiffness: Double = 90
    public var edgeStiffness: Double = 1200
    public var bendStiffness: Double = 300
    public var pressure: Double = 60
    /// Velocity damping per second: v *= exp(-damping * h).
    public var damping: Double = 8
    /// Gravity on the perimeter points (R/s²).
    public var gravity: Double = 3
    /// Gravity on the root while airborne (R/s²).
    public var rootGravity: Double = 10
    /// Fraction of tangential velocity removed on floor contact.
    public var floorFriction: Double = 0.7
    public var restCenterY: Double = -0.86
    public var restRadius: Double = 1

    public init() {}

    public static let main = SoftBodyParams()

    public static var mini: SoftBodyParams {
        var p = SoftBodyParams()
        p.pointCount = 16
        p.damping = 9
        p.pressure = 50
        return p
    }

    /// The fixed physics step.
    public static let substep: Double = 1.0 / 240.0

    /// Verlet stability requires k·h² < 4 for every spring.
    public var isStable: Bool {
        let h2 = Self.substep * Self.substep
        return max(anchorStiffness, edgeStiffness, bendStiffness) * h2 < 4
    }
}

public enum Impulse: Sendable, Equatable {
    /// Downward kick of the whole ring, as if it hit the floor at `speed` R/s.
    case landing(speed: Double)
    /// Leave the floor with vertical speed v0 (R/s).
    case jump(v0: Double)
    /// Horizontal kick of the points on `side` (+1 right, -1 left) toward the other side.
    case slap(side: Double, strength: Double)
    /// Kick of every point in a direction (R/s).
    case shake(direction: SIMD2<Double>)
    /// Inward kick of the points around an angle (radians, 0 = right, -π/2 = top).
    case wobble(angle: Double, strength: Double)
    /// Horizontal squeeze of one side at mid height (chewing).
    case bite(side: Double, strength: Double)
    /// Radial outward kick.
    case puff(scale: Double)
    /// Gentle push of the whole body.
    case nudge(direction: SIMD2<Double>)
}

public enum SoftBodyEvent: Sendable, Equatable {
    case landed(speed: Double)
}
