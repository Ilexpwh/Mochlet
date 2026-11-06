import Foundation
import simd

/// Places clothes on the body: headwear on the top ring point (lagging on a spring so hats bounce
/// a beat after a landing), wraps around the body, charms on the head or front. Eyewear is drawn
/// straight onto the eye anchors by the renderer and needs no rig.
public enum OutfitRig {
    public static func build(outfit: SlimeOutfit, ring: [SIMD2<Double>], anim: TraitAnim, detail: DetailLevel, mini: Bool) -> [TraitFrame] {
        guard ring.count >= 6, !outfit.isEmpty else { return [] }
        var out: [TraitFrame] = []
        let n = ring.count
        var c = SIMD2<Double>.zero
        for p in ring { c += p }
        c /= Double(n)
        func at(_ angle: Double) -> (p: SIMD2<Double>, normal: SIMD2<Double>) {
            let p = ring[TraitRig.index(angle: angle, count: n)]
            return (p, TraitRig.unit(p - c))
        }
        let s = mini ? 0.8 : 1.0
        let up = SIMD2<Double>(0, -1)
        let top = -Double.pi / 2
        let crown = at(top)
        let hatDir = TraitRig.rotate(crown.normal, by: anim.hat.x * 2.5)
        let hatAnchor = crown.p + anim.hat
        let rich = detail >= .medium

        // Wraps: the back layer first, then the front pieces (before the hat so a towel sits under it).
        switch outfit.wrap {
        case .royalCape where rich:
            out.append(TraitFrame(kind: .wrapBack(.royalCape), side: 0, anchor: c, direction: up, scale: s, phase: 0))
            out.append(TraitFrame(kind: .wrapFront(.royalCape), side: 0, anchor: c, direction: up, scale: s, phase: 0))
        case .hoodie where rich:
            out.append(TraitFrame(kind: .wrapBack(.hoodie), side: 0, anchor: crown.p, direction: crown.normal, scale: s, phase: 0))
            out.append(TraitFrame(kind: .wrapFront(.hoodie), side: 0, anchor: crown.p, direction: crown.normal, scale: s, phase: 0))
        case .scarf where rich, .bowtie where rich:
            out.append(TraitFrame(kind: .wrapFront(outfit.wrap), side: 0, anchor: c, direction: up, scale: s, phase: 0))
        case .towel:
            out.append(TraitFrame(kind: .wrapFront(.towel), side: 0, anchor: hatAnchor, direction: hatDir, scale: s, phase: 0))
        default:
            break
        }

        // Headwear on the crown. Side pieces (bow, flower, leaf) sit to the right; a halo floats.
        switch outfit.headwear {
        case .none:
            break
        case .bow, .flower:
            let side = at(top + 0.6)
            out.append(TraitFrame(kind: .headwear(outfit.headwear), side: 1, anchor: side.p + anim.hat * 0.6, direction: TraitRig.unit(side.normal * 0.7 + up * 0.5), scale: s, phase: 0))
        case .leaf:
            out.append(TraitFrame(kind: .headwear(.leaf), side: 1, anchor: hatAnchor, direction: TraitRig.rotate(hatDir, by: 0.3), scale: s, phase: anim.hat.x * 3))
        case .halo:
            out.append(TraitFrame(kind: .headwear(.halo), side: 0, anchor: crown.p + up * (0.42 * s) + anim.hat * 1.4, direction: up, scale: s, phase: 0))
        case .beret:
            out.append(TraitFrame(kind: .headwear(.beret), side: 1, anchor: hatAnchor + SIMD2(0.12, 0.02) * s, direction: TraitRig.rotate(hatDir, by: 0.22), scale: s, phase: 0))
        default:
            let lift = outfit.wrap == .towel ? 0.22 * s : 0
            out.append(TraitFrame(kind: .headwear(outfit.headwear), side: 0, anchor: hatAnchor + hatDir * lift, direction: hatDir, scale: s, phase: 0))
        }

        // Charms: the duck rides the towel or the head; the bell hangs at the front.
        switch outfit.charm {
        case .duck where rich:
            let onTowel = outfit.wrap == .towel
            let seat = onTowel ? hatAnchor + hatDir * (0.3 * s) + SIMD2(0.18, 0) * s : at(top + 0.5).p + anim.hat * 0.8
            out.append(TraitFrame(kind: .charm(.duck), side: 1, anchor: seat, direction: onTowel ? hatDir : up, scale: s, phase: 0))
        case .bell where rich:
            out.append(TraitFrame(kind: .charm(.bell), side: 0, anchor: c + SIMD2(0, 0.62) * s, direction: up, scale: s, phase: anim.hat.x * 2))
        default:
            break
        }
        return out
    }
}
