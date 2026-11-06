import CoreGraphics
import SwiftUI
import simd
import SlimeKit

/// Clothes: headwear on the crown (trait space: origin at the crown, +y up along the hat's
/// direction, +x to the right), wraps around the body (origin at the centroid), charms, and
/// eyewear drawn straight onto the eye anchors.
extension SlimeCGRenderer {
    enum Wardrobe {
        static let gold = RGBA(hex: 0xFFC43D)
        static let goldDark = RGBA(hex: 0xC98A12)
        static let gem = RGBA(hex: 0xE0453F)
        static let silver = RGBA(hex: 0xE8EEF5)
        static let silverDark = RGBA(hex: 0xA9B6C6)
        static let board = RGBA(hex: 0x2B2B33)
        static let red = RGBA(hex: 0xD83A3A)
        static let redDark = RGBA(hex: 0x9E2525)
        static let straw = RGBA(hex: 0xE9C97A)
        static let strawDark = RGBA(hex: 0xC9A455)
        static let beret = RGBA(hex: 0xC94F6D)
        static let wizard = RGBA(hex: 0x4B3F8F)
        static let wizardDark = RGBA(hex: 0x2F2660)
        static let phones = RGBA(hex: 0x2E2E36)
        static let pink = RGBA(hex: 0xF06292)
        static let petal = RGBA(hex: 0xFFD0E0)
        static let halo = RGBA(hex: 0xFFE27A)
        static let night = RGBA(hex: 0x6C7BD1)
        static let nightDark = RGBA(hex: 0x4A58A8)
        static let leaf = RGBA(hex: 0x6CBF5A)
        static let leafDark = RGBA(hex: 0x3F8F33)
        static let cape = RGBA(hex: 0xC8323C)
        static let capeDark = RGBA(hex: 0x8E1F29)
        static let scarf = RGBA(hex: 0xE25C5C)
        static let scarfDark = RGBA(hex: 0xB33E3E)
        static let towelStripe = RGBA(hex: 0x7FB2E5)
        static let hoodie = RGBA(hex: 0x8A9BB5)
        static let hoodieDark = RGBA(hex: 0x62728C)
        static let duck = RGBA(hex: 0xFFD93B)
        static let beak = RGBA(hex: 0xF28C28)
        static let ink = RGBA(hex: 0x2A2A33)
        static let lens = RGBA(hex: 0x1E1E24)
    }

    func outline(_ p: CGPath, _ t: TraitFrame, width: CGFloat = 1.1, in cg: CGContext) {
        stroke(p, Wardrobe.ink, 0.8, width: hair(t, width), in: cg)
    }

    // MARK: Headwear

    func drawHeadwear(_ kind: SlimeOutfit.Headwear, _ t: TraitFrame, in cg: CGContext) {
        inTraitSpace(t, rotation: CGFloat(t.phase), in: cg) { cg in
            switch kind {
            case .none:
                break
            case .crown:
                let p = CGMutablePath()
                p.move(to: CGPoint(x: -0.42, y: -0.06))
                p.addLine(to: CGPoint(x: -0.44, y: 0.26))
                p.addLine(to: CGPoint(x: -0.3, y: 0.52))
                p.addLine(to: CGPoint(x: -0.15, y: 0.26))
                p.addLine(to: CGPoint(x: 0, y: 0.58))
                p.addLine(to: CGPoint(x: 0.15, y: 0.26))
                p.addLine(to: CGPoint(x: 0.3, y: 0.52))
                p.addLine(to: CGPoint(x: 0.44, y: 0.26))
                p.addLine(to: CGPoint(x: 0.42, y: -0.06))
                p.closeSubpath()
                fill(p, Wardrobe.gold, in: cg)
                fill(CGPath(rect: CGRect(x: -0.44, y: -0.06, width: 0.88, height: 0.12), transform: nil), Wardrobe.goldDark, 0.6, in: cg)
                for (x, y) in [(-0.3, 0.52), (0.0, 0.58), (0.3, 0.52)] as [(CGFloat, CGFloat)] {
                    fill(Self.ellipse(CGPoint(x: x, y: y), 0.055, 0.055), Wardrobe.gold, in: cg)
                }
                fill(Self.ellipse(CGPoint(x: 0, y: 0.16), 0.08, 0.08), Wardrobe.gem, in: cg)
                fill(Self.ellipse(CGPoint(x: -0.03, y: 0.19), 0.025, 0.02), .white, 0.8, in: cg)
                outline(p, t, in: cg)
            case .tiara:
                let p = CGMutablePath()
                p.move(to: CGPoint(x: -0.42, y: 0.0))
                p.addQuadCurve(to: CGPoint(x: 0, y: 0.3), control: CGPoint(x: -0.25, y: 0.3))
                p.addQuadCurve(to: CGPoint(x: 0.42, y: 0.0), control: CGPoint(x: 0.25, y: 0.3))
                p.addQuadCurve(to: CGPoint(x: 0, y: 0.1), control: CGPoint(x: 0.2, y: 0.1))
                p.addQuadCurve(to: CGPoint(x: -0.42, y: 0.0), control: CGPoint(x: -0.2, y: 0.1))
                p.closeSubpath()
                fill(p, Wardrobe.silver, in: cg)
                fill(Self.ellipse(CGPoint(x: 0, y: 0.26), 0.07, 0.07), Wardrobe.pink, in: cg)
                stroke(p, Wardrobe.silverDark, 0.9, width: hair(t, 1.0), in: cg)
            case .mortarboard:
                let cap = CGPath(ellipseIn: CGRect(x: -0.36, y: -0.14, width: 0.72, height: 0.4), transform: nil)
                fill(cap, Wardrobe.board, in: cg)
                let board = CGMutablePath()
                board.move(to: CGPoint(x: -0.6, y: 0.2))
                board.addLine(to: CGPoint(x: 0.0, y: 0.46))
                board.addLine(to: CGPoint(x: 0.6, y: 0.2))
                board.addLine(to: CGPoint(x: 0.0, y: 0.06))
                board.closeSubpath()
                fill(board, Wardrobe.board, in: cg)
                stroke(board, RGBA(hex: 0x55556A), 0.9, width: hair(t, 1.0), in: cg)
                fill(Self.ellipse(CGPoint(x: 0, y: 0.46), 0.04, 0.04), Wardrobe.gold, in: cg)
                let tassel = CGMutablePath()
                tassel.move(to: CGPoint(x: 0, y: 0.46))
                tassel.addQuadCurve(to: CGPoint(x: 0.52, y: 0.0), control: CGPoint(x: 0.5, y: 0.4))
                stroke(tassel, Wardrobe.gold, 1, width: hair(t, 1.4), in: cg)
                fill(Self.ellipse(CGPoint(x: 0.53, y: -0.06), 0.045, 0.08), Wardrobe.gold, in: cg)
            case .santaHat, .nightcap:
                let night = kind == .nightcap
                let body = CGMutablePath()
                body.move(to: CGPoint(x: -0.4, y: 0.08))
                body.addCurve(to: CGPoint(x: 0.5, y: 0.62), control1: CGPoint(x: -0.3, y: 0.55), control2: CGPoint(x: 0.1, y: 0.7))
                if night {
                    body.addQuadCurve(to: CGPoint(x: 0.72, y: 0.3), control: CGPoint(x: 0.74, y: 0.55))
                    body.addQuadCurve(to: CGPoint(x: 0.4, y: 0.08), control: CGPoint(x: 0.5, y: 0.2))
                } else {
                    body.addQuadCurve(to: CGPoint(x: 0.62, y: 0.46), control: CGPoint(x: 0.68, y: 0.62))
                    body.addQuadCurve(to: CGPoint(x: 0.4, y: 0.08), control: CGPoint(x: 0.5, y: 0.18))
                }
                body.closeSubpath()
                celFill(body, night ? Wardrobe.night : Wardrobe.red, shadow: night ? Wardrobe.nightDark : Wardrobe.redDark, split: 0.12, t, in: cg)
                let band = CGPath(roundedRect: CGRect(x: -0.46, y: -0.06, width: 0.92, height: 0.17), cornerWidth: 0.08, cornerHeight: 0.08, transform: nil)
                fill(band, .white, in: cg)
                outline(band, t, width: 0.9, in: cg)
                let pom = Self.ellipse(night ? CGPoint(x: 0.72, y: 0.3) : CGPoint(x: 0.63, y: 0.47), 0.1, 0.1)
                fill(pom, .white, in: cg)
                outline(pom, t, width: 0.9, in: cg)
            case .strawHat:
                let brim = CGPath(ellipseIn: CGRect(x: -0.8, y: 0.0, width: 1.6, height: 0.22), transform: nil)
                celFill(brim, Wardrobe.straw, shadow: Wardrobe.strawDark, split: 0.3, t, in: cg)
                let crown = CGMutablePath()
                crown.move(to: CGPoint(x: -0.42, y: 0.1))
                crown.addCurve(to: CGPoint(x: 0.42, y: 0.1), control1: CGPoint(x: -0.4, y: 0.52), control2: CGPoint(x: 0.4, y: 0.52))
                crown.closeSubpath()
                celFill(crown, Wardrobe.straw, shadow: Wardrobe.strawDark, split: 0.12, t, in: cg)
                cg.saveGState()
                cg.addPath(crown)
                cg.clip()
                fill(CGPath(rect: CGRect(x: -0.5, y: 0.12, width: 1, height: 0.09), transform: nil), Wardrobe.red, in: cg)
                cg.restoreGState()
            case .beret:
                let disc = CGPath(ellipseIn: CGRect(x: -0.48, y: 0.0, width: 0.96, height: 0.36), transform: nil)
                celFill(disc, Wardrobe.beret, shadow: Wardrobe.beret.mixed(with: .black, 0.35), split: 0.15, t, in: cg)
                fill(Self.ellipse(CGPoint(x: 0.05, y: 0.36), 0.04, 0.05), Wardrobe.beret.mixed(with: .black, 0.3), in: cg)
            case .wizardHat:
                let cone = CGMutablePath()
                cone.move(to: CGPoint(x: -0.4, y: 0.08))
                cone.addCurve(to: CGPoint(x: 0.12, y: 0.98), control1: CGPoint(x: -0.2, y: 0.55), control2: CGPoint(x: -0.05, y: 0.8))
                cone.addQuadCurve(to: CGPoint(x: 0.34, y: 0.86), control: CGPoint(x: 0.32, y: 1.0))
                cone.addCurve(to: CGPoint(x: 0.4, y: 0.08), control1: CGPoint(x: 0.2, y: 0.78), control2: CGPoint(x: 0.3, y: 0.45))
                cone.closeSubpath()
                celFill(cone, Wardrobe.wizard, shadow: Wardrobe.wizardDark, split: 0.1, t, in: cg)
                let brim = CGPath(ellipseIn: CGRect(x: -0.66, y: -0.02, width: 1.32, height: 0.2), transform: nil)
                celFill(brim, Wardrobe.wizard, shadow: Wardrobe.wizardDark, split: 0.2, t, in: cg)
                cg.saveGState()
                cg.addPath(cone)
                cg.clip()
                fill(CGPath(rect: CGRect(x: -0.5, y: 0.16, width: 1, height: 0.1), transform: nil), Wardrobe.gold, in: cg)
                cg.restoreGState()
                fill(BodyPath.sparkle(center: CGPoint(x: 0.0, y: 0.5), radius: 0.07).cgPath, Wardrobe.gold, 0.95, in: cg)
                fill(BodyPath.sparkle(center: CGPoint(x: -0.14, y: 0.32), radius: 0.045).cgPath, Wardrobe.gold, 0.9, in: cg)
            case .headphones:
                let band = CGMutablePath()
                band.move(to: CGPoint(x: -0.92, y: -0.48))
                band.addCurve(to: CGPoint(x: 0.92, y: -0.48), control1: CGPoint(x: -0.9, y: 0.4), control2: CGPoint(x: 0.9, y: 0.4))
                stroke(band, Wardrobe.phones, 1, width: 0.09, in: cg)
                for x in [-0.96, 0.96] as [CGFloat] {
                    let cup = CGPath(roundedRect: CGRect(x: x - 0.11, y: -0.72, width: 0.22, height: 0.34), cornerWidth: 0.08, cornerHeight: 0.08, transform: nil)
                    fill(cup, Wardrobe.phones, in: cg)
                    fill(CGPath(roundedRect: CGRect(x: x - 0.07, y: -0.66, width: 0.14, height: 0.22), cornerWidth: 0.05, cornerHeight: 0.05, transform: nil), theme.accent, 0.9, in: cg)
                    outline(cup, t, width: 0.9, in: cg)
                }
            case .bow:
                let p = CGMutablePath()
                p.move(to: .zero)
                p.addQuadCurve(to: CGPoint(x: -0.34, y: 0.26), control: CGPoint(x: -0.42, y: -0.02))
                p.addQuadCurve(to: .zero, control: CGPoint(x: -0.22, y: 0.36))
                p.addQuadCurve(to: CGPoint(x: 0.34, y: 0.26), control: CGPoint(x: 0.22, y: 0.36))
                p.addQuadCurve(to: .zero, control: CGPoint(x: 0.42, y: -0.02))
                p.closeSubpath()
                celFill(p, Wardrobe.pink, shadow: Wardrobe.pink.mixed(with: .black, 0.3), split: 0.05, t, in: cg)
                fill(Self.ellipse(CGPoint(x: 0, y: 0.08), 0.07, 0.08), Wardrobe.pink.mixed(with: .black, 0.25), in: cg)
            case .flower:
                for k in 0..<5 {
                    let a = Double(k) / 5 * 2 * .pi - .pi / 2
                    fill(Self.ellipse(CGPoint(x: CGFloat(cos(a)) * 0.16, y: 0.12 + CGFloat(sin(a)) * 0.16), 0.11, 0.11), Wardrobe.petal, in: cg)
                    outline(Self.ellipse(CGPoint(x: CGFloat(cos(a)) * 0.16, y: 0.12 + CGFloat(sin(a)) * 0.16), 0.11, 0.11), t, width: 0.8, in: cg)
                }
                fill(Self.ellipse(CGPoint(x: 0, y: 0.12), 0.09, 0.09), Wardrobe.gold, in: cg)
            case .halo:
                let ring = CGPath(ellipseIn: CGRect(x: -0.5, y: -0.08, width: 1.0, height: 0.2), transform: nil)
                stroke(ring, Wardrobe.halo, 0.45, width: 0.14, in: cg)
                stroke(ring, Wardrobe.halo, 1, width: 0.06, in: cg)
                stroke(ring, .white, 0.7, width: 0.02, in: cg)
            case .leaf:
                let stalk = CGMutablePath()
                stalk.move(to: .zero)
                stalk.addQuadCurve(to: CGPoint(x: 0.06, y: 0.24), control: CGPoint(x: -0.02, y: 0.14))
                stroke(stalk, Wardrobe.leafDark, 1, width: 0.035, in: cg)
                var m = CGAffineTransform(translationX: 0.16, y: 0.32).rotated(by: 0.55)
                let blade = CGPath(ellipseIn: CGRect(x: -0.16, y: -0.08, width: 0.32, height: 0.16), transform: &m)
                celFill(blade, Wardrobe.leaf, shadow: Wardrobe.leafDark, split: 0.12, t, in: cg)
                let rib = CGMutablePath()
                rib.move(to: CGPoint(x: 0.06, y: 0.24))
                rib.addLine(to: CGPoint(x: 0.28, y: 0.4))
                stroke(rib, Wardrobe.leafDark, 0.8, width: hair(t, 1.0), in: cg)
            }
        }
    }

    // MARK: Wraps

    func drawWrapBack(_ kind: SlimeOutfit.Wrap, _ t: TraitFrame, in cg: CGContext) {
        inTraitSpace(t, in: cg) { cg in
            switch kind {
            case .royalCape:
                let p = CGMutablePath()
                p.move(to: CGPoint(x: -0.82, y: 0.72))
                p.addCurve(to: CGPoint(x: -1.3, y: -0.92), control1: CGPoint(x: -1.05, y: 0.2), control2: CGPoint(x: -1.3, y: -0.4))
                for k in 0..<5 {
                    let x0 = -1.3 + CGFloat(k) * 0.52
                    p.addQuadCurve(to: CGPoint(x: x0 + 0.52, y: -0.92), control: CGPoint(x: x0 + 0.26, y: -0.78))
                }
                p.addCurve(to: CGPoint(x: 0.82, y: 0.72), control1: CGPoint(x: 1.3, y: -0.4), control2: CGPoint(x: 1.05, y: 0.2))
                p.addQuadCurve(to: CGPoint(x: -0.82, y: 0.72), control: CGPoint(x: 0, y: 0.95))
                p.closeSubpath()
                fill(p, Wardrobe.cape, in: cg)
                fillRadial(p, [(Wardrobe.capeDark.opacity(0), 0), (Wardrobe.capeDark.opacity(0.55), 1)], center: CGPoint(x: 0, y: 0.3), radius: 1.5, in: cg)
                let folds = CGMutablePath()
                for x in [-0.6, -0.2, 0.2, 0.6] as [CGFloat] {
                    folds.move(to: CGPoint(x: x * 0.7, y: 0.5))
                    folds.addQuadCurve(to: CGPoint(x: x * 1.6, y: -0.85), control: CGPoint(x: x * 1.1, y: -0.2))
                }
                stroke(folds, Wardrobe.capeDark, 0.5, width: hair(t, 1.2), in: cg)
                outline(p, t, in: cg)
            case .hoodie:
                var m = CGAffineTransform(translationX: 0, y: -0.62)
                let hood = CGPath(ellipseIn: CGRect(x: -1.24, y: -1.08, width: 2.48, height: 2.16), transform: &m)
                let peak = CGMutablePath()
                peak.addPath(hood)
                peak.move(to: CGPoint(x: -0.3, y: 0.3))
                peak.addQuadCurve(to: CGPoint(x: 0.3, y: 0.3), control: CGPoint(x: 0.15, y: 0.62))
                peak.closeSubpath()
                fill(peak, Wardrobe.hoodie, in: cg)
                outline(peak, t, in: cg)
            default:
                break
            }
        }
    }

    func drawWrapFront(_ kind: SlimeOutfit.Wrap, _ t: TraitFrame, in cg: CGContext) {
        inTraitSpace(t, in: cg) { cg in
            switch kind {
            case .royalCape:
                // Fur collar across the chest with a brooch.
                let collar = CGMutablePath()
                collar.move(to: CGPoint(x: -0.98, y: 0.1))
                collar.addQuadCurve(to: CGPoint(x: 0.98, y: 0.1), control: CGPoint(x: 0, y: -1.0))
                stroke(collar, .white, 1, width: 0.2, in: cg)
                stroke(collar, Wardrobe.ink, 0.5, width: 0.22, in: cg)
                stroke(collar, .white, 1, width: 0.18, in: cg)
                for k in 0..<9 {
                    let u = CGFloat(k) / 8
                    let x = -0.98 + 1.96 * u
                    let y = 0.1 * (1 - u) * (1 - u) + 2 * (1 - u) * u * (-1.0) + 0.1 * u * u
                    fill(Self.ellipse(CGPoint(x: x, y: y), 0.028, 0.028), Wardrobe.ink, 0.6, in: cg)
                }
                fill(Self.ellipse(CGPoint(x: 0, y: -0.47), 0.09, 0.09), Wardrobe.gold, in: cg)
                fill(Self.ellipse(CGPoint(x: 0, y: -0.47), 0.045, 0.045), Wardrobe.gem, in: cg)
            case .scarf:
                let band = CGMutablePath()
                band.move(to: CGPoint(x: -0.96, y: -0.1))
                band.addQuadCurve(to: CGPoint(x: 0.96, y: -0.1), control: CGPoint(x: 0, y: -0.5))
                band.addLine(to: CGPoint(x: 0.96, y: -0.38))
                band.addQuadCurve(to: CGPoint(x: -0.96, y: -0.38), control: CGPoint(x: 0, y: -0.78))
                band.closeSubpath()
                fill(band, Wardrobe.scarf, in: cg)
                let stripes = CGMutablePath()
                for x in [-0.7, -0.35, 0.0, 0.35, 0.7] as [CGFloat] {
                    stripes.move(to: CGPoint(x: x - 0.04, y: -0.1 - 0.2 * (1 - abs(x) / 1.2)))
                    stripes.addLine(to: CGPoint(x: x + 0.04, y: -0.38 - 0.2 * (1 - abs(x) / 1.2)))
                }
                cg.saveGState()
                cg.addPath(band)
                cg.clip()
                stroke(stripes, Wardrobe.scarfDark, 0.8, width: 0.05, in: cg)
                cg.restoreGState()
                outline(band, t, in: cg)
                let tail = CGMutablePath()
                tail.move(to: CGPoint(x: 0.62, y: -0.3))
                tail.addQuadCurve(to: CGPoint(x: 0.9, y: -0.85), control: CGPoint(x: 0.95, y: -0.5))
                tail.addLine(to: CGPoint(x: 0.72, y: -0.9))
                tail.addQuadCurve(to: CGPoint(x: 0.5, y: -0.35), control: CGPoint(x: 0.62, y: -0.6))
                tail.closeSubpath()
                fill(tail, Wardrobe.scarf, in: cg)
                outline(tail, t, in: cg)
                let knot = CGPath(roundedRect: CGRect(x: 0.5, y: -0.42, width: 0.26, height: 0.24), cornerWidth: 0.08, cornerHeight: 0.08, transform: nil)
                fill(knot, Wardrobe.scarf, in: cg)
                outline(knot, t, in: cg)
            case .towel:
                let lower = CGPath(roundedRect: CGRect(x: -0.52, y: -0.04, width: 1.04, height: 0.28), cornerWidth: 0.1, cornerHeight: 0.1, transform: nil)
                let upper = CGPath(roundedRect: CGRect(x: -0.38, y: 0.22, width: 0.76, height: 0.2), cornerWidth: 0.08, cornerHeight: 0.08, transform: nil)
                for (p, y) in [(lower, 0.08), (upper, 0.3)] as [(CGPath, CGFloat)] {
                    fill(p, .white, in: cg)
                    cg.saveGState()
                    cg.addPath(p)
                    cg.clip()
                    fill(CGPath(rect: CGRect(x: -1, y: y, width: 2, height: 0.05), transform: nil), Wardrobe.towelStripe, in: cg)
                    cg.restoreGState()
                    outline(p, t, width: 0.9, in: cg)
                }
            case .hoodie:
                let rim = CGMutablePath()
                rim.move(to: CGPoint(x: -1.02, y: -1.0))
                rim.addCurve(to: CGPoint(x: 1.02, y: -1.0), control1: CGPoint(x: -1.1, y: 0.35), control2: CGPoint(x: 1.1, y: 0.35))
                stroke(rim, Wardrobe.hoodieDark, 1, width: 0.2, in: cg)
                stroke(rim, Wardrobe.hoodie, 1, width: 0.14, in: cg)
                let strings = CGMutablePath()
                for x in [-0.22, 0.22] as [CGFloat] {
                    strings.move(to: CGPoint(x: x, y: -1.0))
                    strings.addQuadCurve(to: CGPoint(x: x * 1.3, y: -1.45), control: CGPoint(x: x * 1.4, y: -1.2))
                }
                stroke(strings, .white, 0.9, width: 0.04, in: cg)
            case .bowtie:
                let p = CGMutablePath()
                p.move(to: CGPoint(x: 0, y: -0.6))
                p.addLine(to: CGPoint(x: -0.32, y: -0.44))
                p.addLine(to: CGPoint(x: -0.32, y: -0.76))
                p.closeSubpath()
                p.move(to: CGPoint(x: 0, y: -0.6))
                p.addLine(to: CGPoint(x: 0.32, y: -0.44))
                p.addLine(to: CGPoint(x: 0.32, y: -0.76))
                p.closeSubpath()
                fill(p, Wardrobe.red, in: cg)
                outline(p, t, in: cg)
                let knot = Self.ellipse(CGPoint(x: 0, y: -0.6), 0.07, 0.08)
                fill(knot, Wardrobe.redDark, in: cg)
            case .none:
                break
            }
        }
    }

    // MARK: Charms

    func drawCharm(_ kind: SlimeOutfit.Charm, _ t: TraitFrame, in cg: CGContext) {
        inTraitSpace(t, rotation: CGFloat(t.phase), in: cg) { cg in
            switch kind {
            case .duck:
                let body = CGPath(ellipseIn: CGRect(x: -0.18, y: 0.0, width: 0.36, height: 0.24), transform: nil)
                celFill(body, Wardrobe.duck, shadow: Wardrobe.duck.mixed(with: Wardrobe.beak, 0.4), split: 0.04, t, in: cg)
                let head = Self.ellipse(CGPoint(x: 0.12, y: 0.28), 0.12, 0.12)
                fill(head, Wardrobe.duck, in: cg)
                outline(head, t, width: 0.9, in: cg)
                let beak = CGMutablePath()
                beak.move(to: CGPoint(x: 0.22, y: 0.3))
                beak.addLine(to: CGPoint(x: 0.36, y: 0.27))
                beak.addLine(to: CGPoint(x: 0.22, y: 0.22))
                beak.closeSubpath()
                fill(beak, Wardrobe.beak, in: cg)
                fill(Self.ellipse(CGPoint(x: 0.14, y: 0.32), 0.022, 0.022), Wardrobe.ink, in: cg)
                let wing = CGMutablePath()
                wing.move(to: CGPoint(x: -0.1, y: 0.14))
                wing.addQuadCurve(to: CGPoint(x: 0.06, y: 0.06), control: CGPoint(x: -0.06, y: 0.02))
                stroke(wing, Wardrobe.beak, 0.7, width: hair(t, 1.0), in: cg)
            case .bell:
                let bell = CGMutablePath()
                bell.move(to: CGPoint(x: -0.16, y: -0.1))
                bell.addCurve(to: CGPoint(x: 0.16, y: -0.1), control1: CGPoint(x: -0.16, y: 0.22), control2: CGPoint(x: 0.16, y: 0.22))
                bell.addLine(to: CGPoint(x: 0.2, y: -0.15))
                bell.addLine(to: CGPoint(x: -0.2, y: -0.15))
                bell.closeSubpath()
                celFill(bell, Wardrobe.gold, shadow: Wardrobe.goldDark, split: 0.03, t, in: cg)
                fill(Self.ellipse(CGPoint(x: 0, y: -0.17), 0.04, 0.04), Wardrobe.goldDark, in: cg)
                let ribbon = CGMutablePath()
                ribbon.move(to: CGPoint(x: -0.12, y: 0.16))
                ribbon.addLine(to: CGPoint(x: 0, y: 0.1))
                ribbon.addLine(to: CGPoint(x: 0.12, y: 0.16))
                ribbon.addLine(to: CGPoint(x: 0, y: 0.22))
                ribbon.closeSubpath()
                fill(ribbon, Wardrobe.red, in: cg)
            case .none:
                break
            }
        }
    }

    // MARK: Eyewear (world space, on the eye anchors)

    func drawEyewear(in cg: CGContext) {
        let kind = frame.outfit.eyewear
        guard kind != .none, frame.faceOpacity > 0.005 else { return }
        let eyes = frame.eyes.filter { $0.visible }
        guard !eyes.isEmpty else { return }
        cg.saveGState()
        cg.setAlpha(frame.opacity * frame.faceOpacity)
        let rot = CGFloat(frame.body.rotation)
        let sx = CGFloat(frame.body.scaleX)
        let sy = CGFloat(frame.body.scaleY)
        let lw = max(1.0, 0.035 * R)
        func lensRect(_ e: EyeFrame, _ k: CGFloat) -> (CGPoint, CGFloat, CGFloat) {
            let r = CGFloat(e.radius * e.scale) * R * k
            return (px(e.center), r * CGFloat(e.foreshorten.x) * sx, r * CGFloat(e.foreshorten.y) * sy)
        }
        func rotated(_ p: CGPath, about c: CGPoint) -> CGPath {
            var m = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: rot).translatedBy(x: -c.x, y: -c.y)
            return p.copy(using: &m) ?? p
        }
        let left = eyes.min { $0.side < $1.side }
        let right = eyes.max { $0.side < $1.side }
        switch kind {
        case .none:
            break
        case .roundGlasses:
            for e in eyes {
                let (c, rx, ry) = lensRect(e, 1.5)
                let lens = rotated(Self.ellipse(c, rx, ry), about: c)
                fill(lens, .white, 0.12, in: cg)
                stroke(lens, Wardrobe.ink, 0.9, width: lw, in: cg)
            }
            if eyes.count == 2, let l = left, let r = right {
                let (lc, lrx, _) = lensRect(l, 1.5)
                let (rc, rrx, _) = lensRect(r, 1.5)
                let bridge = CGMutablePath()
                bridge.move(to: CGPoint(x: lc.x + lrx, y: lc.y - 0.02 * R))
                bridge.addQuadCurve(to: CGPoint(x: rc.x - rrx, y: rc.y - 0.02 * R), control: CGPoint(x: (lc.x + rc.x) / 2, y: (lc.y + rc.y) / 2 - 0.1 * R))
                bridge.move(to: CGPoint(x: lc.x - lrx, y: lc.y))
                bridge.addLine(to: CGPoint(x: lc.x - lrx - 0.16 * R, y: lc.y - 0.06 * R))
                bridge.move(to: CGPoint(x: rc.x + rrx, y: rc.y))
                bridge.addLine(to: CGPoint(x: rc.x + rrx + 0.16 * R, y: rc.y - 0.06 * R))
                stroke(bridge, Wardrobe.ink, 0.9, width: lw, in: cg)
            }
        case .sunglasses:
            for e in eyes {
                let (c, rx, ry) = lensRect(e, 1.55)
                let lens = rotated(CGPath(roundedRect: CGRect(x: c.x - rx, y: c.y - ry * 0.85, width: 2 * rx, height: 1.7 * ry), cornerWidth: rx * 0.45, cornerHeight: ry * 0.45, transform: nil), about: c)
                fill(lens, Wardrobe.lens, 0.94, in: cg)
                stroke(lens, Wardrobe.ink, 1, width: lw, in: cg)
                let streak = CGMutablePath()
                streak.move(to: CGPoint(x: c.x - rx * 0.6, y: c.y - ry * 0.1))
                streak.addLine(to: CGPoint(x: c.x - rx * 0.1, y: c.y - ry * 0.6))
                stroke(rotated(streak, about: c), .white, 0.55, width: lw, in: cg)
            }
            if eyes.count == 2, let l = left, let r = right {
                let (lc, lrx, _) = lensRect(l, 1.55)
                let (rc, rrx, _) = lensRect(r, 1.55)
                let bridge = CGMutablePath()
                bridge.move(to: CGPoint(x: lc.x + lrx, y: lc.y - 0.05 * R))
                bridge.addLine(to: CGPoint(x: rc.x - rrx, y: rc.y - 0.05 * R))
                stroke(bridge, Wardrobe.ink, 1, width: lw * 1.4, in: cg)
            }
        case .monocle:
            if let r = right {
                let (c, rx, ry) = lensRect(r, 1.5)
                let lens = rotated(Self.ellipse(c, rx, ry), about: c)
                fill(lens, .white, 0.12, in: cg)
                stroke(lens, Wardrobe.gold, 1, width: lw, in: cg)
                let chain = CGMutablePath()
                chain.move(to: CGPoint(x: c.x + rx * 0.7, y: c.y + ry * 0.7))
                chain.addCurve(to: CGPoint(x: c.x + rx * 1.6, y: c.y + ry * 2.8), control1: CGPoint(x: c.x + rx * 1.5, y: c.y + ry * 1.0), control2: CGPoint(x: c.x + rx * 1.1, y: c.y + ry * 2.2))
                stroke(chain, Wardrobe.gold, 0.9, width: max(0.8, lw * 0.6), in: cg)
            }
        case .mask:
            if let l = left, let r = right {
                let (lc, lrx, lry) = lensRect(l, 1.0)
                let (rc, rrx, rry) = lensRect(r, 1.0)
                let (lcx, rcx) = eyes.count == 2 ? (lc, rc) : (lc, lc)
                let h = max(lry, rry) * 1.9
                let p = CGMutablePath()
                p.move(to: CGPoint(x: lcx.x - lrx * 2.2, y: lcx.y - h * 0.9))
                p.addQuadCurve(to: CGPoint(x: (lcx.x + rcx.x) / 2, y: (lcx.y + rcx.y) / 2 - h * 0.55), control: CGPoint(x: lcx.x - lrx * 0.3, y: lcx.y - h * 1.15))
                p.addQuadCurve(to: CGPoint(x: rcx.x + rrx * 2.2, y: rcx.y - h * 0.9), control: CGPoint(x: rcx.x + rrx * 0.3, y: rcx.y - h * 1.15))
                p.addQuadCurve(to: CGPoint(x: rcx.x + rrx * 1.4, y: rcx.y + h * 0.75), control: CGPoint(x: rcx.x + rrx * 2.4, y: rcx.y + h * 0.1))
                p.addQuadCurve(to: CGPoint(x: (lcx.x + rcx.x) / 2, y: (lcx.y + rcx.y) / 2 + h * 0.3), control: CGPoint(x: rcx.x - rrx * 0.4, y: rcx.y + h * 0.9))
                p.addQuadCurve(to: CGPoint(x: lcx.x - lrx * 1.4, y: lcx.y + h * 0.75), control: CGPoint(x: lcx.x + lrx * 0.4, y: lcx.y + h * 0.9))
                p.closeSubpath()
                for e in eyes {
                    let (c, rx, ry) = lensRect(e, 1.22)
                    p.addPath(rotated(Self.ellipse(c, rx, ry), about: c))
                }
                let mask = rotated(p, about: CGPoint(x: (lcx.x + rcx.x) / 2, y: (lcx.y + rcx.y) / 2))
                fill(mask, Wardrobe.ink, 0.95, evenOdd: true, in: cg)
            }
        case .eyepatch:
            if let l = left {
                let (c, rx, ry) = lensRect(l, 1.6)
                let patch = rotated(Self.ellipse(c, rx, ry), about: c)
                fill(patch, Wardrobe.ink, 0.96, in: cg)
                let strap = CGMutablePath()
                strap.move(to: CGPoint(x: c.x + rx * 0.4, y: c.y - ry * 0.9))
                strap.addLine(to: CGPoint(x: c.x + rx * 3.2, y: c.y - ry * 3.4))
                strap.move(to: CGPoint(x: c.x - rx * 0.9, y: c.y + ry * 0.2))
                strap.addLine(to: CGPoint(x: c.x - rx * 2.6, y: c.y + ry * 0.9))
                stroke(rotated(strap, about: c), Wardrobe.ink, 0.95, width: lw * 1.1, in: cg)
            }
        }
        cg.restoreGState()
    }
}
