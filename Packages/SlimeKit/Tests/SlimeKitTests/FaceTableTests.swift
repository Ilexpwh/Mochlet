import Testing
import simd
@testable import SlimeKit

@Suite struct FaceTableTests {
    @Test func animeTablesNeverUseBalls() {
        for s in SlimeState.allCases {
            let p = FaceTable.state(s, .anime)
            #expect(!p.left.isBall && !p.right.isBall, "\(s) anime eyes are strokes")
        }
        for e in SlimeEmote.allCases {
            let p = FaceTable.emote(e, .anime)
            #expect(!p.left.isBall && !p.right.isBall, "\(e) anime eyes are strokes")
        }
        for shape in EyeShape.allCases {
            #expect(!shape.strokeEquivalent.isBall, "\(shape) has a stroke stand-in")
            if !shape.isBall { #expect(shape.strokeEquivalent == shape, "\(shape) keeps itself") }
        }
    }

    @Test func roundColumnIsTheEarlierFace() {
        #expect(FaceTable.state(.idle, .round) == FacePose(.open, .smileTiny))
        #expect(FaceTable.state(.error, .round) == FacePose(.flat, .flat))
        #expect(FaceTable.state(.sleeping, .round) == FacePose(.tired, .sleepy))
        #expect(FaceTable.emote(.happy, .round) == FacePose(.happyArc, .omega))
        #expect(FaceTable.emote(.shy, .round).mouth == nil, "shy keeps the state's mouth")
        #expect(FaceTable.emote(.wink, .round) == FacePose(left: .happyArc, right: .open, mouth: .smileTiny))
        // The anime idle face has no mouth; a mouth appears only when the moment needs one.
        #expect(FaceTable.state(.idle, .anime) == FacePose(.content, MouthShape.none))
        #expect(FaceTable.emote(.annoyed, .anime).mouth == .caret)
    }

    @MainActor @Test func animeEngineNeverShowsABall() {
        let e = SlimeEngine(profile: .main, seed: 11)
        #expect(e.appearance.faceStyle == .anime)
        func scan(_ seconds: Double, _ label: String) {
            var t = 0.0
            while t < seconds {
                e.simulate(1.0 / 30.0)
                t += 1.0 / 30.0
                let f = e.frame()
                #expect(f.eyes.allSatisfy { !$0.shape.isBall }, "\(label): \(f.eyes.map(\.shape))")
            }
        }
        scan(0.5, "idle")
        e.dragEntered(fromDirection: 1)
        scan(0.4, "drag in")
        e.drop(kind: .pdf)
        scan(3.0, "chewing")
        e.ingestionFinished(success: true)
        scan(1.0, "finished")
        for s in AgentState.allCases {
            e.agent(s)
            scan(0.6, "agent \(s)")
        }
        e.agent(.idle)
        e.setEyeOverride(.wide, for: 0.3)
        scan(0.4, "stage override")
        e.sleepNow()
        scan(1.5, "sleeping")
        e.wake()
        scan(1.5, "waking")
        // Idle for a long while: micro-idle half-lids and glances included.
        scan(40, "long idle")
        let f = e.frame()
        #expect(f.blushCenters.count == 2 && f.blush > 0.5, "the anime face always wears its blush")
        #expect(f.mouth.shape == .none, "no resting mouth on the anime face")
    }

    @MainActor @Test func roundStyleKeepsTheEarlierFace() {
        let e = SlimeEngine(profile: .main, seed: 11)
        e.appearance.faceStyle = .round
        e.simulate(1)
        let f = e.frame()
        #expect(f.eyes.map(\.shape) == [.open, .open])
        #expect(f.mouth.shape == .smileTiny)
        #expect(abs(f.blush - 0.35) < 1e-6)
        #expect(e.gaze.yawGain > 0.5)
        e.appearance.faceStyle = .anime
        e.simulate(0.5)
        let g = e.frame()
        #expect(g.eyes.map(\.shape) == [.content, .content] && g.mouth.shape == .none)
        #expect(abs(g.blush - 0.70) < 1e-6)
    }

    @MainActor @Test func animeMinisBlush() {
        let m = SlimeEngine(profile: .mini, seed: 3)
        m.simulate(0.5)
        let f = m.frame()
        #expect(f.blushCenters.count == 2)
        #expect(abs(f.blush - 0.60) < 1e-6)
        let r = SlimeEngine(profile: .mini, seed: 3)
        r.appearance.faceStyle = .round
        r.simulate(0.5)
        #expect(r.frame().blushCenters.isEmpty)
    }
}
