import Testing
import Foundation
import simd
@testable import SlimeKit

@Suite struct LookTests {
    static let silhouettes: [SlimeLook.Silhouette] = [.dome, .drop, .puddle, .loaf, .spiky, .tall]
    static let feels: [SlimeLook.Feel] = [.jelly, .firm, .runny, .airy, .bouncy]

    @Test func domeRingIsTheBun() {
        let profile = RestProfile.forSilhouette(.dome)
        #expect(profile == RestProfile.dome)
        let ring = profile.ring(count: 24)
        #expect(ring.count == 24)
        #expect(abs(ring[0].x) < 1e-9 && abs(ring[0].y - (-1.72)) < 1e-6, "the rest top is at −1.72")
        let maxX = ring.map(\.x).max()!
        #expect(maxX > 1.10 && maxX < 1.20, "rest half-width \(maxX)")
        #expect(ring[12].y > 0, "the rest bottom sits under the floor")
    }

    @Test func domeCenterMatchesParams() {
        #expect(abs(SoftBodyParams.main.restCenterY - RestProfile.dome.centerY) < 1e-12)
        #expect(abs(SoftBodyParams.mini.restCenterY - RestProfile.dome.centerY) < 1e-12)
    }

    /// The settled default body reads as the anime bun: wide and low with a flat base, its widest
    /// point below mid-height (the skirt), about 1.38 times as wide as it is tall.
    @Test func bunProportions() {
        for params in [SoftBodyParams.main, SoftBodyParams.main.applying(look: .rimuru, mini: false), SoftBodyParams.mini] {
            let body = SoftBody(params: params)
            let ring = body.referenceRing
            let width = ring.map(\.x).max()! - ring.map(\.x).min()!
            let top = -ring.map(\.y).min()!
            let ratio = width / top
            let widest = ring.max { abs($0.x) < abs($1.x) }!
            #expect(ratio > 1.30 && ratio < 1.45, "width \(width) / height \(top) = \(ratio)")
            // The contact chord is quantised by the ring (5 of 24 points sit on the floor, 3 of 16).
            let minContact = params.pointCount < 20 ? 0.8 : 1.1
            #expect(body.contactWidth > minContact && body.contactWidth < 1.8, "contact \(body.contactWidth)")
            #expect(widest.y > -0.70, "widest point low on the body (y \(widest.y))")
            #expect(top > 1.58 && top < 1.82, "top \(top)")
        }
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
            for (name, base) in [("round", EyeRig.main), ("anime", EyeRig.anime)] {
                let rig = base.fitted(to: profile)
                for side in [-1.0, 1.0] {
                    let p = rig.local(rig.eye(side: side, yaw: 0, pitch: 0))
                    let d = Metaball.polygonDistance(p, body.referenceRing)
                    #expect(d < -0.12, "\(s) \(name) eye \(side) inside the body (distance \(d))")
                    let edge = p + SIMD2(side * rig.eyeRadius, 0)
                    #expect(Metaball.polygonDistance(edge, body.referenceRing) < 0, "\(s) \(name) eye edge inside")
                }
                let m = rig.local(rig.project(yawOffset: 0, pitchOffset: rig.mouthPitch, yaw: 0, pitch: 0))
                #expect(Metaball.polygonDistance(m, body.referenceRing) < -0.08, "\(s) \(name) mouth inside")
                for side in [-1.0, 1.0] {
                    let b = rig.local(rig.project(yawOffset: side * rig.blushYaw, pitchOffset: rig.blushPitch, yaw: 0, pitch: 0))
                    #expect(Metaball.polygonDistance(b, body.referenceRing) < -0.06, "\(s) \(name) blush \(side) inside")
                }
            }
        }
        #expect(EyeRig.main.fitted(to: .dome) == EyeRig.main)
        #expect(EyeRig.anime.fitted(to: .dome) == EyeRig.anime)
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
        let tipRing = SoftBody(params: .main).points
        let tip = TraitRig.build(look: .rimuru, ring: tipRing, anim: TraitAnim(), time: 0, detail: .full, mini: false)
        let crown = tipRing.map(\.y).min()!
        #expect(tip.blobs.count == 2 && tip.blobs[0].position.x > 0.5 && tip.blobs[0].position.y < crown + 0.25, "the tip curls up from the top-right")
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
        let bunWidth = before.ring.map(\.x).max()! - before.ring.map(\.x).min()!
        #expect(f.ring.map(\.x).max()! - f.ring.map(\.x).min()! > bunWidth + 0.1, "loaf is wider than the bun")
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
