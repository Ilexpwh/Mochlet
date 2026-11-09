import Foundation
import simd

/// Ring of Verlet mass points with anchor, edge and bend springs, an area-pressure term,
/// perimeter gravity and a floor. The rest shape is a `RestProfile` (the bun by default) whose
/// bottom sits under the floor: the clamp plus the pressure produce the flat base and the
/// contact patch by themselves.
public struct SoftBody: Sendable {
    public private(set) var params: SoftBodyParams
    public private(set) var points: [SIMD2<Double>]
    private var prev: [SIMD2<Double>]
    private var renderPrev: [SIMD2<Double>]
    private var acc: [SIMD2<Double>]
    private let restRing: [SIMD2<Double>]
    private let edgeRest: [Double]
    private let bendRest: [Double]
    private let baseRestArea: Double

    /// The settled resting shape (root at the origin), used as the reference for the affine fit.
    public private(set) var referenceRing: [SIMD2<Double>] = []
    public private(set) var referenceCentroid: SIMD2<Double> = .zero
    public private(set) var referenceArea: Double = 0

    /// Whole-body carrier for jumps and flights. Anchors follow it.
    public private(set) var root: SIMD2<Double> = .zero
    public private(set) var rootVelocity: SIMD2<Double> = .zero
    public private(set) var airborne = false
    /// Designer-driven offset of the anchors (shake keyframes).
    public var offset: SIMD2<Double> = .zero
    /// Rotation of the rest shape about the contact point, radians (+ leans right).
    public var lean: Double = 0
    /// Vertical scale of the rest shape; horizontal is 1/squash so volume is preserved.
    public var squash: Double = 1
    /// Uniform scale of the rest shape (split shrink, shy); rest area scales with it.
    public var sizeScale: Double = 1
    public var gravityScale: Double = 1
    public var floorEnabled = true

    public init(params: SoftBodyParams) {
        var profile = RestProfile.forSilhouette(params.silhouette)
        profile.width *= params.restRadius
        profile.height *= params.restRadius
        profile.centerY = params.silhouette == .dome ? params.restCenterY : profile.centerY * params.restRadius
        self.init(params: params, profile: profile)
    }

    /// A body resting on an explicit outline (tests and profile tuning).
    init(params: SoftBodyParams, profile: RestProfile) {
        self.params = params
        let n = max(6, params.pointCount)
        let ring = profile.ring(count: n)
        restRing = ring
        points = ring
        prev = ring
        renderPrev = ring
        acc = Array(repeating: .zero, count: n)
        var e: [Double] = []
        var b: [Double] = []
        for i in 0..<n {
            e.append(simd_distance(ring[i], ring[(i + 1) % n]))
            b.append(simd_distance(ring[i], ring[(i + 2) % n]))
        }
        edgeRest = e
        bendRest = b
        baseRestArea = Self.polygonArea(ring)
        settle()
    }

    // MARK: Queries

    public var count: Int { points.count }
    public var restArea: Double { baseRestArea * sizeScale * sizeScale }
    public var area: Double { Self.polygonArea(points) }
    public var areaRatio: Double { area / restArea }
    public var centroid: SIMD2<Double> { points.reduce(.zero, +) / Double(points.count) }
    public var topY: Double { points.map(\.y).min() ?? 0 }
    public var bottomY: Double { points.map(\.y).max() ?? 0 }
    public var minX: Double { points.map(\.x).min() ?? 0 }
    public var maxX: Double { points.map(\.x).max() ?? 0 }

    /// Width of the part of the ring resting on the floor.
    public var contactWidth: Double {
        let xs = points.filter { $0.y > -0.03 }.map(\.x)
        guard let lo = xs.min(), let hi = xs.max() else { return 0 }
        return hi - lo
    }

    /// Ring at a fraction between the previous and the current substep (render interpolation).
    public func interpolated(alpha: Double) -> [SIMD2<Double>] {
        let a = clamp(alpha, 0, 1)
        var out = points
        for i in 0..<out.count {
            out[i] = renderPrev[i] + (points[i] - renderPrev[i]) * a
        }
        return out
    }

    public static func polygonArea(_ p: [SIMD2<Double>]) -> Double {
        let n = p.count
        guard n >= 3 else { return 0 }
        var s = 0.0
        for i in 0..<n {
            let a = p[i]
            let b = p[(i + 1) % n]
            s += a.x * b.y - b.x * a.y
        }
        return abs(s) * 0.5
    }

    public func anchor(_ i: Int) -> SIMD2<Double> {
        let r = restRing[i] * sizeScale
        let scaled = SIMD2(r.x / squash, r.y * squash)
        let c = cos(lean)
        let s = sin(lean)
        let rotated = SIMD2(scaled.x * c - scaled.y * s, scaled.x * s + scaled.y * c)
        return root + offset + rotated
    }

    public func anchors() -> [SIMD2<Double>] {
        (0..<points.count).map { anchor($0) }
    }

    /// Outward direction of point i from the ring centroid.
    public func outwardNormal(_ i: Int) -> SIMD2<Double> {
        let d = points[i] - centroid
        let l = simd_length(d)
        return l > 1e-9 ? d / l : SIMD2(0, -1)
    }

    // MARK: Mutation

    public mutating func setParams(_ p: SoftBodyParams) {
        params = p
    }

    public mutating func teleport(root newRoot: SIMD2<Double>) {
        let delta = newRoot - root
        root = newRoot
        for i in 0..<points.count {
            points[i] += delta
            prev[i] += delta
            renderPrev[i] += delta
        }
    }

    public mutating func launch(velocity: SIMD2<Double>) {
        rootVelocity = velocity
        airborne = true
    }

    /// Place the body in the air and let it fall (greeting entrance).
    public mutating func drop(fromHeight height: Double, initialSpeed: Double = 0) {
        teleport(root: SIMD2(root.x, -abs(height)))
        launch(velocity: SIMD2(0, initialSpeed))
    }

    public mutating func land() {
        root.y = 0
        rootVelocity = .zero
        airborne = false
    }

    /// Velocity kick (R/s), encoded into the Verlet previous positions.
    public mutating func apply(_ impulse: Impulse, h: Double = SoftBodyParams.substep) {
        let n = points.count
        let c = centroid
        func kick(_ i: Int, _ dv: SIMD2<Double>) {
            prev[i] -= dv * h
        }
        switch impulse {
        case .landing(let speed):
            for i in 0..<n { kick(i, SIMD2(0, abs(speed) * 0.6)) }
        case .jump(let v0):
            launch(velocity: SIMD2(rootVelocity.x, -abs(v0)))
            for i in 0..<n { kick(i, SIMD2(0, -abs(v0) * 0.45)) }
        case .slap(let side, let strength):
            let s = side >= 0 ? 1.0 : -1.0
            for i in 0..<n {
                let w = clamp((points[i].x - c.x) * s, 0, 1)
                if w > 0 { kick(i, SIMD2(-s * strength * 2.0 * w, 0)) }
            }
        case .shake(let dir):
            for i in 0..<n { kick(i, dir) }
        case .wobble(let angle, let strength):
            let dir = SIMD2(cos(angle), sin(angle))
            for i in 0..<n {
                let nrm = outwardNormal(i)
                let w = max(0, simd_dot(nrm, dir))
                let ww = w * w * w
                if ww > 0.01 { kick(i, -nrm * (strength * 2.5 * ww)) }
            }
        case .bite(let side, let strength):
            let s = side >= 0 ? 1.0 : -1.0
            for i in 0..<n {
                let p = points[i]
                let w = clamp((p.x - c.x) * s, 0, 1)
                let mid = 1 - min(1, abs(p.y - c.y) / 0.6)
                let ww = w * mid
                if ww > 0.02 { kick(i, SIMD2(-s * strength * 2.2 * ww, 0)) }
            }
        case .puff(let scale):
            for i in 0..<n { kick(i, outwardNormal(i) * (scale * 4)) }
        case .nudge(let dir):
            for i in 0..<n { kick(i, dir * 0.8) }
        }
    }

    public mutating func step(h: Double) -> [SoftBodyEvent] {
        var events: [SoftBodyEvent] = []
        if airborne {
            rootVelocity.y += params.rootGravity * h
            root += rootVelocity * h
            if root.y >= 0 {
                root.y = 0
                events.append(.landed(speed: rootVelocity.y))
                rootVelocity = .zero
                airborne = false
            }
        }
        let n = points.count
        for i in 0..<n {
            acc[i] = .zero
            renderPrev[i] = points[i]
        }
        let kA = params.anchorStiffness
        let kE = params.edgeStiffness
        let kB = params.bendStiffness
        for i in 0..<n {
            acc[i] += (anchor(i) - points[i]) * kA
        }
        for i in 0..<n {
            let j = (i + 1) % n
            let d = points[j] - points[i]
            let len = simd_length(d)
            if len > 1e-9 {
                let f = d * (kE * (len - edgeRest[i] * sizeScale) / len)
                acc[i] += f
                acc[j] -= f
            }
            let k2 = (i + 2) % n
            let d2 = points[k2] - points[i]
            let len2 = simd_length(d2)
            if len2 > 1e-9 {
                let f2 = d2 * (kB * (len2 - bendRest[i] * sizeScale) / len2)
                acc[i] += f2
                acc[k2] -= f2
            }
        }
        let coef = params.pressure * (1 - area / restArea)
        for i in 0..<n {
            let j = (i + 1) % n
            let e = points[j] - points[i]
            let len = simd_length(e)
            guard len > 1e-9 else { continue }
            let normal = SIMD2(e.y, -e.x) / len
            let f = normal * (0.5 * coef * len)
            acc[i] += f
            acc[j] += f
        }
        let g = params.gravity * gravityScale
        let dampingFactor = exp(-params.damping * h)
        for i in 0..<n {
            acc[i].y += g
            var v = (points[i] - prev[i]) * dampingFactor
            var p = points[i] + v + acc[i] * (h * h)
            if floorEnabled && p.y > 0 {
                p.y = 0
                v.x *= (1 - params.floorFriction)
                prev[i] = SIMD2(p.x - v.x, 0)
            } else {
                prev[i] = points[i]
            }
            points[i] = p
        }
        return events
    }

    /// Run the simulation to rest and record the settled shape as the reference.
    public mutating func settle(seconds: Double = 3) {
        let steps = Int(seconds / SoftBodyParams.substep)
        for _ in 0..<steps {
            _ = step(h: SoftBodyParams.substep)
        }
        referenceRing = points.map { $0 - root }
        referenceCentroid = referenceRing.reduce(.zero, +) / Double(referenceRing.count)
        referenceArea = area
        prev = points
        renderPrev = points
    }

    /// Kill all motion (used by tests and the Emote Lab reset).
    public mutating func rest() {
        prev = points
        renderPrev = points
        rootVelocity = .zero
    }
}
