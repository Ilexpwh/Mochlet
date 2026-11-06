import CoreGraphics
import SwiftUI
import simd
import SlimeKit

/// Species features and surfaces: wings and fins behind the body, horns, shards, inner ears and
/// tail tips in front, and the surface effects painted inside the body clip.
extension SlimeCGRenderer {
    var detail: DetailLevel { DetailLevel(pixelsPerUnit: Double(R)) }
    var look: SlimeLook { appearance.look }

    /// Path space of a trait: origin at its anchor, +y along its direction, +x toward the floor side
    /// of the body (mirrored for the left side), one unit = R × scale × body scale.
    func traitTransform(_ t: TraitFrame, rotation: CGFloat = 0) -> CGAffineTransform {
        let s = CGFloat(t.scale) * R * CGFloat((frame.body.scaleX * frame.body.scaleY).squareRoot())
        let side = t.side == 0 ? 1.0 : t.side
        let dir = t.direction
        let xAxis = SIMD2(-dir.y, dir.x) * side
        let a = px(t.anchor)
        let m = CGAffineTransform(a: s * CGFloat(xAxis.x), b: s * CGFloat(xAxis.y), c: s * CGFloat(dir.x), d: s * CGFloat(dir.y), tx: a.x, ty: a.y)
        return rotation == 0 ? m : CGAffineTransform(rotationAngle: rotation).concatenating(m)
    }

    func inTraitSpace(_ t: TraitFrame, rotation: CGFloat = 0, in cg: CGContext, _ body: (CGContext) -> Void) {
        cg.saveGState()
        cg.concatenate(traitTransform(t, rotation: rotation))
        body(cg)
        cg.restoreGState()
    }

    /// Line width in trait space for a hairline of `pointsWide` pixels.
    func hair(_ t: TraitFrame, _ pointsWide: CGFloat) -> CGFloat {
        pointsWide / max(1, CGFloat(t.scale) * R)
    }

    /// Ink line for feature outlines: dark on a light body, light on a dark one.
    var featureInk: RGBA { theme.ink.mixed(with: theme.deep, theme.isDark ? 0.2 : 0.45) }

    /// Fills a feature path, darkens its half away from the light (x > split in trait space), and outlines it.
    func celFill(_ p: CGPath, _ base: RGBA, shadow: RGBA? = nil, split: CGFloat = 0.02, outline: CGFloat = 1.1, _ t: TraitFrame, in cg: CGContext) {
        fill(p, base, in: cg)
        cg.saveGState()
        cg.addPath(p)
        cg.clip()
        let dark = shadow ?? base.mixed(with: theme.deep, 0.45)
        fill(CGPath(rect: CGRect(x: split, y: -4, width: 8, height: 8), transform: nil), dark, 0.5, in: cg)
        cg.restoreGState()
        stroke(p, featureInk, 0.85, width: hair(t, outline), in: cg)
    }

    func drawGloss(_ t: TraitFrame, in cg: CGContext) {
        inTraitSpace(t, in: cg) { cg in
            var m = CGAffineTransform(rotationAngle: -0.5)
            let ell = CGPath(ellipseIn: CGRect(x: -0.07, y: -0.04, width: 0.14, height: 0.08), transform: &m)
            fill(ell, theme.highlight, 0.85, in: cg)
        }
    }

    // MARK: Back layer

    func drawBackTraits(in cg: CGContext) {
        for t in frame.traits {
            switch t.kind {
            case .wing(let w): drawWing(w, t, in: cg)
            case .fin: drawFin(t, in: cg)
            case .wrapBack(let w): drawWrapBack(w, t, in: cg)
            default: break
            }
        }
    }

    func drawWing(_ kind: SlimeLook.Wings, _ t: TraitFrame, in cg: CGContext) {
        inTraitSpace(t, rotation: CGFloat(t.phase), in: cg) { cg in
            switch kind {
            case .bat, .dragon:
                // Shoulder at the origin, arm up to the wrist, three fingers fanning out, scalloped trailing edge.
                let span: CGFloat = kind == .dragon ? 1.15 : 1.0
                let wrist = CGPoint(x: 0.15 * span, y: 0.7 * span)
                let tips = [CGPoint(x: -0.1 * span, y: 1.25 * span), CGPoint(x: 0.55 * span, y: 1.05 * span), CGPoint(x: 0.85 * span, y: 0.55 * span)]
                let p = CGMutablePath()
                p.move(to: .zero)
                p.addQuadCurve(to: tips[0], control: CGPoint(x: -0.18 * span, y: 0.6 * span))
                p.addQuadCurve(to: tips[1], control: CGPoint(x: 0.3 * span, y: 0.88 * span))
                p.addQuadCurve(to: tips[2], control: CGPoint(x: 0.62 * span, y: 0.68 * span))
                p.addQuadCurve(to: CGPoint(x: 0.5 * span, y: -0.08 * span), control: CGPoint(x: 0.62 * span, y: 0.2 * span))
                p.closeSubpath()
                let membrane: RGBA = kind == .bat ? theme.ink.mixed(with: theme.deep, 0.35) : theme.deep
                fill(p, membrane, 0.96, in: cg)
                // Lighter inner membrane near the shoulder, darker toward the tips.
                fillRadial(p, [(membrane.mixed(with: theme.core, kind == .bat ? 0.3 : 0.4), 0), (membrane.opacity(0), 1)], center: CGPoint(x: 0.1 * span, y: 0.25 * span), radius: 1.0 * span, in: cg)
                let bones = CGMutablePath()
                bones.move(to: .zero)
                bones.addLine(to: wrist)
                for tip in tips {
                    bones.move(to: wrist)
                    bones.addQuadCurve(to: tip, control: CGPoint(x: (wrist.x + tip.x) * 0.5 - 0.03, y: (wrist.y + tip.y) * 0.5 + 0.04))
                }
                stroke(bones, kind == .bat ? theme.rim : theme.core, 0.6, width: hair(t, 1.4), in: cg)
                stroke(p, featureInk, 0.85, width: hair(t, 1.2), in: cg)
            case .fairy:
                // Two glassy petals growing out of the shoulder.
                let petals: [(CGPoint, CGFloat, CGFloat, CGFloat)] = [(CGPoint(x: -0.06, y: 0.5), 0.24, 0.52, -0.15), (CGPoint(x: 0.3, y: 0.22), 0.17, 0.3, 0.95)]
                for (c, rx, ry, rot) in petals {
                    var m = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: rot)
                    let ell = CGPath(ellipseIn: CGRect(x: -rx, y: -ry, width: 2 * rx, height: 2 * ry), transform: &m)
                    fillRadial(ell, [(RGBA.white.opacity(0.7), 0), (theme.core.opacity(0.35), 0.6), (theme.blush.opacity(0.3), 1)], center: CGPoint(x: c.x * 0.3, y: c.y * 0.3), radius: ry * 1.6, in: cg)
                    let veins = CGMutablePath()
                    for k in [-0.35, 0.0, 0.35] as [CGFloat] {
                        veins.move(to: .zero)
                        let tipP = CGPoint(x: c.x + (c.x * 0.9) * k * 0.6 - ry * sin(rot) * 0.9 * (1 + k * 0.3), y: c.y + ry * cos(rot) * 0.9 * (1 + k * 0.2))
                        veins.addQuadCurve(to: tipP, control: CGPoint(x: (c.x + tipP.x) * 0.5 + k * 0.1, y: (c.y + tipP.y) * 0.45))
                    }
                    stroke(veins, .white, 0.5, width: hair(t, 1.0), in: cg)
                    stroke(ell, .white, 0.85, width: hair(t, 1.1), in: cg)
                }
                fill(BodyPath.sparkle(center: CGPoint(x: -0.12, y: 0.78), radius: 0.09).cgPath, .white, 0.9, in: cg)
            case .none:
                break
            }
        }
    }

    func drawFin(_ t: TraitFrame, in cg: CGContext) {
        inTraitSpace(t, rotation: CGFloat(t.phase), in: cg) { cg in
            let p = CGMutablePath()
            p.move(to: .zero)
            p.addLine(to: CGPoint(x: -0.3, y: 0.58))
            p.addQuadCurve(to: CGPoint(x: 0, y: 0.38), control: CGPoint(x: -0.1, y: 0.42))
            p.addQuadCurve(to: CGPoint(x: 0.3, y: 0.58), control: CGPoint(x: 0.1, y: 0.42))
            p.closeSubpath()
            fill(p, theme.rim, 0.95, in: cg)
            let rays = CGMutablePath()
            for x in [-0.22, -0.11, 0.11, 0.22] as [CGFloat] {
                rays.move(to: CGPoint(x: 0, y: 0.05))
                rays.addLine(to: CGPoint(x: x, y: 0.5))
            }
            stroke(rays, theme.deep, 0.5, width: hair(t, 1.0), in: cg)
            stroke(p, featureInk, 0.8, width: hair(t, 1.1), in: cg)
        }
    }

    // MARK: Front layer

    func drawFrontTraits(in cg: CGContext) {
        for t in frame.traits {
            switch t.kind {
            case .horn(let h): drawHorn(h, t, in: cg)
            case .shard: drawShard(t, in: cg)
            case .earInner(let e): drawInnerEar(e, t, in: cg)
            case .antennaBall: drawAntennaBall(t, in: cg)
            case .tailTip(let k): drawTailTip(k, t, in: cg)
            case .gloss: drawGloss(t, in: cg)
            case .headwear(let h): drawHeadwear(h, t, in: cg)
            case .wrapFront(let w): drawWrapFront(w, t, in: cg)
            case .charm(let c): drawCharm(c, t, in: cg)
            case .wing, .fin, .wrapBack: break
            }
        }
    }

    func drawHorn(_ kind: SlimeLook.Horns, _ t: TraitFrame, in cg: CGContext) {
        inTraitSpace(t, in: cg) { cg in
            let p = CGMutablePath()
            switch kind {
            case .demonPair:
                // A crescent that curves outward to a point.
                p.move(to: CGPoint(x: -0.16, y: -0.02))
                p.addCurve(to: CGPoint(x: 0.42, y: 0.82), control1: CGPoint(x: -0.28, y: 0.44), control2: CGPoint(x: 0.08, y: 0.9))
                p.addCurve(to: CGPoint(x: 0.15, y: -0.02), control1: CGPoint(x: 0.36, y: 0.56), control2: CGPoint(x: 0.3, y: 0.14))
                p.closeSubpath()
                let hornInk = theme.isDark ? theme.ink.mixed(with: theme.deep, 0.5) : theme.ink.mixed(with: theme.deep, 0.3)
                celFill(p, hornInk, shadow: hornInk.mixed(with: .black, 0.35), split: 0.06, t, in: cg)
                let sheen = CGMutablePath()
                sheen.move(to: CGPoint(x: -0.07, y: 0.08))
                sheen.addQuadCurve(to: CGPoint(x: 0.2, y: 0.66), control: CGPoint(x: -0.06, y: 0.46))
                stroke(sheen, .white, 0.5, width: hair(t, 1.6), in: cg)
            case .dragonPair:
                p.move(to: CGPoint(x: -0.14, y: -0.02))
                p.addCurve(to: CGPoint(x: 0.38, y: 0.62), control1: CGPoint(x: -0.12, y: 0.35), control2: CGPoint(x: 0.15, y: 0.6))
                p.addCurve(to: CGPoint(x: 0.14, y: -0.02), control1: CGPoint(x: 0.28, y: 0.38), control2: CGPoint(x: 0.22, y: 0.12))
                p.closeSubpath()
                let bone = RGBA(hex: 0xEDE4D2).mixed(with: theme.core, 0.25)
                celFill(p, bone, shadow: bone.mixed(with: theme.deep, 0.5), split: 0.08, t, in: cg)
                let sheen = CGMutablePath()
                sheen.move(to: CGPoint(x: -0.05, y: 0.1))
                sheen.addQuadCurve(to: CGPoint(x: 0.2, y: 0.5), control: CGPoint(x: -0.02, y: 0.4))
                stroke(sheen, .white, 0.5, width: hair(t, 1.4), in: cg)
            case .oniSingle:
                p.move(to: CGPoint(x: -0.15, y: -0.02))
                p.addLine(to: CGPoint(x: 0, y: 0.64))
                p.addLine(to: CGPoint(x: 0.15, y: -0.02))
                p.closeSubpath()
                celFill(p, RGBA(hex: 0xFFF3DC), shadow: RGBA(hex: 0xC9B99C), split: 0.0, t, in: cg)
                let ridges = CGMutablePath()
                for (y, w) in [(0.18, 0.1), (0.34, 0.07)] as [(CGFloat, CGFloat)] {
                    ridges.move(to: CGPoint(x: -w, y: y))
                    ridges.addLine(to: CGPoint(x: w, y: y))
                }
                stroke(ridges, featureInk, 0.35, width: hair(t, 1.0), in: cg)
            case .unicorn:
                p.move(to: CGPoint(x: -0.13, y: -0.02))
                p.addLine(to: CGPoint(x: 0, y: 0.82))
                p.addLine(to: CGPoint(x: 0.13, y: -0.02))
                p.closeSubpath()
                let gold = theme.accent.mixed(with: RGBA(hex: 0xFFD36B), 0.6)
                celFill(p, gold, shadow: gold.mixed(with: RGBA(hex: 0x8A5A1E), 0.5), split: 0.0, t, in: cg)
                let twist = CGMutablePath()
                for y in [0.16, 0.34, 0.52] as [CGFloat] {
                    let w = 0.13 * (1 - y / 0.82)
                    twist.move(to: CGPoint(x: -w, y: y))
                    twist.addLine(to: CGPoint(x: w, y: y + 0.07))
                }
                stroke(twist, .white, 0.6, width: hair(t, 1.1), in: cg)
            case .none:
                break
            }
        }
    }

    func drawShard(_ t: TraitFrame, in cg: CGContext) {
        inTraitSpace(t, in: cg) { cg in
            let p = CGMutablePath()
            p.move(to: CGPoint(x: -0.15, y: -0.02))
            p.addLine(to: CGPoint(x: -0.09, y: 0.5))
            p.addLine(to: CGPoint(x: 0.0, y: 0.68))
            p.addLine(to: CGPoint(x: 0.1, y: 0.5))
            p.addLine(to: CGPoint(x: 0.15, y: -0.02))
            p.closeSubpath()
            celFill(p, theme.core.mixed(with: theme.mid, 0.3), shadow: theme.mid.mixed(with: theme.deep, 0.3), split: 0.0, t, in: cg)
            let facet = CGMutablePath()
            facet.move(to: CGPoint(x: 0, y: 0.68))
            facet.addLine(to: CGPoint(x: -0.03, y: 0.05))
            stroke(facet, .white, 0.6, width: hair(t, 1.0), in: cg)
            stroke(p, .white, 0.5, width: hair(t, 0.8), in: cg)
        }
    }

    func drawInnerEar(_ kind: SlimeLook.Ears, _ t: TraitFrame, in cg: CGContext) {
        inTraitSpace(t, in: cg) { cg in
            let ell = CGPath(ellipseIn: CGRect(x: -0.075, y: -0.14, width: 0.15, height: 0.28), transform: nil)
            let tone: RGBA = kind == .fox ? .white : theme.blush
            fillRadial(ell, [(tone.opacity(0.75), 0), (tone.opacity(0.35), 1)], center: CGPoint(x: 0, y: 0.06), radius: 0.16, in: cg)
        }
    }

    func drawAntennaBall(_ t: TraitFrame, in cg: CGContext) {
        let c = px(t.anchor)
        let r = 0.13 * R * CGFloat(t.scale)
        if look.surface == .electric {
            fillRadial(Self.ellipse(c, r * 2.6, r * 2.6), [(theme.accent.opacity(0.55), 0), (theme.accent.opacity(0), 1)], center: c, radius: r * 2.6, in: cg)
            fill(Self.ellipse(c, r * 0.55, r * 0.55), .white, 0.9, in: cg)
        } else {
            fill(Self.ellipse(CGPoint(x: c.x - r * 0.3, y: c.y - r * 0.35), r * 0.28, r * 0.22), .white, 0.85, in: cg)
        }
    }

    func drawTailTip(_ kind: SlimeLook.Tail, _ t: TraitFrame, in cg: CGContext) {
        switch kind {
        case .dragon:
            inTraitSpace(t, in: cg) { cg in
                let p = CGMutablePath()
                // A spade: two flared lobes and a point.
                p.move(to: CGPoint(x: 0, y: -0.1))
                p.addQuadCurve(to: CGPoint(x: -0.3, y: 0.24), control: CGPoint(x: -0.2, y: 0.02))
                p.addQuadCurve(to: CGPoint(x: -0.07, y: 0.26), control: CGPoint(x: -0.17, y: 0.3))
                p.addLine(to: CGPoint(x: 0, y: 0.58))
                p.addLine(to: CGPoint(x: 0.07, y: 0.26))
                p.addQuadCurve(to: CGPoint(x: 0.3, y: 0.24), control: CGPoint(x: 0.17, y: 0.3))
                p.addQuadCurve(to: CGPoint(x: 0, y: -0.1), control: CGPoint(x: 0.2, y: 0.02))
                p.closeSubpath()
                celFill(p, theme.deep.mixed(with: theme.mid, 0.3), shadow: theme.deep, split: 0.0, t, in: cg)
            }
        case .fox:
            let c = px(t.anchor)
            let r = 0.14 * R * CGFloat(t.scale)
            fillRadial(Self.ellipse(c, r, r * 1.1), [(RGBA.white, 0), (RGBA.white.opacity(0.85), 0.7), (theme.core.opacity(0.6), 1)], center: CGPoint(x: c.x - r * 0.2, y: c.y - r * 0.3), radius: r * 1.2, in: cg)
        default:
            break
        }
    }

    // MARK: Surfaces (inside the body clip, world space)

    func drawSurface(in cg: CGContext, bodyPath: CGPath) {
        guard look.surface != .plain else { return }
        let top = CGPoint(x: origin.x + CGFloat(frame.root.x) * R, y: origin.y + CGFloat(frame.topY) * R)
        let bottom = CGPoint(x: top.x, y: origin.y)
        let rich = detail >= .medium
        switch look.surface {
        case .plain:
            break
        case .fire:
            let hot = theme.accent.mixed(with: RGBA(hex: 0xFFE27A), 0.5)
            cg.drawLinearGradient(gradient([(hot.opacity(0.7), 0), (theme.accent.opacity(0.35), 0.45), (theme.accent.opacity(0), 1)]),
                                  start: top, end: bottom, options: [])
        case .electric:
            stroke(bodyPath, theme.accent, 0.55, width: 0.07 * R, in: cg)
            if rich {
                let n = frame.ring.count
                for k in 0..<2 {
                    let i = (Int(frame.time * 9) * 7 + k * 11) % n
                    let a = frame.ring[i], b = frame.ring[(i + 3) % n]
                    let mid = (a + b) / 2 + SIMD2(0.12 * sin(frame.time * 31 + Double(k)), -0.1)
                    let arc = CGMutablePath()
                    arc.move(to: px(a))
                    arc.addLine(to: px(mid))
                    arc.addLine(to: px(b))
                    stroke(arc, theme.accent, 0.6, width: max(1.5, 0.07 * R), in: cg)
                    stroke(arc, .white, 0.85, width: max(1, 0.03 * R), in: cg)
                }
            }
        case .crystal:
            stroke(bodyPath, .white, 0.4, width: 0.05 * R, in: cg)
            guard rich else { return }
            cg.saveGState()
            cg.concatenate(localTransform)
            let facets: [[CGPoint]] = [
                [CGPoint(x: -0.6, y: -1.5), CGPoint(x: -0.1, y: -1.75), CGPoint(x: 0.2, y: -1.1)],
                [CGPoint(x: 0.3, y: -1.6), CGPoint(x: 0.75, y: -1.1), CGPoint(x: 0.35, y: -0.7)],
                [CGPoint(x: -0.8, y: -0.9), CGPoint(x: -0.35, y: -1.2), CGPoint(x: -0.3, y: -0.5)],
                [CGPoint(x: 0.1, y: -0.9), CGPoint(x: 0.55, y: -0.5), CGPoint(x: 0, y: -0.25)],
            ]
            for f in facets {
                let p = CGMutablePath()
                p.addLines(between: f)
                p.closeSubpath()
                fill(p, .white, 0.12, in: cg)
                stroke(p, .white, 0.3, width: 1.4 / R, in: cg)
            }
            cg.restoreGState()
        case .ghost:
            cg.saveGState()
            cg.concatenate(localTransform)
            let drift = CGFloat(0.08 * sin(frame.time * 0.8))
            let c = CGPoint(x: bodyCenterLocal.x + drift, y: bodyCenterLocal.y + 0.1)
            fillRadial(CGPath(rect: CGRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4), transform: nil),
                       [(RGBA.white.opacity(0.25), 0), (RGBA.white.opacity(0), 1)], center: c, radius: 0.95, in: cg)
            cg.restoreGState()
        case .honey:
            cg.saveGState()
            cg.concatenate(localTransform)
            let c = bodyCenterLocal
            var m = CGAffineTransform(translationX: c.x, y: c.y - 0.45).rotated(by: -0.12)
            let band = CGPath(ellipseIn: CGRect(x: -0.78, y: -0.17, width: 1.56, height: 0.34), transform: &m)
            fill(band, .white, 0.3, in: cg)
            fillRadial(CGPath(rect: CGRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4), transform: nil),
                       [(theme.deep.opacity(0), 0), (theme.deep.opacity(0), 0.55), (theme.deep.opacity(0.4), 1)], center: CGPoint(x: c.x, y: c.y - 0.5), radius: 1.4, in: cg)
            cg.restoreGState()
        case .galaxy:
            cg.saveGState()
            cg.setFillColor(cgc(theme.deep, 0.45))
            cg.fill(CGRect(x: -1e5, y: -1e5, width: 2e5, height: 2e5))
            cg.concatenate(localTransform)
            let c = bodyCenterLocal
            let big = CGPath(rect: CGRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4), transform: nil)
            fillRadial(big, [(theme.accent.opacity(0.3), 0), (theme.accent.opacity(0), 1)], center: CGPoint(x: c.x + 0.3, y: c.y + 0.1), radius: 0.8, in: cg)
            fillRadial(big, [(theme.blush.opacity(0.22), 0), (theme.blush.opacity(0), 1)], center: CGPoint(x: c.x - 0.4, y: c.y - 0.35), radius: 0.6, in: cg)
            let count = rich ? 16 : 7
            for k in 0..<count {
                let a = Double(k) * 2.399
                let rad = 0.15 + 0.78 * (Double(k) * 0.618).truncatingRemainder(dividingBy: 1)
                let p = CGPoint(x: c.x + CGFloat(rad * cos(a)), y: c.y + CGFloat(rad * 0.85 * sin(a)))
                let tw = 0.45 + 0.55 * abs(sin(frame.time * (1.3 + Double(k % 3)) + Double(k)))
                let r = CGFloat(0.022 + 0.02 * Double(k % 3))
                fill(Self.ellipse(p, r, r), .white, tw, in: cg)
            }
            cg.restoreGState()
        case .bubble:
            cg.saveGState()
            cg.addPath(bodyPath)
            cg.setLineWidth(0.18 * R)
            cg.replacePathWithStrokedPath()
            cg.clip()
            let stops: [(RGBA, Double)] = [(RGBA(hex: 0xFF9AD5).opacity(0.5), 0), (RGBA(hex: 0xFFE27A).opacity(0.45), 0.33), (RGBA(hex: 0x7CF0FF).opacity(0.5), 0.66), (RGBA(hex: 0xC9A6FF).opacity(0.5), 1)]
            cg.drawLinearGradient(gradient(stops), start: CGPoint(x: top.x - R, y: top.y), end: CGPoint(x: bottom.x + R, y: bottom.y), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            cg.restoreGState()
        }
    }

    // MARK: Surface particles

    func drawSurfaceParticle(_ p: Particle, in cg: CGContext) {
        let c = px(p.position)
        let t = CGFloat(p.progress)
        let size = CGFloat(p.size) * R
        switch p.kind {
        case .wisp:
            let s = size * (1 - 0.45 * t)
            let hot = theme.accent.mixed(with: RGBA(hex: 0xFFE27A), 0.4)
            fill(BodyPath.teardrop(center: c, radius: s * 0.55).cgPath, theme.accent, 0.9 * (1 - t), in: cg)
            fill(BodyPath.teardrop(center: CGPoint(x: c.x, y: c.y + s * 0.15), radius: s * 0.28).cgPath, hot, 0.9 * (1 - t), in: cg)
        case .spark:
            let z = CGMutablePath()
            let d = size
            let sx = CGFloat(p.seed > 0.5 ? 1 : -1)
            z.move(to: c)
            z.addLine(to: CGPoint(x: c.x + 0.45 * d * sx, y: c.y - 0.35 * d))
            z.addLine(to: CGPoint(x: c.x + 0.25 * d * sx, y: c.y - 0.75 * d))
            z.addLine(to: CGPoint(x: c.x + 0.8 * d * sx, y: c.y - 1.1 * d))
            stroke(z, theme.accent, 0.8 * (1 - t), width: max(1.5, 0.06 * R), in: cg)
            stroke(z, .white, 0.95 * (1 - t), width: max(1, 0.025 * R), in: cg)
        case .glint:
            let s = size * sin(t * .pi)
            fill(BodyPath.sparkle(center: c, radius: s).cgPath, .white, 0.9, in: cg)
        case .drip:
            let s = size
            fill(BodyPath.teardrop(center: c, radius: s * 0.55).cgPath, theme.rim, 0.95 * (1 - t * t), in: cg)
            fill(Self.ellipse(CGPoint(x: c.x - s * 0.12, y: c.y - s * 0.02), s * 0.1, s * 0.12), .white, 0.7 * (1 - t), in: cg)
        case .bubble:
            let r = size * (1 + 0.3 * t)
            stroke(Self.ellipse(c, r, r), .white, 0.6 * (1 - t), width: max(1, 0.025 * R), in: cg)
            fill(Self.ellipse(CGPoint(x: c.x - r * 0.35, y: c.y - r * 0.35), r * 0.2, r * 0.2), .white, 0.8 * (1 - t), in: cg)
        default:
            break
        }
    }
}
