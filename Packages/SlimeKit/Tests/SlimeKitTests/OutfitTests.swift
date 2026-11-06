import Testing
import Foundation
import simd
@testable import SlimeKit

@Suite struct OutfitTests {
    func ringTop(_ ring: [SIMD2<Double>]) -> SIMD2<Double> { ring[TraitRig.index(angle: -.pi / 2, count: ring.count)] }

    @Test func headwearSitsOnTheCrown() {
        let ring = SoftBody(params: .main).points
        let top = ringTop(ring)
        for h in SlimeOutfit.Headwear.allCases where h != .none {
            let traits = OutfitRig.build(outfit: SlimeOutfit(headwear: h), ring: ring, anim: TraitAnim(), detail: .full, mini: false)
            let hat = traits.first { if case .headwear = $0.kind { return true } else { return false } }
            #expect(hat != nil, "\(h) is placed")
            guard let hat else { continue }
            let d = simd_distance(hat.anchor, top)
            let sideMounted = h == .bow || h == .flower
            #expect(d < (h == .halo ? 0.6 : 0.75), "\(h) near the crown (\(d))")
            #expect(hat.anchor.y <= top.y + (sideMounted ? 0.6 : 0.1), "\(h) never sinks into the body")
            #expect(abs(simd_length(hat.direction) - 1) < 1e-6)
        }
    }

    @Test func everySetHasAllItsPiecesAtFullDetail() {
        let ring = SoftBody(params: .main).points
        for set in SlimeOutfit.sets where set.name != "none" {
            let traits = OutfitRig.build(outfit: set.outfit, ring: ring, anim: TraitAnim(), detail: .full, mini: false)
            if set.outfit.headwear != .none { #expect(traits.contains { if case .headwear = $0.kind { return true } else { return false } }, "\(set.name) headwear") }
            if set.outfit.wrap != .none { #expect(traits.contains { if case .wrapFront = $0.kind { return true } else { return false } }, "\(set.name) wrap") }
            if set.outfit.charm != .none { #expect(traits.contains { if case .charm = $0.kind { return true } else { return false } }, "\(set.name) charm") }
        }
    }

    @Test func tinyDetailKeepsHeadwearAndTheTowelOnly() {
        let ring = SoftBody(params: .main).points
        let king = OutfitRig.build(outfit: SlimeOutfit.set(named: "king")!, ring: ring, anim: TraitAnim(), detail: .tiny, mini: false)
        #expect(king.count == 1)
        if case .headwear(.crown) = king[0].kind {} else { Issue.record("crown expected") }
        let onsen = OutfitRig.build(outfit: SlimeOutfit.set(named: "onsen")!, ring: ring, anim: TraitAnim(), detail: .tiny, mini: false)
        #expect(onsen.count == 1)
        if case .wrapFront(.towel) = onsen[0].kind {} else { Issue.record("towel expected") }
        #expect(OutfitRig.build(outfit: SlimeOutfit(), ring: ring, anim: TraitAnim(), detail: .full, mini: false).isEmpty)
    }

    @MainActor @Test func hatRidesTheCrownThroughAGreeting() {
        let e = SlimeEngine(profile: .main, seed: 4)
        e.appearance = SlimeAppearance(look: .rimuru, outfit: SlimeOutfit.set(named: "king")!)
        e.simulate(0.5)
        e.greet()
        var worst = 0.0
        var moved = false
        var sawOffset = false
        for _ in 0..<180 {
            e.simulate(1.0 / 60.0)
            let f = e.frame()
            guard let hat = f.traits.first(where: { if case .headwear = $0.kind { return true } else { return false } }) else { Issue.record("no hat"); return }
            let top = ringTop(f.ring)
            worst = max(worst, simd_distance(hat.anchor, top))
            if simd_length(e.traitAnim.hat) > 0.01 { sawOffset = true }
            if f.airborne { moved = true }
        }
        #expect(moved, "the greeting hops")
        #expect(sawOffset, "the hat lags during the hop")
        #expect(worst <= 0.08 + 1e-6, "the hat stays within 0.08 R of the crown (\(worst))")
        e.simulate(3)
        #expect(simd_length(e.traitAnim.hat) < 1e-6, "the hat settles exactly so idle frames compare equal")
    }

    @MainActor @Test func situationalPiecesNeverPersist() {
        let e = SlimeEngine(profile: .main, seed: 4)
        e.appearance = SlimeAppearance(look: .rimuru)
        e.simulate(0.3)
        #expect(e.frame().outfit.isEmpty)
        e.drop()
        e.simulate(0.4)
        #expect(e.frame().outfit.eyewear == .roundGlasses, "reading glasses while chewing")
        #expect(e.appearance.outfit.isEmpty, "the chosen outfit is untouched")
        e.ingestionFinished(success: true)
        e.simulate(3)
        #expect(e.frame().outfit.eyewear == .none)
        e.occasion = .reading
        e.simulate(0.1)
        #expect(e.frame().outfit.eyewear == .roundGlasses)
        e.occasion = nil
        e.appearance.dressForOccasion = false
        e.drop()
        e.simulate(0.4)
        #expect(e.frame().outfit.isEmpty, "off means off")
        e.ingestionFinished(success: true)
        e.appearance.dressForOccasion = true
        e.appearance.outfit.eyewear = .sunglasses
        e.simulate(0.2)
        e.drop()
        e.simulate(0.4)
        #expect(e.frame().outfit.eyewear == .sunglasses, "chosen eyewear wins over the situational glasses")
    }

    @Test func appearanceCarriesDressForOccasion() throws {
        var a = SlimeAppearance(look: .cat, outfit: SlimeOutfit.set(named: "scholar")!)
        a.dressForOccasion = false
        let data = try JSONEncoder().encode(a)
        let back = try JSONDecoder().decode(SlimeAppearance.self, from: data)
        #expect(back == a && back.dressForOccasion == false)
        let old = try JSONDecoder().decode(SlimeAppearance.self, from: Data(#"{"look":{"name":"fox"}}"#.utf8))
        #expect(old.dressForOccasion && old.outfit.isEmpty)
        #expect(a.forMini.outfit.isEmpty && a.forGhost.outfit.isEmpty)
    }
}
