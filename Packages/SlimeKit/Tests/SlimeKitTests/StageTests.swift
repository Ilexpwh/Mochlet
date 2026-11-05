import Testing
import simd
@testable import SlimeKit

@MainActor
@Suite struct ChoreographyTests {
    private func fullRestArea(_ e: SlimeEngine) -> Double {
        e.body.restArea / (e.body.sizeScale * e.body.sizeScale)
    }

    @Test func splitMergesBeforeDeadline() {
        let s = SlimeStage(seed: 3)
        s.simulate(0.5)
        s.split(extra: 0)
        #expect(s.droplets.count == 3)
        #expect(s.isSplitting)
        #expect(s.main.state == .split)
        s.simulate(0.3)
        #expect(!s.main.blobs.isEmpty)
        s.simulate(1.65)
        #expect(!s.isSplitting)
        #expect(s.main.blobs.isEmpty)
        #expect(s.main.state == .dizzy)
        #expect(s.frameInterval == nil || s.main.state == .dizzy)
    }

    @Test func splitConservesArea() {
        let s = SlimeStage(seed: 5)
        s.simulate(0.5)
        let full = fullRestArea(s.main)
        s.split(extra: 1)
        s.simulate(0.5)
        let dropletArea = s.droplets.reduce(0.0) { $0 + Double.pi * $1.radius * $1.radius }
        let total = s.main.body.area + dropletArea
        #expect(abs(total / full - 1) < 0.06, "total area ratio \(total / full)")
        #expect(s.droplets.allSatisfy { $0.position.y <= -$0.radius + 1e-6 })
    }

    @Test func extraClicksAddDroplets() {
        let a = SlimeStage(seed: 1)
        a.simulate(0.2)
        a.split(extra: 2)
        #expect(a.droplets.count == 5)
        let b = SlimeStage(seed: 1)
        b.simulate(0.2)
        b.split(extra: 10)
        #expect(b.droplets.count == 6)
    }

    @Test func pinchOffProducesLiveMini() {
        let s = SlimeStage(seed: 2)
        s.simulate(0.3)
        let m = s.spawnMini(id: "a")
        #expect(m != nil)
        #expect(s.spawnMini(id: "a") == nil)
        s.simulate(0.3)
        #expect(m?.phase == .pinching)
        #expect(!s.main.blobs.isEmpty)
        s.simulate(0.3)
        #expect(m?.phase == .flying)
        #expect(s.main.blobs.isEmpty)
        let cues = s.drainCues().map(\.sound)
        #expect(cues.contains(.pinch))
        s.simulate(1.2)
        #expect(m?.phase == .live)
        #expect(m?.engine.faceOpacity ?? 0 > 0.99)
        let expectedX = SlimeStage.firstSlot / SlimeStage.miniScale
        #expect(abs((m?.engine.body.root.x ?? 0) - expectedX) < 0.35)
        #expect(s.frames().count == 2)
        #expect(s.main.body.sizeScale < 0.99)
    }

    @Test func mergeBackAbsorbs() {
        let s = SlimeStage(seed: 4)
        s.simulate(0.3)
        s.spawnMini(id: "a")
        s.simulate(2.0)
        _ = s.drainCues()
        s.removeMini("a")
        #expect(s.mini("a")?.phase == .merging)
        s.simulate(1.6)
        #expect(s.minis.isEmpty)
        #expect(s.main.blobs.isEmpty)
        let cues = s.drainCues().map(\.sound)
        #expect(cues.contains(.absorb))
        s.simulate(0.5)
        #expect(abs(s.main.body.sizeScale - 1) < 0.01)
    }

    @Test func slotsRepackAfterRemoval() {
        let s = SlimeStage(seed: 6)
        s.simulate(0.3)
        s.spawnMini(id: "a")
        s.simulate(1.0)
        s.spawnMini(id: "b")
        s.simulate(1.0)
        s.spawnMini(id: "c")
        s.simulate(2.0)
        #expect(s.mini("c")?.slot == 2)
        s.removeMini("b")
        s.simulate(2.0)
        #expect(s.mini("c")?.slot == 1)
        let expectedX = (SlimeStage.firstSlot + SlimeStage.slotPitch) / SlimeStage.miniScale
        #expect(abs((s.mini("c")?.engine.body.root.x ?? 0) - expectedX) < 0.4)
        #expect(s.minis.count == 2)
    }

    @Test func ghostSpringsBackWhenCancelled() {
        let s = SlimeStage(seed: 7)
        s.simulate(0.3)
        s.beginDragOut(at: SIMD2(4, -3))
        s.simulate(0.7)
        #expect(s.ghost != nil)
        #expect(s.main.isAway)
        #expect(simd_distance(s.ghost!.body.root, SIMD2(4, -3)) < 0.6)
        s.endDragOut(dropped: false)
        s.simulate(1.2)
        #expect(s.ghost == nil)
        #expect(!s.main.isAway)
    }

    @Test func ghostDroppedMakesMainHappy() {
        let s = SlimeStage(seed: 8)
        s.simulate(0.3)
        s.beginDragOut(at: SIMD2(6, -2))
        s.simulate(0.8)
        s.endDragOut(dropped: true)
        #expect(s.ghost == nil)
        #expect(s.main.emote == .happy)
        #expect(!s.main.isAway)
    }

    @Test func reduceMotionSkipsChoreography() {
        let s = SlimeStage(seed: 9, reduceMotion: true)
        s.simulate(0.2)
        let m = s.spawnMini(id: "a")
        #expect(m?.phase == .live)
        #expect(s.main.blobs.isEmpty)
        s.split(extra: 0)
        #expect(!s.isSplitting)
        #expect(s.main.state == .dizzy)
    }

    @Test func pointerForwardsToMinis() {
        let s = SlimeStage(seed: 10)
        s.simulate(0.2)
        s.spawnMini(id: "a")
        s.simulate(2.0)
        let x = SlimeStage.firstSlot
        s.pointer(SIMD2(x, -0.4))
        #expect(s.hitTest(SIMD2(x, -0.4)) == .mini("a"))
        #expect(s.hitTest(SIMD2(0, -0.9)) == .main)
        #expect(s.hitTest(SIMD2(-5, -0.9)) == .none)
    }

    @Test func determinism() {
        func run() -> [SIMD2<Double>] {
            let s = SlimeStage(seed: 11)
            s.simulate(0.3)
            s.split(extra: 1)
            s.simulate(0.7)
            return s.droplets.map(\.position)
        }
        #expect(run() == run())
    }
}
