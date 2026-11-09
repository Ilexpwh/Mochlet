import Testing
import simd
@testable import SlimeKit

/// Anime timing: anticipation, air stretch, landing squash, the jelly's ring-out and the poke dent.
@Suite struct MotionTests {
    /// Local extrema of a series outside a deadband around its final value.
    static func extrema(_ series: [(t: Double, v: Double)], deadband: Double) -> [(t: Double, v: Double)] {
        guard series.count > 2 else { return [] }
        let final = series.last!.v
        var out: [(t: Double, v: Double)] = []
        for i in 1..<(series.count - 1) {
            let a = series[i - 1].v - final, b = series[i].v - final, c = series[i + 1].v - final
            if abs(b) > deadband, (b > a && b >= c) || (b < a && b <= c) { out.append(series[i]) }
        }
        return out
    }

    @Test func pokeDentsLocally() {
        var body = SoftBody(params: .main)
        let rest = body.points
        let i = rest.indices.max { rest[$0].x < rest[$1].x }!
        let j = rest.indices.min { rest[$0].x < rest[$1].x }!
        body.apply(.poke(angle: 0, depth: 0.25))
        for _ in 0..<2 { _ = body.step(h: SoftBodyParams.substep) }
        #expect(rest[i].x - body.points[i].x >= 0.15, "dent \(rest[i].x - body.points[i].x) R")
        #expect(simd_distance(rest[j], body.points[j]) < 0.05, "the far side is untouched")
        var t = 0.0
        var dev: [(Double, Double)] = []
        while t < 1.5 {
            _ = body.step(h: SoftBodyParams.substep)
            t += SoftBodyParams.substep
            dev.append((t, zip(rest, body.points).map { simd_distance($0, $1) }.max()!))
        }
        let at07 = dev.first { $0.0 >= 0.7 }!.1
        let at15 = dev.last!.1
        #expect(at07 < 0.08, "mostly recovered by 0.7 s (\(at07))")
        #expect(at15 < 0.04, "recovered by 1.5 s (\(at15))")
    }

    @MainActor @Test func hopAnticipates() {
        let e = SlimeEngine(profile: .main, seed: 2)
        e.simulate(1.5)
        e.trigger(.happy)
        var t = 0.0
        var crouched = false
        var takeoff: Double?
        var stretched = false
        while t < 0.6 {
            e.simulate(1.0 / 240.0)
            t += 1.0 / 240.0
            let squash = e.body.squash
            if t < 0.10, !e.body.airborne, squash < 0.95 { crouched = true }
            if takeoff == nil, e.body.airborne { takeoff = t }
            if let to = takeoff, t - to < 0.10, squash > 1.05 { stretched = true }
        }
        #expect(crouched, "squashes before leaving the floor")
        #expect(takeoff != nil && takeoff! >= 0.10 && takeoff! <= 0.17, "take-off at \(String(describing: takeoff))")
        #expect(stretched, "stretches tall right after take-off")
    }

    @MainActor @Test func landingWobblesVisibly() throws {
        let e = SlimeEngine(profile: .main, seed: 2)
        e.simulate(1.5)
        e.greet()
        var t = 0.0
        var wasAirborne = false
        var landedAt: Double?
        var tops: [(t: Double, v: Double)] = []
        while t < 4.0 {
            e.simulate(1.0 / 120.0)
            t += 1.0 / 120.0
            let f = e.frame()
            if f.airborne { wasAirborne = true } else if wasAirborne, landedAt == nil { landedAt = t }
            if let l = landedAt { tops.append((t - l, f.topY)) }
        }
        _ = try #require(landedAt)
        let final = tops.last!.v
        let amplitude = tops.map { abs($0.v - final) }.max()!
        let ex = Self.extrema(tops, deadband: 0.05 * amplitude)
        // The first compression (top down ≈ 0.45 R, height ≈ 0.73) and the first rebound.
        #expect(amplitude > 0.35 && amplitude < 0.60, "landing squash \(amplitude) R")
        #expect(ex.count >= 4, "extrema \(ex.count)")
        if ex.count >= 3 {
            #expect(ex[0].v - final > 0 && ex[0].t < 0.3, "the first extremum is the squash at \(ex[0].t) s")
            let rebound = final - ex[1].v
            #expect(rebound > 0.12 && rebound < 0.45, "rebound \(rebound) R")
            let period = ex[2].t - ex[0].t
            #expect(period > 0.35 && period < 0.60, "wobble period \(period) s")
            #expect(abs(ex[2].v - final) < abs(ex[0].v - final) * 0.85, "the wobble decays")
        }
        // Crossings of the final value outside the deadband: two to three visible cycles
        // (breathing is on, so the tail is measured on the raw body in PhysicsTests).
        var crossings = 0
        var lastSign = 0.0
        for s in tops {
            let d = s.v - final
            guard abs(d) > 0.05 * amplitude else { continue }
            let sign: Double = d > 0 ? 1 : -1
            if lastSign != 0, sign != lastSign { crossings += 1 }
            lastSign = sign
        }
        #expect(crossings >= 4, "\(crossings) crossings")
        let settle = tops.last { abs($0.v - final) > 0.05 * amplitude }?.t ?? 0
        #expect(settle > 0.8 && settle < 3.2, "settled \(settle) s after landing")
    }

    @MainActor @Test func pressSquintsAndDents() {
        let e = SlimeEngine(profile: .main, seed: 2)
        e.simulate(1.5)
        let before = e.frame()
        e.pressBegan(at: SIMD2(0.9, -1.0))
        e.simulate(1.0 / 60.0)
        let f = e.frame()
        #expect(f.eyes.allSatisfy { $0.shape == .squint }, "squints on contact: \(f.eyes.map(\.shape))")
        // The ring moved in on the pressed side and not on the far side.
        let right = zip(before.ring, f.ring).filter { $0.0.x > 0.9 }.map { $0.0.x - $0.1.x }.max() ?? 0
        let left = zip(before.ring, f.ring).filter { $0.0.x < -0.9 }.map { abs($0.0.x - $0.1.x) }.max() ?? 0
        #expect(right > 0.08, "dent on the pressed side \(right)")
        #expect(left < 0.04, "far side still \(left)")
        e.pressEnded()
        e.simulate(0.4)
        #expect(e.frame().eyes.allSatisfy { $0.shape != .squint })
    }

    @MainActor @Test func firmStaysCalm() {
        var look = SlimeLook.plain
        look.feel = .firm
        var body = SoftBody(params: SoftBodyParams.main.applying(look: look, mini: false))
        body.drop(fromHeight: 1.6, initialSpeed: 2.0)
        var landed = false
        var t = 0.0
        var tops: [(t: Double, v: Double)] = []
        while t < 3.0 {
            let ev = body.step(h: SoftBodyParams.substep)
            t += SoftBodyParams.substep
            if !landed, ev.contains(where: { if case .landed = $0 { return true } else { return false } }) { landed = true }
            if landed { tops.append((t, body.topY)) }
        }
        let final = tops.last!.v
        let amplitude = tops.map { abs($0.v - final) }.max()!
        var crossings = 0
        var lastSign = 0.0
        for s in tops {
            let d = s.v - final
            guard abs(d) > 0.05 * amplitude else { continue }
            let sign: Double = d > 0 ? 1 : -1
            if lastSign != 0, sign != lastSign { crossings += 1 }
            lastSign = sign
        }
        #expect(crossings <= 3, "firm rings less than the jelly (\(crossings) crossings)")
    }
}
