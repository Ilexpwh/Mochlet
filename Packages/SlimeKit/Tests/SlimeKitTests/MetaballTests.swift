import Testing
import simd
@testable import SlimeKit

@Suite struct MetaballTests {
    static func circle(_ c: SIMD2<Double>, _ r: Double, n: Int = 24) -> [SIMD2<Double>] {
        (0..<n).map { i in
            let a = Double(i) / Double(n) * 2 * .pi
            return c + SIMD2(cos(a), sin(a)) * r
        }
    }

    @Test func plainRingTracesOneLoopWithTheSameArea() {
        let ring = Self.circle(SIMD2(0, -0.86), 1)
        let loops = Metaball.contour(ring: ring, blobs: [])
        #expect(loops.count == 1)
        let a = Metaball.area(loops[0])
        #expect(abs(a - .pi) / .pi < 0.06)
    }

    @Test func farBlobStaysSeparate() {
        let ring = Self.circle(SIMD2(0, -0.86), 1)
        let loops = Metaball.contour(ring: ring, blobs: [Blob(position: SIMD2(3.5, -0.4), radius: 0.4)])
        #expect(loops.count == 2)
        let small = loops.min { Metaball.area($0) < Metaball.area($1) }!
        #expect(abs(Metaball.area(small) - .pi * 0.16) / (.pi * 0.16) < 0.12)
    }

    @Test func nearBlobBridgesIntoOneLoop() {
        let ring = Self.circle(SIMD2(0, -0.86), 1)
        // Gap of 0.2 R between the ring (edge at x = 1) and the blob (edge at x = 1.2).
        let loops = Metaball.contour(ring: ring, blobs: [Blob(position: SIMD2(1.6, -0.86), radius: 0.4)])
        #expect(loops.count == 1)
        #expect(Metaball.area(loops[0]) > .pi + .pi * 0.16)
    }

    @Test func holesAreFilled() {
        // Four blobs around an empty centre bridge into a ring; the hole must not survive.
        let ring = Self.circle(SIMD2(0, -0.86), 0.3)
        let blobs = [SIMD2(1.2, -0.86), SIMD2(-1.2, -0.86), SIMD2(0, 0.34), SIMD2(0, -2.06)].map { Blob(position: $0, radius: 0.75) }
        let loops = Metaball.contour(ring: ring, blobs: blobs)
        #expect(loops.count == 1)
        for loop in loops {
            #expect(Metaball.polygonDistance(SIMD2(0.6, -1.4), loop) <= 0.05)
        }
    }

    @Test func signedDistanceIsNegativeInside() {
        let ring = Self.circle(.zero, 1)
        #expect(Metaball.polygonDistance(.zero, ring) < -0.9)
        #expect(abs(Metaball.polygonDistance(SIMD2(2, 0), ring) - 1) < 0.02)
    }

    @MainActor @Test func contourIsCheap() {
        let ring = Self.circle(SIMD2(0, -0.86), 0.5)
        let blobs = (0..<5).map { i in Blob(position: SIMD2(cos(Double(i)) * 2, -1 - sin(Double(i))), radius: 0.4, stretch: 1.2, heading: 0.3) }
        let t0 = PerfProbe.processCPUSeconds()
        for _ in 0..<20 { _ = Metaball.contour(ring: ring, blobs: blobs) }
        let ms = (PerfProbe.processCPUSeconds() - t0) * 1000 / 20
        #expect(ms < 150, "contour took \(ms) ms (debug build; release is ~40x faster)")
    }
}

@Suite struct RenderDiffTests {
    @MainActor @Test func idleRedrawsRarely() {
        let stage = SlimeStage(seed: 3)
        stage.simulate(3)
        var redraws = 0
        var last = stage.frames()
        for _ in 0..<150 {
            stage.simulate(1.0 / 30.0)
            let now = stage.frames()
            if PlacedSlime.visuallyDiffer(now, last, pixelsPerUnit: 15) { redraws += 1; last = now }
        }
        // Five seconds of breathing at notch size: blinks and micro-idle redraw, breathing mostly does not.
        #expect(redraws < 45, "\(redraws) redraws in 150 frames")
    }

    @MainActor @Test func sameFrameDoesNotDiffer() {
        let stage = SlimeStage(seed: 3)
        stage.simulate(1)
        let a = stage.frames()
        #expect(!PlacedSlime.visuallyDiffer(a, stage.frames(), pixelsPerUnit: 30))
    }

    @MainActor @Test func blinkRedraws() {
        let engine = SlimeEngine(profile: .main, seed: 5)
        engine.simulate(1)
        let before = engine.frame()
        var differs = false
        for _ in 0..<240 {
            engine.simulate(1.0 / 60.0)
            if engine.frame().visuallyDiffers(from: before, pixelsPerUnit: 15) { differs = true; break }
        }
        #expect(differs)
    }
}
