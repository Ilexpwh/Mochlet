import Testing
import Foundation
import simd
@testable import SlimeKit

@Suite struct LookTests {
    static let silhouettes: [SlimeLook.Silhouette] = [.dome, .drop, .puddle, .loaf, .spiky, .tall]
    static let feels: [SlimeLook.Feel] = [.jelly, .firm, .runny, .airy, .bouncy]

    @Test func domeRingIsUnchanged() {
        let ring = RestProfile.forSilhouette(.dome).ring(count: 24)
        #expect(ring.count == 24)
        #expect(abs(ring[0].x) < 1e-12 && abs(ring[0].y - (-1.86)) < 1e-12)
        #expect(abs(ring[6].x - 1) < 1e-12 && abs(ring[6].y - (-0.86)) < 1e-12)
    }

    @Test func everySilhouetteSettlesAndKeepsItsArea() {
        for s in Self.silhouettes {
            for feel in Self.feels {
                let params = SoftBodyParams.main.applying(look: SlimeLook(name: "t", silhouette: s, feel: feel), mini: false)
                #expect(params.isStable, "\(s) \(feel) stable")
                var body = SoftBody(params: params)
                #expect(body.points.allSatisfy { $0.y <= 1e-6 && $0.x.isFinite && $0.y.isFinite }, "\(s) \(feel) rests on the floor")
                #expect(body.topY < -1.1, "\(s) \(feel) stands up: top \(body.topY)")
                #expect(abs(body.areaRatio - 1) < 0.08, "\(s) \(feel) area \(body.areaRatio)")
                #expect(body.contactWidth > 0.3, "\(s) \(feel) contact \(body.contactWidth)")
                body.apply(.landing(speed: 4))
                for _ in 0..<Int(1.6 / SoftBodyParams.substep) { _ = body.step(h: SoftBodyParams.substep) }
                var worst = 0.0
                for (i, p) in body.points.enumerated() { worst = max(worst, simd_distance(p, body.referenceRing[i])) }
                #expect(worst < 0.05, "\(s) \(feel) settles again: \(worst)")
            }
        }
    }

    @Test func faceFitsEverySilhouette() {
        for s in Self.silhouettes {
            let profile = RestProfile.forSilhouette(s)
            let body = SoftBody(params: SoftBodyParams.main.applying(look: SlimeLook(name: "t", silhouette: s), mini: false))
            let rig = EyeRig.main.fitted(to: profile)
            for side in [-1.0, 1.0] {
                let p = rig.local(rig.eye(side: side, yaw: 0, pitch: 0))
                let d = Metaball.polygonDistance(p, body.referenceRing)
                #expect(d < -0.12, "\(s) eye \(side) inside the body (distance \(d))")
                let edge = p + SIMD2(side * rig.eyeRadius, 0)
                #expect(Metaball.polygonDistance(edge, body.referenceRing) < 0, "\(s) eye edge inside")
            }
            let m = rig.local(rig.project(yawOffset: 0, pitchOffset: rig.mouthPitch, yaw: 0, pitch: 0))
            #expect(Metaball.polygonDistance(m, body.referenceRing) < -0.08, "\(s) mouth inside")
        }
        #expect(EyeRig.main.fitted(to: .dome) == EyeRig.main)
    }

    @Test func traitsRideTheRing() {
        for look in SlimeLook.all {
            let body = SoftBody(params: SoftBodyParams.main.applying(look: look, mini: false))
            let ring = body.points
            let out = TraitRig.build(look: look, ring: ring, anim: TraitAnim(), time: 0.3, detail: .full, mini: false)
            for b in out.blobs {
                let near = ring.map { simd_distance($0, b.position) }.min() ?? 10
                #expect(near < 1.3, "\(look.name) blob attached (nearest ring point \(near))")
                #expect(b.radius > 0.03 && b.radius < 0.3)
            }
            for t in out.traits {
                #expect(abs(simd_length(t.direction) - 1) < 1e-6, "\(look.name) unit direction")
                #expect(t.anchor.x.isFinite && t.anchor.y.isFinite)
            }
            if look.tail == .cat || look.tail == .fox || look.tail == .dragon {
                let tail = out.blobs.suffix(TraitRig.tailLinks(look.tail))
                var prev: SIMD2<Double>?
                for b in tail {
                    if let p = prev { #expect(simd_distance(p, b.position) < 0.36, "\(look.name) tail chain contiguous") }
                    #expect(b.position.y <= 0.02, "\(look.name) tail stays above the floor")
                    prev = b.position
                }
            }
            if look.wings != .none { #expect(out.traits.filter { if case .wing = $0.kind { return true } else { return false } }.count == 2) }
            if look.horns == .demonPair || look.horns == .dragonPair { #expect(out.traits.filter { if case .horn = $0.kind { return true } else { return false } }.count == 2) }
            let mini = TraitRig.build(look: look.mini, ring: ring, anim: TraitAnim(), time: 0, detail: .medium, mini: true)
            #expect(!mini.traits.contains { if case .wing = $0.kind { return true } else { return false } })
        }
        #expect(TraitRig.build(look: .plain, ring: SoftBody(params: .main).points, anim: TraitAnim(), time: 0, detail: .full, mini: false) == TraitRig.Output())
        let tip = TraitRig.build(look: .rimuru, ring: SoftBody(params: .main).points, anim: TraitAnim(), time: 0, detail: .full, mini: false)
        #expect(tip.blobs.count == 2 && tip.blobs[0].position.x > 0.5 && tip.blobs[0].position.y < -1.6, "the tip curls up from the top-right")
    }

    @Test func ringIndexMapsAngles() {
        #expect(TraitRig.index(angle: -.pi / 2, count: 24) == 0)
        #expect(TraitRig.index(angle: 0, count: 24) == 6)
        #expect(TraitRig.index(angle: .pi / 2, count: 24) == 12)
        #expect(TraitRig.index(angle: -.pi / 2 - 0.2, count: 24) == 23)
    }

    @MainActor @Test func engineReshapesForANewLook() {
        let e = SlimeEngine(profile: .main, seed: 2)
        e.simulate(0.5)
        let before = e.frame()
        #expect(before.traits.isEmpty && before.blobs.isEmpty)
        e.appearance = SlimeAppearance(look: .cat)
        #expect(e.body.params.silhouette == .loaf)
        e.simulate(1)
        let f = e.frame()
        #expect(f.blobs.count == 2 + TraitRig.tailLinks(.cat), "cat ears and tail are goo")
        #expect(f.traits.filter { if case .earInner = $0.kind { return true } else { return false } }.count == 2, "inner ears at full detail")
        #expect(f.traits.contains { $0.kind == .gloss }, "goo features carry a gloss at full detail")
        #expect(f.ring.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        #expect(f.ring.map(\.x).max()! - f.ring.map(\.x).min()! > 2.0, "loaf is wider than the dome")
        e.appearance = SlimeAppearance(look: .tempest)
        e.simulate(1)
        let t = e.frame()
        #expect(t.traits.contains { if case .wing = $0.kind { return true } else { return false } })
        #expect(t.blobs.count == TraitRig.tailLinks(.dragon), "dragon tail chain")
        e.appearance = SlimeAppearance(look: .flame)
        e.detail = .full
        e.simulate(3)
        #expect(e.frame().blobs.count == 3, "flame tongues")
        #expect(e.frame().particles.contains { $0.kind == .wisp }, "fire wisps at full detail")
        e.detail = .tiny
        e.simulate(4)
        #expect(!e.frame().particles.contains { $0.kind == .wisp }, "no surface particles when tiny")
        e.appearance = .rimuru
        e.simulate(0.5)
        #expect(e.frame().blobs.isEmpty && e.frame().traits.isEmpty)
    }

    @MainActor @Test func idleFrameIntervalStaysQuietWithALook() {
        let e = SlimeEngine(profile: .main, seed: 2)
        e.appearance = SlimeAppearance(look: .cat)
        e.detail = .tiny
        e.simulate(8)
        #expect(e.frameInterval == 1.0 / 30.0)
    }

    @Test func detailLevels() {
        #expect(DetailLevel(pixelsPerUnit: 15) == .tiny)
        #expect(DetailLevel(pixelsPerUnit: 24) == .medium)
        #expect(DetailLevel(pixelsPerUnit: 56) == .full)
        #expect(DetailLevel.tiny < .full)
    }

    @Test func paramsDecodeWithoutASilhouette() throws {
        let data = Data(#"{"pointCount":20,"damping":9}"#.utf8)
        let p = try JSONDecoder().decode(SoftBodyParams.self, from: data)
        #expect(p.pointCount == 20 && p.damping == 9 && p.silhouette == .dome && p.pressure == 60)
    }
}
