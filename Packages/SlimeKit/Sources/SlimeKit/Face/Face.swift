import Foundation
import simd

public enum EyeShape: String, Sendable, Codable, CaseIterable {
    case open, half, closedLine, happyArc, squint, dot, wide, spiral, cross, heart, star, tired, focused, flat
    /// Ink-line faces from the anime: a relaxed flat line with a tick, a "> <" squeeze with radiating
    /// ticks, an angled glare, a half-lidded smug look, a welling teary eye, concentric shock rings,
    /// a sideways glance and a soft "︶" pleased arc.
    case relaxed, squeeze, glare, smug, teary, shock, sideGlance, pleased
    /// The stroke face (`FaceStyle.anime`): the content chevron with its short hook, a sad
    /// outward-down arc, a closed stroke with two tear ribbons, and a four-point sparkle.
    case content, sad, cryStream, sparkle

    /// Shapes drawn as a ball (an ink ellipse with highlights) that blinks shut.
    public var isBall: Bool {
        switch self {
        case .open, .half, .wide, .focused, .tired, .dot, .smug, .teary, .sideGlance, .glare: return true
        default: return false
        }
    }

    /// The stroke that stands in for a ball shape on an anime face, so nothing that sets an eye
    /// (states, emotes, drag-in, digesting, micro-idle, the stage) can put a sclera on it.
    public var strokeEquivalent: EyeShape {
        switch self {
        case .open, .dot, .sideGlance: return .content
        case .half, .focused: return .relaxed
        case .wide: return .shock
        case .tired, .smug: return .flat
        case .teary: return .cryStream
        case .glare: return .squint
        default: return self
        }
    }
}

public enum MouthShape: String, Sendable, Codable, CaseIterable {
    case none, smileTiny, omega, openRound, o, flat, wavy, sleepy
    /// A big rounded shout, a puckered pout, a tongue out, a wide toothy grin and a droopy squiggle.
    case openWide, pout, tongue, grin, squiggle
    /// The small "∧" pout of the stroke face.
    case caret
}

/// Eyes live on a sphere inside the jelly: they slide across it as the gaze turns and
/// foreshorten near the silhouette, which is what makes the dome read as round.
public struct EyeRig: Sendable, Codable, Equatable {
    /// Angular half-distance between the eyes (radians).
    public var separation: Double = 0.36
    /// Resting pitch of the eyes above the sphere centre (radians, + is up).
    public var basePitch: Double = 0.14
    /// Sphere radius in R, centred on `sphereCenter` (contact point = origin, y down).
    public var sphereRadius: Double = 0.88
    public var sphereCenter: SIMD2<Double> = SIMD2(0, -0.92)
    /// Eye half-width in R and height/width aspect.
    public var eyeRadius: Double = 0.16
    public var eyeAspect: Double = 1.32
    public var minForeshorten: Double = 0.18
    /// Mouth pitch below the sphere centre (radians).
    public var mouthPitch: Double = -0.42
    /// Blush position: yaw offset and pitch on the sphere.
    public var blushYaw: Double = 0.62
    public var blushPitch: Double = -0.12

    public init() {}

    /// The round face: tall bead eyes 0.38 R wide and 0.85 R apart, so they read as one pair
    /// rather than two dots in the middle of the face.
    public static let main: EyeRig = {
        var r = EyeRig()
        r.separation = 0.50
        r.basePitch = 0.16
        r.eyeRadius = 0.19
        r.eyeAspect = 1.35
        r.blushYaw = 0.78
        r.blushPitch = -0.10
        return r
    }()

    public static var mini: EyeRig {
        var r = main
        r.eyeRadius = 0.21
        r.eyeAspect = 1.25
        return r
    }

    /// The stroke face, measured off the sticker sheets and the Bandai figures: two thin strokes
    /// about 0.46 R long and 1.15 R apart, high on the dome at (±0.57, −1.07) (eyes at the upper
    /// third of the body, half way out to the silhouette), the mouth 0.35 R under them and the
    /// blush ovals outside and a little below the eyes at (±0.84, −0.91).
    public static var anime: EyeRig {
        var r = EyeRig()
        r.separation = 0.58
        r.basePitch = 0.17
        r.eyeRadius = 0.37
        r.eyeAspect = 0.5
        r.mouthPitch = -0.30
        r.blushYaw = 1.27
        r.blushPitch = -0.01
        return r
    }

    /// The stroke face on a mini: the same proportions, a little longer so it reads at 7 px.
    public static var animeMini: EyeRig {
        var r = anime
        r.eyeRadius = 0.42
        return r
    }

    /// This rig scaled to another rest outline, so eyes, mouth and blush sit on a puddle or a
    /// tall drop the way they sit on the dome.
    public func fitted(to profile: RestProfile) -> EyeRig {
        var r = self
        let dome = RestProfile.dome
        let kx = profile.width / dome.width
        let ky = (profile.height - profile.centerY) / (dome.height - dome.centerY)
        if abs(kx - 1) < 1e-9, abs(ky - 1) < 1e-9 { return self }
        let k = (kx * ky).squareRoot()
        r.sphereCenter = SIMD2(sphereCenter.x, sphereCenter.y * ky)
        r.sphereRadius = sphereRadius * k
        r.eyeRadius = eyeRadius * k
        return r
    }

    public struct Projection: Sendable, Equatable {
        /// Point on the unit sphere (x right, y down), to be scaled by `sphereRadius`.
        public var position: SIMD2<Double>
        public var foreshorten: SIMD2<Double>
        public var depth: Double
        public var visible: Bool
    }

    /// Projects a feature at (yawOffset, pitchOffset) on the sphere under the current gaze.
    public func project(yawOffset: Double, pitchOffset: Double, yaw: Double, pitch: Double) -> Projection {
        let ey = yawOffset + yaw
        let ep = pitchOffset + pitch
        let position = SIMD2(sin(ey) * cos(ep), -sin(ep))
        let depth = cos(ey) * cos(ep)
        let foreshorten = SIMD2(max(minForeshorten, cos(ey)), max(minForeshorten, cos(ep)))
        return Projection(position: position, foreshorten: foreshorten, depth: depth, visible: depth > 0.04)
    }

    public func eye(side: Double, yaw: Double, pitch: Double) -> Projection {
        project(yawOffset: side * separation, pitchOffset: basePitch, yaw: yaw, pitch: pitch)
    }

    /// Local (reference-space) position of a projection.
    public func local(_ p: Projection) -> SIMD2<Double> {
        sphereCenter + p.position * sphereRadius
    }
}

/// Smoothed gaze: yaw = 0.62·tanh(dx/12R), pitch = 0.50·tanh(dy/9R), τ 0.17 s.
public struct Gaze: Sendable, Codable, Equatable {
    public var yawGain: Double = 0.62
    public var yawRange: Double = 12
    public var pitchGain: Double = 0.50
    public var pitchRange: Double = 9
    public var tau: Double = 0.17
    /// Beyond this distance (R) the pointer stops mattering.
    public var fadeDistance: Double = 30

    public private(set) var yaw: Double = 0
    public private(set) var pitch: Double = 0
    public private(set) var target: SIMD2<Double> = .zero

    public init() {}

    /// Gaze (yaw, pitch) for a pointer offset from the eye centre, in R, y down.
    public func pointerTarget(_ d: SIMD2<Double>) -> SIMD2<Double> {
        let dist = simd_length(d)
        let weight = 1 - smoothstep(fadeDistance * 0.6, fadeDistance, dist)
        let yaw = yawGain * tanh(d.x / yawRange)
        let pitch = pitchGain * tanh(-d.y / pitchRange)
        return SIMD2(yaw, pitch) * weight
    }

    public mutating func setTarget(_ t: SIMD2<Double>) {
        target = SIMD2(clamp(t.x, -1.2, 1.2), clamp(t.y, -1.0, 1.0))
    }

    public mutating func advance(dt: Double) {
        yaw = approach(yaw, toward: target.x, tau: tau, dt: dt)
        pitch = approach(pitch, toward: target.y, tau: tau, dt: dt)
    }

    public mutating func snap(_ t: SIMD2<Double>) {
        setTarget(t)
        yaw = target.x
        pitch = target.y
    }
}

/// Irregular blinks: U(2.2, 5.4) s apart, 22 % doubles, one eye leading by ≤ 25 ms,
/// close 70 ms / hold 20 ms / open 130 ms.
public struct BlinkScheduler: Sendable, Equatable {
    public var interval: ClosedRange<Double> = 2.2...5.4
    public var doubleChance: Double = 0.22
    public var doubleGap: Double = 0.24
    public var closeDuration: Double = 0.07
    public var holdDuration: Double = 0.02
    public var openDuration: Double = 0.13
    public var maxLag: Double = 0.025
    public var suppressed = false

    private struct Blink: Sendable, Equatable {
        var start: Double
        var lag: SIMD2<Double>
    }

    private var nextAt: Double = 2
    private var blinks: [Blink] = []
    public private(set) var openness: SIMD2<Double> = SIMD2(1, 1)
    public private(set) var count = 0

    public init() {}

    public var totalDuration: Double { closeDuration + holdDuration + openDuration }
    public var isBlinking: Bool { openness.x < 0.999 || openness.y < 0.999 }
    public var nextBlinkAt: Double { nextAt }

    public mutating func prime(at time: Double, rng: inout SeededRandom) {
        nextAt = time + rng.range(1.0...2.5)
    }

    public mutating func reschedule(after time: Double, rng: inout SeededRandom) {
        nextAt = time + rng.range(interval)
    }

    public mutating func blinkNow(at time: Double, rng: inout SeededRandom) {
        let lag = rng.range(0...maxLag)
        let lead = rng.sign()
        blinks.append(Blink(start: time, lag: lead > 0 ? SIMD2(0, lag) : SIMD2(lag, 0)))
        count += 1
    }

    private func opennessOf(_ b: Blink, at time: Double, lag: Double) -> Double {
        let u = time - b.start - lag
        if u <= 0 { return 1 }
        if u < closeDuration { return 1 - u / closeDuration }
        if u < closeDuration + holdDuration { return 0 }
        let o = u - closeDuration - holdDuration
        if o < openDuration { return o / openDuration }
        return 1
    }

    /// Advances the schedule and returns (left, right) openness in 0...1.
    @discardableResult
    public mutating func advance(to time: Double, rng: inout SeededRandom) -> SIMD2<Double> {
        if suppressed {
            nextAt = max(nextAt, time + 0.6)
        } else if time >= nextAt {
            blinkNow(at: time, rng: &rng)
            var next = time + rng.range(interval)
            if rng.chance(doubleChance) {
                let lag = blinks.last?.lag ?? .zero
                blinks.append(Blink(start: time + doubleGap, lag: lag))
                count += 1
                next += doubleGap
            }
            nextAt = next
        }
        let expiry = totalDuration + maxLag
        blinks.removeAll { time - $0.start > expiry }
        var l = 1.0
        var r = 1.0
        for b in blinks {
            l = min(l, opennessOf(b, at: time, lag: b.lag.x))
            r = min(r, opennessOf(b, at: time, lag: b.lag.y))
        }
        openness = SIMD2(l, r)
        return openness
    }
}
