import Testing
import Foundation
import simd
@testable import SlimeKit

@MainActor
@Suite struct ArmTests {
    static let poses: [ArmPose] = [
        .holdFront(.file(kind: .pdf, bites: 0)), .holdHigh(.bell), .holdSide(.phone, side: -1), .holdSide(.mic, side: 1),
        .hug(.heart), .wave(side: 1), .thumbsUp(side: 1), .cheer, .rubEyes, .scratchHead, .facepalm, .cover,
        .point(SIMD2(1, -0.4)), .sip, .hidden,
    ]

    func settled(_ e: SlimeEngine) { e.simulate(1.5) }

    @Test func idleHasNoArmsAndNoBlobs() {
        let e = SlimeEngine(profile: .main, seed: 2)
        e.simulate(2)
        let f = e.frame()
        #expect(f.arms.isEmpty && f.props.isEmpty && f.innerItems.isEmpty && f.chewPhase == nil)
        #expect(f.blobs.allSatisfy { $0.radius < 1e-3 })
    }

    @Test func everyPoseStaysWithinReach() {
        for p in Self.poses {
            for side in [-1.0, 1.0] {
                let k = ArmRig.keyframe(p, side: side)
                #expect(simd_length(k.hand) <= 1.6, "\(p.name) hand within 1.6 R (\(simd_length(k.hand)))")
                #expect(simd_length(k.elbow) <= 1.6, "\(p.name) elbow within 1.6 R")
            }
        }
    }

    @Test func poseSwitchesNeverSnap() {
        let e = SlimeEngine(profile: .main, seed: 3)
        e.simulate(0.5)
        var prev: [SIMD2<Double>]?
        var worst = 0.0
        var frames = 0
        for (i, p) in Self.poses.enumerated() {
            e.gesture(p, for: 10)
            for _ in 0..<(i % 3 == 0 ? 4 : 18) {   // sometimes switch mid-move
                e.simulate(1.0 / 60.0)
                let f = e.frame()
                let joints = f.arms.flatMap { [$0.shoulder, $0.elbow, $0.hand] }
                if let prev, prev.count == joints.count {
                    for (a, b) in zip(prev, joints) { worst = max(worst, simd_distance(a, b)) }
                }
                prev = joints
                frames += 1
            }
        }
        #expect(frames > 100)
        #expect(worst <= 0.3, "no joint moves more than 0.3 R between frames (\(worst))")
    }

    @Test func propsFollowTheHands() {
        let e = SlimeEngine(profile: .main, seed: 4)
        e.simulate(0.5)
        e.gesture(.holdSide(.phone, side: -1), for: 10)
        settled(e)
        var f = e.frame()
        #expect(f.props.count == 1 && f.props[0].prop == .phone)
        let left = f.arms.first { $0.side < 0 }
        #expect(left != nil && f.arms.count == 1, "one arm for a one-handed prop")
        if let left { #expect(simd_distance(f.props[0].position, left.hand) < 0.45) }
        e.gesture(.holdFront(.book), for: 10)
        settled(e)
        f = e.frame()
        #expect(f.arms.count == 2 && f.props.count == 1)
        let mid = (f.arms[0].hand + f.arms[1].hand) * 0.5
        #expect(simd_distance(f.props[0].position, mid) < 0.3)
        #expect(f.props[0].behindHands)
        // A hop: the prop lags, then settles back exactly on the hands.
        let rest = f.props[0].position - mid
        e.impulse(.jump(v0: 2.4))
        var lag = 0.0
        for _ in 0..<120 {
            e.simulate(1.0 / 60.0)
            let g = e.frame()
            if let p = g.props.first {
                let m = (g.arms[0].hand + g.arms[1].hand) * 0.5
                lag = max(lag, simd_distance(p.position - m, rest))
            }
        }
        #expect(lag > 0.05, "the prop wobbles after a jump (\(lag))")
        settled(e)
        f = e.frame()
        let m2 = (f.arms[0].hand + f.arms[1].hand) * 0.5
        #expect(simd_distance(f.props[0].position - m2, rest) < 0.02, "and settles back on the hands")
    }

    @Test func chewingTimelineCatchesBitesDigestsAndGulps() {
        let e = SlimeEngine(profile: .main, seed: 5)
        e.simulate(0.5)
        e.drop(kind: .pdf)
        e.simulate(0.05)
        var f = e.frame()
        #expect(f.chewPhase == .catching)
        #expect(f.arms.count == 2 && f.props.first?.prop == .file(kind: .pdf, bites: 0))
        if let p = f.props.first, let a = f.arms.first { #expect(p.position.y < a.hand.y, "the file starts above the hands") }
        var lastBites = 0.0
        var sawBiting = false
        var sawDigesting = false
        var sawPages = false
        var maxArmsWhileDigesting = 0
        var digestAt = 0.0
        for _ in 0..<(60 * 4) {
            e.simulate(1.0 / 60.0)
            f = e.frame()
            switch f.chewPhase {
            case .biting(let b):
                sawBiting = true
                #expect(b >= lastBites - 1e-9, "bites are monotonic")
                lastBites = b
                if let p = f.props.first, case .file(_, let pb) = p.prop { #expect(abs(pb - b) < 1e-9) }
            case .digesting:
                if !sawDigesting { digestAt = e.time }
                sawDigesting = true
                if !f.innerItems.isEmpty { sawPages = true }
                if e.time - digestAt > 0.6 { maxArmsWhileDigesting = max(maxArmsWhileDigesting, f.arms.filter { $0.reach > 0.5 }.count) }
            default:
                break
            }
        }
        #expect(sawBiting && sawDigesting && sawPages)
        #expect(lastBites >= 0.45 - 1e-9 && e.bites >= 0.6)
        #expect(maxArmsWhileDigesting == 0, "arms retract while digesting")
        #expect(e.state == .chewing, "keeps digesting until the host finishes")
        let t0 = e.time
        e.ingestionFinished(success: true)
        var filed = false
        while e.state == .chewing && e.time - t0 < 3 {
            e.simulate(1.0 / 60.0)
            if e.frame().chewPhase == .filing { filed = true }
        }
        #expect(filed)
        #expect(e.state != .chewing)
        e.simulate(2)
        f = e.frame()
        #expect(f.chewPhase == nil && f.innerItems.isEmpty && f.props.isEmpty)
    }

    @Test func quickIngestStillEatsForTwoSeconds() {
        let e = SlimeEngine(profile: .main, seed: 6)
        e.simulate(0.3)
        e.drop(kind: .doc)
        e.simulate(0.1)
        e.ingestionFinished(success: true)
        let t0 = e.time
        var sawBite = false
        while e.state == .chewing && e.time - t0 < 6 {
            e.simulate(1.0 / 60.0)
            if case .biting(let b) = e.frame().chewPhase, b > 0 { sawBite = true }
        }
        #expect(sawBite, "a quick ingest still shows bites")
        #expect(e.time - t0 >= 2.0 && e.time - t0 < 5.5)
    }

    @Test func hostProgressHoldsTheBites() {
        let e = SlimeEngine(profile: .main, seed: 7)
        e.simulate(0.3)
        e.drop(kind: .image)
        e.simulate(0.8)
        e.setChewPhase(.biting(0.2))
        e.simulate(3)
        guard case .biting(let b) = e.frame().chewPhase else { Issue.record("still biting while the host reads"); return }
        #expect(b <= 0.6 * 0.2 + 0.12 + 1e-9 && b > 0)
        e.setChewPhase(.biting(1))
        e.simulate(3)
        #expect(e.frame().chewPhase == .digesting)
        e.setChewPhase(.filing)
        e.simulate(0.1)
        #expect(e.frame().chewPhase == .filing)
    }

    @Test func armsOffMeansNoArmsEvenWhileEating() {
        let e = SlimeEngine(profile: .main, seed: 8)
        e.appearance.armsEnabled = false
        e.simulate(0.3)
        e.drop(kind: .pdf)
        e.simulate(1.2)
        let f = e.frame()
        #expect(f.arms.isEmpty && f.props.isEmpty && f.chewPhase == nil && e.state == .chewing)
        e.gesture(.wave(side: 1), for: 5)
        e.simulate(0.5)
        #expect(e.frame().arms.isEmpty)
    }

    @Test func tinyDetailKeepsOnlyTheChewingArms() {
        let e = SlimeEngine(profile: .main, seed: 9)
        e.detail = .tiny
        e.simulate(0.3)
        e.gesture(.wave(side: 1), for: 5)
        e.simulate(0.6)
        #expect(e.frame().arms.isEmpty, "gestures need R ≥ 24 px")
        e.drop(kind: .text)
        e.simulate(1.0)
        #expect(e.frame().arms.count == 2 && e.frame().props.count == 1, "chewing arms at every size")
    }

    @Test func statesAndOccasionsHoldProps() {
        let e = SlimeEngine(profile: .main, seed: 10)
        e.simulate(0.3)
        e.startListening()
        settled(e)
        var f = e.frame()
        #expect(f.props.first?.prop == .mic)
        #expect(!f.accessories.contains { $0.kind == .micBars }, "mic in hand replaces the bars")
        e.detail = .medium
        settled(e)
        f = e.frame()
        #expect(f.props.isEmpty && f.accessories.contains { $0.kind == .micBars }, "bars below R 36")
        e.detail = .full
        e.stopListening(hadSpeech: false)
        e.setRecording(true)
        settled(e)
        #expect(e.frame().props.first?.prop == .phone)
        e.setRecording(false)
        e.occasion = .rest
        settled(e)
        #expect(e.frame().props.first?.prop == .mug)
        e.occasion = .working
        settled(e)
        #expect(e.frame().props.first?.prop == .pen)
        e.occasion = nil
        settled(e)
        #expect(e.frame().arms.isEmpty)
    }

    @Test func minisNeverGrowArms() {
        let e = SlimeEngine(profile: .mini, seed: 11)
        e.simulate(0.3)
        e.gesture(.cheer, for: 5)
        e.simulate(0.5)
        #expect(e.frame().arms.isEmpty)
    }

    @Test func posesParseAndPrint() {
        for p in Self.poses {
            let back = ArmPose.parse(p.name)
            #expect(back == p, "\(p.name) round-trips (\(String(describing: back)))")
        }
        #expect(ArmPose.parse("holdSide:mic:1") == .holdSide(.mic, side: 1))
        #expect(Prop.named("pdf") == .file(kind: .pdf, bites: 0))
        #expect(ChewPhase.parse("biting:0.5") == .biting(0.5))
    }
}
