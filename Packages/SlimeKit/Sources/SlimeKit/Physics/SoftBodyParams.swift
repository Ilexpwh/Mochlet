import Foundation

/// Tunable constants of the jelly. Units are normalised: rest radius R = 1, floor at y = 0,
/// y grows downward (screen space), time in seconds.
public struct SoftBodyParams: Sendable, Codable, Equatable {
    public var pointCount: Int = 24
    /// The jelly: with the pressure's share the ring rings at about 0.45 s per cycle and keeps
    /// roughly 0.56 of its swing each cycle (ζ ≈ 0.09), two to three visible wobbles.
    public var anchorStiffness: Double = 165
    public var edgeStiffness: Double = 1200
    public var bendStiffness: Double = 300
    public var pressure: Double = 60
    /// Velocity damping per second: v *= exp(-damping * h).
    public var damping: Double = 2.6
    /// Bulk viscosity: a pressure term against the rate of area change (per rest area per
    /// second). Jelly keeps its volume: the breathing mode (every point in or out together) is
    /// damped to about critical (effective damping 4π·b/n ≈ 0.52 b per point at 24 points) while
    /// the shape modes, which keep the area, ring with `damping` alone.
    public var bulkDamping: Double = 30
    /// Gravity on the perimeter points (R/s²).
    public var gravity: Double = 3
    /// Gravity on the root while airborne (R/s²).
    public var rootGravity: Double = 10
    /// Fraction of tangential velocity removed on floor contact.
    public var floorFriction: Double = 0.7
    public var restCenterY: Double = -0.78
    public var restRadius: Double = 1
    /// Shape of the rest ring (see `RestProfile`).
    public var silhouette: SlimeLook.Silhouette = .dome

    public init() {}

    enum CodingKeys: String, CodingKey {
        case pointCount, anchorStiffness, edgeStiffness, bendStiffness, pressure, damping, bulkDamping, gravity, rootGravity, floorFriction, restCenterY, restRadius, silhouette
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SoftBodyParams()
        pointCount = try c.decodeIfPresent(Int.self, forKey: .pointCount) ?? d.pointCount
        anchorStiffness = try c.decodeIfPresent(Double.self, forKey: .anchorStiffness) ?? d.anchorStiffness
        edgeStiffness = try c.decodeIfPresent(Double.self, forKey: .edgeStiffness) ?? d.edgeStiffness
        bendStiffness = try c.decodeIfPresent(Double.self, forKey: .bendStiffness) ?? d.bendStiffness
        pressure = try c.decodeIfPresent(Double.self, forKey: .pressure) ?? d.pressure
        damping = try c.decodeIfPresent(Double.self, forKey: .damping) ?? d.damping
        bulkDamping = try c.decodeIfPresent(Double.self, forKey: .bulkDamping) ?? d.bulkDamping
        gravity = try c.decodeIfPresent(Double.self, forKey: .gravity) ?? d.gravity
        rootGravity = try c.decodeIfPresent(Double.self, forKey: .rootGravity) ?? d.rootGravity
        floorFriction = try c.decodeIfPresent(Double.self, forKey: .floorFriction) ?? d.floorFriction
        restCenterY = try c.decodeIfPresent(Double.self, forKey: .restCenterY) ?? d.restCenterY
        restRadius = try c.decodeIfPresent(Double.self, forKey: .restRadius) ?? d.restRadius
        silhouette = try c.decodeIfPresent(SlimeLook.Silhouette.self, forKey: .silhouette) ?? .dome
    }

    /// These parameters shaped by a look: the silhouette's rest ring and the feel's springs.
    public func applying(look: SlimeLook, mini: Bool) -> SoftBodyParams {
        var p = self
        p.silhouette = look.silhouette
        p.pointCount = RestProfile.forSilhouette(look.silhouette, mini: mini).pointCount
        switch look.feel {
        case .jelly:
            break
        case .firm:
            // Calm (ζ ≈ 0.28): about one overshoot and done.
            p.damping = mini ? 10 : 9
            p.anchorStiffness = 220
        case .runny:
            p.pressure = 45
            p.damping = 2.2
            p.gravity = 4
        case .airy:
            p.gravity = 0.6
            p.damping = 2.4
        case .bouncy:
            p.damping = 1.8
        }
        return p
    }

    public static let main = SoftBodyParams()

    public static var mini: SoftBodyParams {
        var p = SoftBodyParams()
        p.pointCount = 16
        p.damping = 3.0
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
    /// A finger dent: the points facing `angle` (radians, 0 = right, -π/2 = top) move straight
    /// in by up to `depth` R and the ring rings back.
    case poke(angle: Double, depth: Double)
}

public enum SoftBodyEvent: Sendable, Equatable {
    case landed(speed: Double)
}
