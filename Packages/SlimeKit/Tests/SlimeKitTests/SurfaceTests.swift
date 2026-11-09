import Testing
import simd
@testable import SlimeKit

/// Surface details: sweat, strain creases, the lagging core and the melting face.
@Suite struct SurfaceTests {
    @MainActor @Test func threeQuickPokesSweat() {
        let e = SlimeEngine(profile: .main, seed: 2)
        e.simulate(1)
        for _ in 0..<2 {
            e.pressBegan(at: SIMD2(0.6, -1.0))
            e.simulate(0.1)
            e.pressEnded()
            e.simulate(0.2)
        }
        #expect(!e.frame().accessories.contains { $0.kind == .sweat }, "two pokes: no sweat yet")
        e.pressBegan(at: SIMD2(0.6, -1.0))
        e.simulate(0.05)
        let f = e.frame()
        let sweat = f.accessories.first { $0.kind == .sweat }
        #expect(sweat != nil, "the third quick poke sweats")
        if let s = sweat {
            let d = Metaball.polygonDistance(s.anchor, f.ring)
            #expect(abs(d) < 0.12, "the drop sits on the surface (distance \(d))")
            #expect(s.anchor.x > 0 && s.anchor.y < -0.9, "on the upper right cheek: \(s.anchor)")
        }
        e.pressEnded()
        e.simulate(0.4)
        if let s = sweat, let l = e.frame().accessories.first(where: { $0.kind == .sweat }) {
            #expect(l.anchor.y > s.anchor.y + 0.05, "the drop slides down: \(s.anchor.y) → \(l.anchor.y)")
        }
        e.simulate(0.8)
        #expect(!e.frame().accessories.contains { $0.kind == .sweat }, "gone within a second")
    }

    @MainActor @Test func creasesFollowAPoke() {
        let e = SlimeEngine(profile: .main, seed: 2)
        e.simulate(1)
        #expect(e.frame().creases.isEmpty)
        e.pressBegan(at: SIMD2(0.9, -1.0))
        e.simulate(0.02)
        let f = e.frame()
        #expect(f.creases.count == 3)
        for c in f.creases {
            #expect(c.anchor.x > 0.3, "creases on the poked side: \(c.anchor)")
            #expect(abs(Metaball.polygonDistance(c.anchor, f.ring)) < 0.15, "just inside the outline")
            #expect(c.length > 0.1 && c.alpha > 0.8)
            #expect(abs(simd_length(c.direction) - 1) < 1e-6)
        }
        e.pressEnded()
        e.simulate(0.7)
        #expect(e.frame().creases.isEmpty, "faded by 0.7 s")
    }

    @MainActor @Test func puffCreasesBothCheeks() {
        let e = SlimeEngine(profile: .main, seed: 2)
        e.simulate(1)
        e.trigger(.puff)
        e.simulate(0.4)
        let p = e.frame()
        #expect(p.creases.count == 4)
        #expect(p.creases.contains { $0.anchor.x > 0.5 } && p.creases.contains { $0.anchor.x < -0.5 })
        e.simulate(SlimeEmote.puff.duration + 1.0)
        #expect(e.frame().creases.isEmpty)
    }

    @MainActor @Test func coreLagsTheBody() {
        let e = SlimeEngine(profile: .main, seed: 2)
        e.simulate(1.5)
        e.greet()
        var samples: [(t: Double, cy: Double, lag: Double)] = []
        var t = 0.0
        while t < 3.5 {
            e.simulate(1.0 / 120.0)
            t += 1.0 / 120.0
            let f = e.frame()
            let c = f.ring.reduce(SIMD2<Double>.zero, +) / Double(f.ring.count)
            samples.append((t, c.y, f.core.y - (c.y - 0.04)))
        }
        // The landing squash (lowest centroid) and the core's deepest dive after it.
        let landIdx = samples.indices.max { samples[$0].cy < samples[$1].cy }!
        let peak = samples[landIdx...].max { abs($0.lag) < abs($1.lag) }!
        #expect(abs(peak.lag) >= 0.03, "the core overshoots the body by \(peak.lag) R")
        let delay = peak.t - samples[landIdx].t
        #expect(delay >= 0.02 && delay <= 0.3, "the core peaks \(delay) s after the body")
        #expect(abs(samples.last!.lag) < 0.02, "and settles (lag \(samples.last!.lag))")
    }

    @MainActor @Test func coreScaleTrailsTheBody() {
        let e = SlimeEngine(profile: .main, seed: 2)
        e.simulate(1.5)
        let rest = e.frame().coreScale
        #expect(abs(rest.x - 1) < 0.06 && abs(rest.y - 1) < 0.06, "at rest the core is body sized: \(rest)")
        e.greet()
        var maxDiff = 0.0
        var t = 0.0
        while t < 1.5 {
            e.simulate(1.0 / 120.0)
            t += 1.0 / 120.0
            let f = e.frame()
            maxDiff = max(maxDiff, abs(f.coreScale.y - f.body.scaleY))
        }
        #expect(maxDiff > 0.03, "the core scale trails the body through a landing (\(maxDiff))")
    }

    @MainActor @Test func meltSlidesTheFaceDown() {
        let e = SlimeEngine(profile: .main, seed: 2)
        e.simulate(1)
        func localEyeY() -> Double {
            let f = e.frame()
            let v = f.body.matrix.inverse * (f.eyes[0].center - f.body.origin)
            return v.y
        }
        let before = localEyeY()
        e.trigger(.melt)
        e.simulate(0.7)
        let during = localEyeY()
        #expect(during - before >= 0.18, "the face slid \(during - before) R down the body")
        e.simulate(SlimeEmote.melt.duration + 1.0)
        #expect(abs(localEyeY() - before) < 0.03, "and came back")
    }

    @Test func ringPointInterpolates() {
        let ring = RestProfile.dome.ring(count: 24)
        let top = TraitRig.point(angle: -.pi / 2, ring: ring)
        #expect(abs(top.x) < 1e-9 && abs(top.y - ring[0].y) < 1e-9)
        let between = TraitRig.point(angle: -.pi / 2 + .pi / 24, ring: ring)
        #expect(abs(between.x - (ring[0].x + ring[1].x) / 2) < 1e-9)
        let wrapped = TraitRig.point(angle: -.pi / 2 + 2 * .pi, ring: ring)
        #expect(abs(wrapped.y - top.y) < 1e-9)
    }
}
