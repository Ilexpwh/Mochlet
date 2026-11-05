import Testing
import simd
@testable import SlimeKit

@Suite struct BlinkTests {
    @Test func intervalStatistics() {
        var rng = SeededRandom(seed: 42)
        var b = BlinkScheduler()
        b.prime(at: 0, rng: &rng)
        var t = 0.0
        var starts: [Double] = []
        var lastCount = 0
        var doubles = 0
        var lastStart = -10.0
        while starts.count < 10_000 {
            b.advance(to: t, rng: &rng)
            if b.count != lastCount {
                let added = b.count - lastCount
                lastCount = b.count
                starts.append(t)
                if added == 2 { doubles += 1; starts.append(t + b.doubleGap) }
                lastStart = t
            }
            t += 1.0 / 120.0
        }
        _ = lastStart
        let singles = zip(starts, starts.dropFirst()).map { $1 - $0 }.filter { $0 > 1 }
        let mean = singles.reduce(0, +) / Double(singles.count)
        #expect(abs(mean - 3.85) < 0.15, "mean interval \(mean)")
        #expect(singles.allSatisfy { $0 >= 2.2 - 0.02 && $0 <= 5.4 + 0.3 })
        let ratio = Double(doubles) / Double(lastCount - doubles)
        #expect(abs(ratio - 0.22) < 0.03, "double ratio \(ratio)")
    }

    @Test func blinkClosesAndReopens() {
        var rng = SeededRandom(seed: 1)
        var b = BlinkScheduler()
        b.blinkNow(at: 0, rng: &rng)
        var minOpen = 1.0
        var t = 0.0
        while t < 0.4 {
            let o = b.advance(to: t, rng: &rng)
            minOpen = min(minOpen, min(o.x, o.y))
            t += 1.0 / 240.0
        }
        #expect(minOpen < 0.01)
        #expect(b.openness == SIMD2(1, 1))
    }

    @Test func suppressionHoldsBlinks() {
        var rng = SeededRandom(seed: 9)
        var b = BlinkScheduler()
        b.prime(at: 0, rng: &rng)
        b.suppressed = true
        var t = 0.0
        while t < 20 {
            b.advance(to: t, rng: &rng)
            t += 1.0 / 60.0
        }
        #expect(b.count == 0)
    }
}

@Suite struct EyeRigTests {
    @Test func farEyeDisappearsPastTheSilhouette() {
        let rig = EyeRig()
        let straight = rig.eye(side: 1, yaw: 0, pitch: 0)
        #expect(straight.visible)
        let turned = rig.eye(side: 1, yaw: 1.25, pitch: 0)
        #expect(!turned.visible)
        let other = rig.eye(side: -1, yaw: 1.25, pitch: 0)
        #expect(other.visible)
    }

    @Test func foreshorteningIsMonotonic() {
        let rig = EyeRig()
        var last = 2.0
        for yaw in stride(from: 0.0, through: 1.0, by: 0.1) {
            let p = rig.eye(side: 1, yaw: yaw, pitch: 0)
            #expect(p.foreshorten.x <= last + 1e-9)
            last = p.foreshorten.x
        }
    }
}

@Suite struct GazeTests {
    @Test func saturates() {
        let g = Gaze()
        let far = g.pointerTarget(SIMD2(5, 0))
        #expect(far.x > 0.2 && far.x <= 0.62)
        let veryFar = g.pointerTarget(SIMD2(20, 0))
        #expect(veryFar.x < 0.62 && veryFar.x > 0.3)
        let gone = g.pointerTarget(SIMD2(40, 0))
        #expect(abs(gone.x) < 1e-9)
    }

    @Test func approachesWithTau() {
        var g = Gaze()
        g.setTarget(SIMD2(0.5, 0))
        var t = 0.0
        while t < 0.17 - 1e-9 {
            g.advance(dt: 1.0 / 240.0)
            t += 1.0 / 240.0
        }
        #expect(abs(g.yaw - 0.5 * 0.632) < 0.02)
    }
}

@Suite struct AnimationTests {
    @Test func retargetContinuesFromCurrentValue() {
        var v = AnimatedValue(0)
        v.animate(to: 1, duration: 1, ease: .linear, at: 0)
        v.advance(to: 0.5)
        #expect(abs(v.value - 0.5) < 1e-9)
        v.animate(to: 0, duration: 1, ease: .linear, at: 0.5)
        v.advance(to: 0.5)
        #expect(abs(v.value - 0.5) < 1e-9)
        v.advance(to: 1.0)
        #expect(abs(v.value - 0.25) < 1e-9)
    }

    @Test func keyframesRunInSequence() {
        var v = AnimatedValue(1)
        v.animate(keys: [.init(to: 0.5, duration: 0.1, ease: .linear), .init(to: 2, duration: 0.1, ease: .linear)], at: 0)
        v.advance(to: 0.1)
        #expect(abs(v.value - 0.5) < 1e-9)
        v.advance(to: 0.15)
        #expect(abs(v.value - 1.25) < 1e-9)
        v.advance(to: 0.5)
        #expect(v.value == 2 && !v.isAnimating)
    }

    @Test func springHasNoDiscontinuityOnRetarget() {
        var s = Spring1D(value: 0, omega: 20, zeta: 0.5)
        s.target = 1
        for _ in 0..<24 { s.advance(1.0 / 240.0) }
        let v = s.value
        s.target = -1
        s.advance(1.0 / 240.0)
        #expect(abs(s.value - v) < 0.05)
    }

    @Test func easeEndpoints() {
        for e in [Ease.linear, .inQuad, .outQuad, .inOutQuad, .outCubic, .inOutCubic, .inOutSine, .outBack, .outExpo, .outElastic] {
            #expect(abs(e.apply(0)) < 1e-9)
            #expect(abs(e.apply(1) - 1) < 1e-9)
        }
    }
}

@Suite struct ClockTests {
    @Test func sixtyAndOneTwentyHzRunTheSameSubsteps() {
        var a = SlimeClock()
        var b = SlimeClock()
        _ = a.advance(to: 0)
        _ = b.advance(to: 0)
        var stepsA = 0
        var stepsB = 0
        for i in 1...120 { stepsA += a.advance(to: Double(i) / 60.0).steps }
        for i in 1...240 { stepsB += b.advance(to: Double(i) / 120.0).steps }
        #expect(abs(stepsA - stepsB) <= 1)
        #expect(abs(stepsA - 480) <= 1)
    }

    @Test func clampsLongFrames() {
        var c = SlimeClock()
        _ = c.advance(to: 0)
        let r = c.advance(to: 5)
        #expect(r.steps == 24)
    }
}

@Suite struct RandomTests {
    @Test func seededSequencesRepeat() {
        var a = SeededRandom(seed: 5)
        var b = SeededRandom(seed: 5)
        for _ in 0..<100 { #expect(a.next() == b.next()) }
        var units = SeededRandom(seed: 11)
        for _ in 0..<1000 {
            let u = units.unit()
            #expect(u >= 0 && u < 1)
        }
    }

    @Test func noiseIsBoundedAndContinuous() {
        let n = ValueNoise(seed: 3)
        var prev = n.value(at: 0)
        var t = 0.0
        while t < 50 {
            let v = n.value(at: t)
            #expect(v >= -1 && v <= 1)
            #expect(abs(v - prev) < 0.05)
            prev = v
            t += 0.01
        }
    }
}
