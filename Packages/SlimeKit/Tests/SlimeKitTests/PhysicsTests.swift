import Testing
import simd
@testable import SlimeKit

@Suite struct SoftBodyTests {
    @Test func parametersAreStable() {
        #expect(SoftBodyParams.main.isStable)
        #expect(SoftBodyParams.mini.isStable)
    }

    @Test func restingShapeIsStillAndAboveTheFloor() {
        var body = SoftBody(params: .main)
        let before = body.points
        for _ in 0..<240 { _ = body.step(h: SoftBodyParams.substep) }
        var maxMove = 0.0
        for (a, b) in zip(before, body.points) { maxMove = max(maxMove, simd_distance(a, b)) }
        #expect(maxMove < 0.002, "a settled body must not drift (moved \(maxMove))")
        #expect(body.points.allSatisfy { $0.y <= 1e-9 })
        #expect(body.areaRatio > 0.85 && body.areaRatio < 1.1, "area ratio \(body.areaRatio)")
        #expect(body.contactWidth > 0.7 && body.contactWidth < 1.4, "contact width \(body.contactWidth)")
        #expect(body.topY < -1.7 && body.topY > -2.0, "top \(body.topY)")
    }

    @Test func squashPreservesVolumeByConstruction() {
        var body = SoftBody(params: .main)
        body.squash = 0.8
        let anchors = body.anchors()
        let xs = anchors.map(\.x)
        let ys = anchors.map(\.y)
        let w = xs.max()! - xs.min()!
        let h = ys.max()! - ys.min()!
        #expect(abs(w - 2 / 0.8) < 1e-9)
        #expect(abs(h - 2 * 0.8) < 1e-9)
    }

    @Test func landingSettlesWithOvershoots() {
        var body = SoftBody(params: .main)
        body.drop(fromHeight: 1.6, initialSpeed: 2.0)
        var landedAt: Double?
        var t = 0.0
        var tops: [(Double, Double)] = []
        while t < 3.0 {
            let ev = body.step(h: SoftBodyParams.substep)
            t += SoftBodyParams.substep
            if landedAt == nil, ev.contains(where: { if case .landed = $0 { return true } else { return false } }) { landedAt = t }
            if let l = landedAt { tops.append((t - l, body.topY)) }
        }
        let landed = try! #require(landedAt)
        #expect(landed > 0.3 && landed < 0.55, "landed at \(landed)")
        let final = tops.last!.1
        let amplitude = tops.map { abs($0.1 - final) }.max()!
        var signChanges = 0
        var lastSign = 0.0
        for (_, y) in tops {
            let s = (y - final) > 0 ? 1.0 : -1.0
            if lastSign != 0, s != lastSign, abs(y - final) > amplitude * 0.03 { signChanges += 1 }
            if abs(y - final) > amplitude * 0.03 { lastSign = s }
        }
        #expect(signChanges >= 2, "expected visible overshoots, got \(signChanges)")
        let settleTime = tops.last { abs($0.1 - final) > amplitude * 0.02 }?.0 ?? 0
        #expect(settleTime > 0.5 && settleTime < 1.6, "settled in \(settleTime)s")
        #expect(body.points.allSatisfy { $0.y <= 1e-9 })
    }

    @Test func areaStaysNearRestAfterASlap() {
        var body = SoftBody(params: .main)
        body.apply(.slap(side: 1, strength: 1.0))
        var minRatio = 1.0
        var maxRatio = 1.0
        var t = 0.0
        var ratioAt50ms = 1.0
        while t < 1.5 {
            _ = body.step(h: SoftBodyParams.substep)
            t += SoftBodyParams.substep
            minRatio = min(minRatio, body.areaRatio)
            maxRatio = max(maxRatio, body.areaRatio)
            if abs(t - 0.05) < SoftBodyParams.substep / 2 { ratioAt50ms = body.areaRatio }
        }
        #expect(minRatio > 0.88 && maxRatio < 1.12, "area ratio range \(minRatio)…\(maxRatio)")
        #expect(abs(ratioAt50ms - body.areaRatio) < 0.08)
    }

    @Test func jumpHeightAndAirtime() {
        var body = SoftBody(params: .main)
        body.apply(.jump(v0: 2.6))
        var t = 0.0
        var peak = 0.0
        var airtime: Double?
        while t < 2 {
            let ev = body.step(h: SoftBodyParams.substep)
            t += SoftBodyParams.substep
            peak = max(peak, -body.root.y)
            if airtime == nil, ev.contains(where: { if case .landed = $0 { return true } else { return false } }) { airtime = t }
        }
        #expect(abs(peak - 0.338) < 0.02, "peak \(peak)")
        let air = try! #require(airtime)
        #expect(abs(air - 0.52) < 0.03, "airtime \(air)")
    }

    @Test func determinism() {
        var a = SoftBody(params: .main)
        var b = SoftBody(params: .main)
        a.apply(.wobble(angle: -1.2, strength: 0.5))
        b.apply(.wobble(angle: -1.2, strength: 0.5))
        for _ in 0..<480 {
            _ = a.step(h: SoftBodyParams.substep)
            _ = b.step(h: SoftBodyParams.substep)
        }
        #expect(a.points == b.points)
    }

    @Test func interpolationStaysBetweenSteps() {
        var body = SoftBody(params: .main)
        body.apply(.puff(scale: 0.2))
        _ = body.step(h: SoftBodyParams.substep)
        let mid = body.interpolated(alpha: 0.5)
        let end = body.interpolated(alpha: 1)
        #expect(end == body.points)
        #expect(mid.count == body.count)
    }
}

@Suite struct BodyFrameTests {
    @Test func identityOnReference() {
        let body = SoftBody(params: .main)
        let f = BodyFrame.fit(reference: body.referenceRing, referenceCentroid: body.referenceCentroid, current: body.referenceRing)
        #expect(abs(f.scaleX - 1) < 1e-6)
        #expect(abs(f.scaleY - 1) < 1e-6)
        #expect(abs(f.rotation) < 1e-6)
    }

    @Test func recoversScaleAndTranslation() {
        let body = SoftBody(params: .main)
        let moved = body.referenceRing.map { SIMD2($0.x * 1.2 + 0.5, $0.y * 0.8 - 0.3) }
        let f = BodyFrame.fit(reference: body.referenceRing, referenceCentroid: body.referenceCentroid, current: moved)
        #expect(abs(f.scaleX - 1.2) < 1e-6)
        #expect(abs(f.scaleY - 0.8) < 1e-6)
        let p = f.transform(SIMD2(0, -1))
        #expect(abs(p.x - 0.5) < 1e-6 && abs(p.y - (-0.8 - 0.3)) < 1e-6)
    }
}

@Suite struct BreathTests {
    @Test func boundsAndSmoothness() {
        var b = BreathOscillator(seed: 3)
        var t = 0.0
        var prev = b.value
        var lo = 1.0
        var hi = 1.0
        while t < 30 {
            b.advance(dt: 1.0 / 240.0, time: t)
            t += 1.0 / 240.0
            lo = min(lo, b.value)
            hi = max(hi, b.value)
            #expect(abs(b.value - prev) < 0.002)
            prev = b.value
        }
        #expect(lo > 1 - 0.02 * 1.4 && hi < 1 + 0.02 * 1.4)
        #expect(hi - lo > 0.02)
    }
}

@Suite struct DropletTests {
    @Test func bouncesAndSettles() {
        var d = Droplet(id: 1, position: SIMD2(0, -2), velocity: SIMD2(1, 0), radius: 0.3)
        var bounces = 0
        for _ in 0..<(240 * 3) {
            if d.step(h: 1.0 / 240.0, gravity: 10) { bounces += 1 }
        }
        #expect(bounces >= 1)
        #expect(abs(d.position.y + 0.3) < 1e-6)
        #expect(d.stretch >= 1 && d.stretch <= 1.18)
    }
}
