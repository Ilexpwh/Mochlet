import Testing
import Foundation
import CoreGraphics
import simd
@testable import SlimeKit
@testable import SlimeKitUI

@MainActor
@Suite struct ExpressionTests {
    @Test func everyEmoteRunsAndEnds() {
        for face in FaceStyle.allCases {
            for e in SlimeEmote.allCases {
                let eng = SlimeEngine(profile: .main, seed: 5)
                eng.appearance.faceStyle = face
                eng.simulate(0.5)
                eng.trigger(e)
                #expect(eng.emote == e, "\(e) starts")
                var t = 0.0
                while t < e.duration + 0.7 {
                    eng.simulate(1.0 / 60.0)
                    t += 1.0 / 60.0
                    let f = eng.frame()
                    #expect(f.eyes.count == 2)
                    if face == .anime { #expect(f.eyes.allSatisfy { !$0.shape.isBall }, "\(e): no ball eyes on the anime face") }
                    #expect(f.ring.allSatisfy { $0.x.isFinite && $0.y.isFinite }, "\(e): finite ring")
                    #expect(f.blobs.allSatisfy { $0.radius.isFinite && $0.position.x.isFinite && $0.position.y.isFinite }, "\(e): finite blobs")
                }
                #expect(eng.emote == nil, "\(e) ends after its duration")
                // Morph bulges, stalks and arms are all gone again once the emote has released.
                #expect(eng.frame().blobs.allSatisfy { $0.radius < 1e-3 }, "\(e): no blobs left")
            }
        }
    }

    @Test func grownGlyphPopsAboveTheHead() {
        let e = SlimeEngine(profile: .main, seed: 2)
        e.detail = .full
        e.appearance.glyphStyle = .grown
        e.simulate(0.3)
        e.startQuestion()
        e.simulate(0.5)
        let f = e.frame()
        let q = f.accessories.first { $0.kind == .question }
        #expect(q?.grown == true)
        // No stalk and no trail of bubbles: the mark is the only thing added.
        #expect(f.blobs.filter { $0.radius > 1e-3 && !$0.shaded }.isEmpty)
        #expect((q?.anchor.y ?? 0) < f.topY, "the glyph stands above the head")
        let gap = f.ring.map { simd_distance($0, q?.anchor ?? .zero) }.min() ?? 9
        #expect(gap > 0.4 && gap < 1.1, "the glyph floats just above the head, gap \(gap) R")
        #expect(q?.pop ?? 0 > 0.95, "fully popped after half a second")
        // One bead sits on the head under the mark, like the anime's "!".
        #expect(q?.bead != nil && (q?.beadRadius ?? 0) > 0.05)
        if let b = q?.bead { #expect((f.ring.map { simd_distance($0, b) }.min() ?? 9) < 0.2, "the bead touches the head") }
    }

    @Test func bubbleGlyphsBelowMediumDetail() {
        let e = SlimeEngine(profile: .main, seed: 2)
        e.detail = .tiny
        e.simulate(0.3)
        e.startQuestion()
        e.simulate(0.5)
        let f = e.frame()
        #expect(f.accessories.first { $0.kind == .question }?.grown == false)
        #expect(f.blobs.allSatisfy { $0.radius < 1e-3 })
    }

    @Test func singleClickPokes() {
        let e = SlimeEngine(profile: .main, seed: 3)
        e.simulate(0.2)
        e.clickGrammar.settleInterval = 0.3
        e.pressBegan(at: SIMD2(0.3, -1))
        e.pressEnded()
        e.simulate(0.4)
        #expect(e.emote == .poked)
        #expect(e.state == .idle)
    }

    @Test func errorShocksThenCries() {
        let e = SlimeEngine(profile: .main, seed: 4)
        e.simulate(0.3)
        e.agent(.error)
        #expect(e.emote == .shock)
        e.simulate(3)
        #expect(e.emote == nil)
        e.simulate(7.5)
        #expect(e.emote == .cry)
        #expect(e.state == .error)
        e.agent(.idle)
        e.simulate(0.1)
        #expect(e.state == .idle)
    }

    @Test func wakeStretches() {
        let e = SlimeEngine(profile: .main, seed: 4)
        e.simulate(0.3)
        e.sleepNow()
        e.simulate(1.5)
        #expect(e.state == .sleeping)
        e.wake()
        e.simulate(0.3)
        #expect(e.emote == .stretch)
    }

    @Test func selfHugHasArmsAndNoProp() {
        let e = SlimeEngine(profile: .main, seed: 4)
        e.simulate(0.3)
        e.trigger(.hug)
        e.simulate(0.6)
        let f = e.frame()
        #expect(f.arms.count == 2)
        #expect(f.props.isEmpty)
        #expect(ArmPose.parse("hug:self") == .hug(nil))
        #expect(ArmPose.parse("hug") == .hug(.heart))
        #expect(ArmPose.hug(nil).name == "hug:self")
    }

    @Test func chewingHugsTheCatchBeforeBiting() {
        let e = SlimeEngine(profile: .main, seed: 6)
        e.simulate(0.3)
        e.drop(kind: .pdf)
        e.simulate(0.9)
        let f = e.frame()
        #expect(f.chewPhase == .catching)
        #expect(f.arms.count == 2 && f.props.count == 1)
        // The two hands cross in front while hugging.
        if f.arms.count == 2 {
            let l = f.arms[0], r = f.arms[1]
            #expect(l.hand.x > r.hand.x - 0.5, "hands overlap in a hug")
        }
        e.simulate(0.6)
        if case .biting = e.frame().chewPhase ?? .catching {} else { Issue.record("biting after the hug") }
    }

    @Test func everyFaceMarkAndParticleRenders() {
        let eng = SlimeEngine(profile: .main, seed: 1)
        eng.simulate(0.5)
        let base = eng.frame()
        let ctx = CGContext(data: nil, width: 256, height: 192, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for radius in [56.0, 18.0] {
            for face in FaceStyle.allCases {
                let appearance = SlimeAppearance(faceStyle: face)
                for s in EyeShape.allCases {
                    var f = base
                    f.eyes[0].shape = s
                    f.eyes[1].shape = s
                    f.eyes[1].openness = 0.4
                    SlimeCGRenderer.draw(f, appearance: appearance, in: ctx, origin: CGPoint(x: 110, y: 170), radius: radius)
                }
                for m in MouthShape.allCases {
                    var f = base
                    f.mouth.shape = m
                    f.mouth.open = 0.8
                    SlimeCGRenderer.draw(f, appearance: appearance, in: ctx, origin: CGPoint(x: 110, y: 170), radius: radius)
                }
            }
            for k in [AccessoryKind.question, .exclamation, .dots, .badge, .micBars, .recDot, .note, .anger, .sweat] {
                for grown in [false, true] {
                    var f = base
                    f.accessories = [AccessoryFrame(kind: k, anchor: SIMD2(1.1, -2.1), pop: 1, phase: 0.4, levels: [0.2, 0.5, 0.8, 0.4, 0.1],
                                                    grown: grown && k.canGrow, direction: SIMD2(0.55, -0.83))]
                    SlimeCGRenderer.draw(f, appearance: .rimuru, in: ctx, origin: CGPoint(x: 110, y: 170), radius: radius)
                }
            }
            for k in [Particle.Kind.sparkle, .heart, .star, .zzz, .drop, .dust, .wisp, .spark, .glint, .drip, .bubble, .crumb, .steam] {
                var f = base
                f.particles = [Particle(kind: k, position: SIMD2(0.5, -1.5), velocity: .zero, age: 0.3, life: 1, size: 0.2, spin: 1, seed: 0.3)]
                SlimeCGRenderer.draw(f, appearance: .rimuru, in: ctx, origin: CGPoint(x: 110, y: 170), radius: radius)
            }
        }
        #expect(ctx.makeImage() != nil)
    }
}
