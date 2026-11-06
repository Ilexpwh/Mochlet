import Foundation
import simd

/// How much of the character a host can afford at its pixel size: everything at 36 px per R and
/// up, solid features and goo but no surface effects between 24 and 36, silhouette only below.
public enum DetailLevel: Int, Sendable, Comparable {
    case tiny = 0, medium = 1, full = 2

    public static func < (a: DetailLevel, b: DetailLevel) -> Bool { a.rawValue < b.rawValue }

    public init(pixelsPerUnit: Double) {
        self = pixelsPerUnit >= 36 ? .full : pixelsPerUnit >= 24 ? .medium : .tiny
    }
}

/// A solid feature attached to the body (horn, wing, inner ear, fin…): where it sits on the jelly
/// and which way it points, in world R units. The renderer draws the shape; the rig places it.
public struct TraitFrame: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case horn(SlimeLook.Horns)
        case wing(SlimeLook.Wings)
        case earInner(SlimeLook.Ears)
        case shard
        case antennaBall
        case tailTip(SlimeLook.Tail)
        case fin
        /// A small specular on a goo feature (ear, tail, tip, flame).
        case gloss
    }

    public var kind: Kind
    /// −1 left, +1 right, 0 centre (mirrors the shape).
    public var side: Double
    public var anchor: SIMD2<Double>
    /// Unit vector the feature grows along.
    public var direction: SIMD2<Double>
    public var scale: Double
    /// Flap, wag or wiggle angle (radians) about the anchor.
    public var phase: Double

    public init(kind: Kind, side: Double, anchor: SIMD2<Double>, direction: SIMD2<Double>, scale: Double, phase: Double) {
        self.kind = kind; self.side = side; self.anchor = anchor; self.direction = direction; self.scale = scale; self.phase = phase
    }
}

/// Animation state of the traits, advanced by the engine every substep.
public struct TraitAnim: Sendable, Equatable {
    /// Ear twitch angles (left, right).
    public var earTwitch = SIMD2<Double>(0, 0)
    public var tailWag: Double = 0
    public var wingFlap: Double = 0
    public var antenna: Double = 0
    /// Both ears rotate outward by this (landing flop, follow-through).
    public var earFlop: Double = 0
    /// The drop tip lags behind the body (clockwise positive).
    public var tipLag: Double = 0
    public init() {}
}

/// Builds the goo (blobs merged into the silhouette) and the solid features of a look from the
/// current ring. Pure: the same ring and animation values give the same output.
public enum TraitRig {
    public struct Output: Sendable, Equatable {
        public var blobs: [Blob] = []
        public var traits: [TraitFrame] = []
        public init() {}
    }

    /// Ring index whose rest angle is closest to `angle` (−π/2 top, 0 right, π/2 bottom).
    /// Links in a goo tail chain. Spacing stays near half a radius so the metaball contour reads
    /// as one smooth tail rather than beads.
    public static func tailLinks(_ tail: SlimeLook.Tail) -> Int { tailChain(tail).count }

    /// `straight` links run out sideways before the rest curl upward.
    static func tailChain(_ tail: SlimeLook.Tail) -> (count: Int, r0: Double, r1: Double, seg: Double, curl: Double, straight: Int) {
        switch tail {
        case .fox: return (7, 0.26, 0.15, 0.17, 0.3, 2)
        case .dragon: return (8, 0.16, 0.06, 0.19, 0.32, 4)
        case .cat: return (7, 0.13, 0.08, 0.15, 0.3, 2)
        case .fish, .none: return (0, 0, 0, 0, 0, 0)
        }
    }

    public static func index(angle: Double, count n: Int) -> Int {
        guard n > 0 else { return 0 }
        let turns = (angle + .pi / 2) / (2 * .pi)
        let i = Int((turns * Double(n)).rounded())
        return ((i % n) + n) % n
    }

    static func unit(_ v: SIMD2<Double>) -> SIMD2<Double> {
        let l = simd_length(v)
        return l > 1e-9 ? v / l : SIMD2(0, -1)
    }

    static func rotate(_ v: SIMD2<Double>, by a: Double) -> SIMD2<Double> {
        let c = cos(a), s = sin(a)
        return SIMD2(v.x * c - v.y * s, v.x * s + v.y * c)
    }

    public static func build(look: SlimeLook, ring: [SIMD2<Double>], anim: TraitAnim, time: Double, detail: DetailLevel, mini: Bool) -> Output {
        var out = Output()
        guard ring.count >= 6, !look.isPlain || look.surface == .fire else { return out }
        let n = ring.count
        var c = SIMD2<Double>.zero
        for p in ring { c += p }
        c /= Double(n)
        func at(_ angle: Double) -> (p: SIMD2<Double>, normal: SIMD2<Double>) {
            let p = ring[index(angle: angle, count: n)]
            return (p, unit(p - c))
        }
        let s = mini ? 0.85 : 1.0
        let up = SIMD2<Double>(0, -1)
        let top = -Double.pi / 2

        // Ears: goo for cat and fox (they jiggle and twitch), crystal shards for ice.
        switch look.ears {
        case .cat, .fox:
            let fox = look.ears == .fox
            for side in [-1.0, 1.0] {
                let base = at(top + side * 0.68)
                let twitch = side < 0 ? anim.earTwitch.x : anim.earTwitch.y
                let dir = rotate(unit(base.normal * 0.55 + up * 0.85), by: side * (twitch + anim.earFlop))
                let r = (fox ? 0.19 : 0.16) * s
                let len = (fox ? 0.36 : 0.30) * s
                out.blobs.append(Blob(position: base.p + dir * len, radius: r, stretch: fox ? 2.1 : 1.9, heading: atan2(dir.y, dir.x)))
                if detail >= .medium {
                    out.traits.append(TraitFrame(kind: .earInner(look.ears), side: side, anchor: base.p + dir * (len * 0.5), direction: dir, scale: s, phase: 0))
                    let perp = SIMD2(-dir.y, dir.x) * (side < 0 ? 1.0 : -1.0)
                    out.traits.append(TraitFrame(kind: .gloss, side: side, anchor: base.p + dir * (len * 1.05) + perp * (r * 0.45), direction: dir, scale: s * 0.8, phase: 0))
                }
            }
        case .ice:
            for side in [-1.0, 1.0] {
                let base = at(top + side * 0.62)
                let dir = unit(base.normal * 0.5 + up * 0.9)
                out.traits.append(TraitFrame(kind: .shard, side: side, anchor: base.p, direction: dir, scale: s, phase: 0))
            }
        case .none:
            break
        }

        // Horns.
        switch look.horns {
        case .demonPair:
            for side in [-1.0, 1.0] {
                let base = at(top + side * 0.52)
                out.traits.append(TraitFrame(kind: .horn(.demonPair), side: side, anchor: base.p, direction: unit(base.normal * 0.7 + up * 0.6), scale: s, phase: 0))
            }
        case .dragonPair:
            for side in [-1.0, 1.0] {
                let base = at(top + side * 0.5)
                out.traits.append(TraitFrame(kind: .horn(.dragonPair), side: side, anchor: base.p, direction: unit(base.normal * 0.45 + up * 0.9), scale: s, phase: 0))
            }
        case .oniSingle:
            let base = at(top)
            out.traits.append(TraitFrame(kind: .horn(.oniSingle), side: 0, anchor: base.p, direction: unit(base.normal), scale: s, phase: 0))
        case .unicorn:
            let base = at(top)
            out.traits.append(TraitFrame(kind: .horn(.unicorn), side: 0, anchor: base.p, direction: rotate(unit(base.normal), by: 0.12), scale: s, phase: 0))
        case .none:
            break
        }

        // The drop tip: two goo links curling up and back from the top-right, lagging the body.
        if look.tip {
            let base = at(top + 0.78)
            let dir0 = rotate(unit(base.normal * 0.5 + up * 0.9), by: 0.15 + anim.tipLag)
            let p1 = base.p + dir0 * (0.3 * s)
            out.blobs.append(Blob(position: p1, radius: 0.2 * s, stretch: 1.6, heading: atan2(dir0.y, dir0.x)))
            let dir1 = rotate(dir0, by: 0.6 + anim.tipLag * 0.6)
            let p2 = p1 + dir1 * (0.3 * s)
            out.blobs.append(Blob(position: p2, radius: 0.12 * s, stretch: 1.5, heading: atan2(dir1.y, dir1.x)))
            if detail >= .medium {
                out.traits.append(TraitFrame(kind: .gloss, side: 1, anchor: p1 + SIMD2(-0.06, -0.09) * s, direction: dir0, scale: s * 0.9, phase: 0))
            }
        }

        // Wings rise from the shoulders, up and out, and flap about them.
        if look.wings != .none, !mini {
            let fairy = look.wings == .fairy
            for side in [-1.0, 1.0] {
                let base = at(top + side * (fairy ? 1.05 : 1.15))
                let dir = unit(base.normal * (fairy ? 0.35 : 0.45) + up * 0.95)
                out.traits.append(TraitFrame(kind: .wing(look.wings), side: side, anchor: base.p, direction: dir, scale: s * (fairy ? 1.0 : 0.85), phase: anim.wingFlap))
            }
        }

        // Antenna: a goo stalk with a ball that lags behind the body.
        if look.antenna {
            let base = at(top)
            let dir = rotate(unit(base.normal), by: anim.antenna)
            let heading = atan2(dir.y, dir.x)
            out.blobs.append(Blob(position: base.p + dir * (0.18 * s), radius: 0.075 * s, stretch: 1.5, heading: heading))
            out.blobs.append(Blob(position: base.p + dir * (0.36 * s), radius: 0.07 * s, stretch: 1.5, heading: heading))
            let ball = base.p + dir * (0.58 * s)
            out.blobs.append(Blob(position: ball, radius: 0.13 * s))
            out.traits.append(TraitFrame(kind: .antennaBall, side: 0, anchor: ball, direction: dir, scale: s, phase: 0))
        }

        // Tail from the lower left, curling up; a fish gets a solid fin instead.
        if look.tail != .none, !mini {
            let base = at(.pi / 2 + 0.9)
            if look.tail == .fish {
                out.traits.append(TraitFrame(kind: .fin, side: -1, anchor: base.p, direction: unit(base.normal * 0.8 + SIMD2(0, 0.25)), scale: s, phase: anim.tailWag))
            } else {
                let (count, r0, r1, seg, curl, straight) = tailChain(look.tail)
                // Run out to the left (never below the floor), then curl up.
                var a = max(atan2(base.normal.y, base.normal.x), .pi * 0.98)
                var p = base.p
                var dir = base.normal
                for k in 0..<count {
                    a += (k < straight ? 0 : curl) + anim.tailWag * (Double(k + 1) / Double(count))
                    dir = SIMD2(cos(a), sin(a))
                    p += dir * seg
                    let r = r0 + (r1 - r0) * Double(k) / Double(max(1, count - 1))
                    out.blobs.append(Blob(position: p, radius: r, stretch: 1.3, heading: a))
                }
                if look.tail == .dragon || look.tail == .fox {
                    out.traits.append(TraitFrame(kind: .tailTip(look.tail), side: -1, anchor: p, direction: dir, scale: s, phase: 0))
                }
                if detail >= .medium, out.blobs.count >= 2, look.tail != .dragon {
                    let b = out.blobs[out.blobs.count - count + 1]
                    out.traits.append(TraitFrame(kind: .gloss, side: -1, anchor: b.position + SIMD2(-0.25, -0.55) * b.radius, direction: up, scale: s * 0.9, phase: 0))
                }
            }
        }

        // Flame tongues on a fire slime are goo too.
        if look.surface == .fire {
            for (k, off) in [0.0, -0.42, 0.42].enumerated() {
                let base = at(top + off)
                let ph = time * 2 * .pi * (1.4 + 0.3 * Double(k)) + Double(k) * 2.1
                let bob = detail >= .medium ? 0.07 * sin(ph) : 0
                let lift = (k == 0 ? 0.3 : 0.2) * s + bob
                let dir = unit(base.normal * (k == 0 ? 0.3 : 0.75) + up * 0.8 + SIMD2(detail >= .medium ? 0.08 * sin(ph * 0.7) : 0, 0))
                out.blobs.append(Blob(position: base.p + dir * lift, radius: (k == 0 ? 0.23 : 0.16) * s, stretch: k == 0 ? 1.6 : 1.5, heading: atan2(dir.y, dir.x)))
                if k == 0, detail >= .medium {
                    out.traits.append(TraitFrame(kind: .gloss, side: 1, anchor: base.p + dir * (lift * 0.9) + SIMD2(-0.08, 0) * s, direction: dir, scale: s * 0.8, phase: 0))
                }
            }
        }
        // Features are body material: one shading pass over the whole goo path, not a droplet each.
        for i in out.blobs.indices { out.blobs[i].shaded = false }
        return out
    }
}
