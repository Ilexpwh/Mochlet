import CoreGraphics
import Foundation
import simd
import SlimeKit

// Pseudopod arms, the props they hold, and the pages seen inside the jelly while it digests.
// The arms themselves are goo (blobs in the silhouette, shaded with the body); this file paints
// each lobe's own form over whatever it covers, so a hand can hide the face or hold a file.
extension SlimeCGRenderer {
    enum PropInk {
        static let card = RGBA(hex: 0xFFFDF7)
        static let cardEdge = RGBA(hex: 0xD9D3C7)
        static let line = RGBA(hex: 0x9AA3B2)
        static let pdf = RGBA(hex: 0xE5484D)
        static let doc = RGBA(hex: 0x3B82F6)
        static let folder = RGBA(hex: 0xF6C453)
        static let folderDark = RGBA(hex: 0xE0A82E)
        static let sky = RGBA(hex: 0xBFE3FF)
        static let hill = RGBA(hex: 0x5BBF6A)
        static let sun = RGBA(hex: 0xFFD54A)
        static let dark = RGBA(hex: 0x2B2F3A)
        static let screen = RGBA(hex: 0xDDF3FF)
        static let green = RGBA(hex: 0x34C759)
        static let mugWhite = RGBA(hex: 0xFFFFFF)
        static let coffee = RGBA(hex: 0x6B3F2A)
        static let pencil = RGBA(hex: 0xF9C846)
        static let eraser = RGBA(hex: 0xF08CA8)
        static let wood = RGBA(hex: 0xE8C9A0)
        static let steel = RGBA(hex: 0x8E95A3)
        static let steelDark = RGBA(hex: 0x4E5563)
        static let gold = RGBA(hex: 0xF5C542)
        static let goldDark = RGBA(hex: 0xC9962A)
        static let bookRed = RGBA(hex: 0xB83A3A)
        static let bookDark = RGBA(hex: 0x7E2727)
        static let pages = RGBA(hex: 0xF4EEDC)
        static let gift = RGBA(hex: 0xE94F64)
        static let ribbon = RGBA(hex: 0xFFE066)
        static let ink = RGBA(hex: 0x2A2F3A)
    }

    private var bodyScale: CGFloat { CGFloat((frame.body.scaleX * frame.body.scaleY).squareRoot()) }
    var inkLine: RGBA { material.inkLine }

    // MARK: Arms

    /// One arm as pixel geometry: the closed lobe (the centre line stroked with round joins, so
    /// a tight elbow folds cleanly, plus the round hand), the hand's radius and the shoulder disk
    /// where nothing is drawn.
    private struct Lobe {
        let arm: ArmFrame
        let tube: CGPath
        let hole: CGFloat
        let handR: CGFloat

        init(_ r: SlimeCGRenderer, _ a: ArmFrame, bodyScale: Double) {
            arm = a
            let n = 24
            let t0 = -0.03
            var centre: [CGPoint] = []
            for k in 0...n {
                let t = t0 + (1 - t0) * Double(k) / Double(n)
                centre.append(r.px(ArmRig.centre(a, t)))
            }
            let line = CGMutablePath()
            line.addLines(between: centre)
            let w = CGFloat(ArmRig.halfWidth(a, 0, bodyScale: bodyScale)) * r.R
            var shape = line.copy(strokingWithWidth: 2 * w, lineCap: .round, lineJoin: .round, miterLimit: 1).normalized(using: .winding)
            let hr = CGFloat(a.handRadius * a.reach * bodyScale) * r.R
            let h = r.px(a.hand)
            shape = shape.union(SlimeCGRenderer.ellipse(h, hr, hr), using: .winding)
            // A thumb nub or a pointing finger: a capsule merged into the lobe.
            let digit = ArmRig.digit(a)
            let finger = CGMutablePath()
            switch a.shape {
            case .thumbsUp:
                finger.move(to: CGPoint(x: h.x + hr * 0.5 * CGFloat(digit.x), y: h.y + hr * 0.5 * CGFloat(digit.y)))
                finger.addLine(to: CGPoint(x: h.x + hr * 1.15 * CGFloat(digit.x), y: h.y + hr * 1.15 * CGFloat(digit.y)))
                shape = shape.union(finger.copy(strokingWithWidth: hr * 0.7, lineCap: .round, lineJoin: .round, miterLimit: 1), using: .winding)
            case .point:
                finger.move(to: h)
                finger.addLine(to: CGPoint(x: h.x + hr * 1.5 * CGFloat(digit.x), y: h.y + hr * 1.5 * CGFloat(digit.y)))
                shape = shape.union(finger.copy(strokingWithWidth: hr * 0.8, lineCap: .round, lineJoin: .round, miterLimit: 1), using: .winding)
            default:
                break
            }
            tube = shape
            hole = CGFloat(0.3 * a.reach * bodyScale) * r.R
            handR = hr
        }
    }

    /// Arms are body material: the engine adds them to the goo as blobs, so the silhouette and
    /// the one-pass jelly shading already include them. This pass gives each lobe its own form
    /// where it lies over the body or a held prop: the jelly tone again (so a hand covers the
    /// face or the edge of a file), a cel shadow along its underside, a soft contact shadow and
    /// an ink line along its edge over the body, and a specular on the hand. Nothing is drawn
    /// around the shoulder, where the lobe simply grows out of the jelly.
    func drawArms(in cg: CGContext, bodyPath: CGPath) {
        guard !frame.arms.isEmpty else { return }
        let bs = bodyScale
        let lobes = frame.arms.filter { $0.reach > 0.03 }.map { Lobe(self, $0, bodyScale: Double(bs)) }
        guard !lobes.isEmpty else { return }
        // The body proper: the ring without its goo. A lobe over it (or over the other arm) gets
        // its edge drawn; a lobe in the air is already outlined by the silhouette.
        let ring = BodyPath.closed(through: frame.ring.map(px)).cgPath
        let huge = CGPath(rect: CGRect(x: -1e5, y: -1e5, width: 2e5, height: 2e5), transform: nil)
        let lineW = max(1.0, 0.025 * R)
        let shift = CGAffineTransform(translationX: -0.06 * R * bs, y: -0.09 * R * bs)
        let boxes = lobes.map { $0.tube.boundingBoxOfPath.insetBy(dx: -0.1 * R, dy: -0.1 * R) }
        var overlapping = false
        for i in boxes.indices { for k in boxes.indices where k > i && boxes[i].intersects(boxes[k]) { overlapping = true } }

        // 1. The jelly inside the lobe, clipped to the silhouette: the shell tone, the inner
        //    tone along its underside (the band not covered by a copy of the lobe shifted toward
        //    the light, as the core flows into the pseudopod) and a thin band of reflected light.
        func jelly(_ lobe: Lobe, in cg: CGContext) {
            cg.saveGState()
            cg.addPath(lobe.tube)
            cg.clip()
            fill(lobe.tube, material.shell, in: cg)
            var m = shift
            if let lit = lobe.tube.copy(using: &m) {
                cg.saveGState()
                cg.addPath(huge)
                cg.addPath(lit)
                cg.clip(using: .evenOdd)
                fill(lobe.tube, material.inner, 0.55, in: cg)
                cg.restoreGState()
            }
            if detail >= .medium { stroke(lobe.tube, material.rimLight, width: 0.06 * R, in: cg) }
            cg.restoreGState()
        }
        // 2. Over the body (or the other arm): a contact shadow just outside the lobe and the
        //    ink line along its edge, both fading out toward the shoulder, where the lobe simply
        //    grows out of the jelly.
        func edge(_ i: Int, _ lobe: Lobe, in cg: CGContext) {
            let a = lobe.arm
            cg.saveGState()
            cg.addPath(ring)
            for (k, other) in lobes.enumerated() where k != i && boxes[k].intersects(boxes[i]) { cg.addPath(other.tube) }
            cg.clip()
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
            cg.saveGState()
            cg.addPath(huge)
            cg.addPath(lobe.tube)
            cg.clip(using: .evenOdd)
            stroke(lobe.tube, deep, 0.2, width: 0.16 * R * bs, in: cg)
            cg.restoreGState()
            stroke(lobe.tube, inkLine, 0.9, width: lineW, in: cg)
            cg.setBlendMode(.destinationOut)
            let sh = px(a.shoulder)
            cg.drawRadialGradient(gradient([(.white, 0), (.white, 0.3), (RGBA.white.opacity(0), 1)]),
                                  startCenter: sh, startRadius: 0, endCenter: sh, endRadius: lobe.hole * 2.2, options: [])
            cg.endTransparencyLayer()
            cg.restoreGState()
        }
        // 3. A specular on the hand, like the one on the head.
        func specular(_ lobe: Lobe, in cg: CGContext) {
            guard detail >= .medium else { return }
            let h = px(lobe.arm.hand), hr = lobe.handR
            var t = CGAffineTransform(translationX: h.x - hr * 0.3, y: h.y - hr * 0.38).rotated(by: -0.55)
            let ell = CGPath(ellipseIn: CGRect(x: -hr * 0.3, y: -hr * 0.15, width: hr * 0.6, height: hr * 0.3), transform: &t)
            fill(ell, theme.highlight, 0.9, in: cg)
        }

        if overlapping {
            // Crossed arms (a hug): each lobe's edge goes on before the next lobe's jelly covers it.
            for (i, lobe) in lobes.enumerated() {
                cg.saveGState()
                cg.addPath(bodyPath)
                cg.clip(using: .evenOdd)
                jelly(lobe, in: cg)
                cg.restoreGState()
                edge(i, lobe, in: cg)
                specular(lobe, in: cg)
            }
        } else {
            // Apart: one silhouette clip serves every lobe.
            cg.saveGState()
            cg.addPath(bodyPath)
            cg.clip(using: .evenOdd)
            for lobe in lobes { jelly(lobe, in: cg) }
            cg.restoreGState()
            for (i, lobe) in lobes.enumerated() {
                edge(i, lobe, in: cg)
                specular(lobe, in: cg)
            }
        }
    }

    // MARK: Props

    func drawProps(behindHands: Bool, in cg: CGContext) {
        for p in frame.props where p.behindHands == behindHands && p.scale > 0.02 {
            let c = px(p.position)
            cg.saveGState()
            cg.translateBy(x: c.x, y: c.y)
            cg.rotate(by: CGFloat(p.angle))
            let u = R * CGFloat(p.scale) * bodyScale
            cg.scaleBy(x: u, y: u)
            drawProp(p.prop, in: cg)
            cg.restoreGState()
        }
    }

    /// Prop space: origin at the prop's centre, 1 = R, y down, no larger than about 0.9 R.
    private func drawProp(_ prop: Prop, in cg: CGContext) {
        let lw: CGFloat = max(0.035, 1.1 / max(R, 1))
        func outline(_ path: CGPath) { stroke(path, PropInk.ink, 0.85, width: lw, in: cg) }
        func rrect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
            CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
        }
        let rich = detail >= .medium
        switch prop {
        case .file(let kind, let bites):
            cg.scaleBy(x: 0.8, y: 0.8)
            if kind == .folder {
                let body = rrect(-0.4, -0.22, 0.8, 0.5, 0.06)
                let tab = rrect(-0.4, -0.32, 0.34, 0.16, 0.05)
                clipBites(bites, top: -0.32, height: 0.6, width: 0.8, in: cg)
                fill(tab, PropInk.folderDark, in: cg)
                fill(body, PropInk.folder, in: cg)
                fill(rrect(-0.4, -0.14, 0.8, 0.42, 0.06), PropInk.folder.mixed(with: .white, 0.18), in: cg)
                outline(body)
                return
            }
            // A card with a folded corner.
            clipBites(bites, top: -0.45, height: 0.9, width: 0.7, in: cg)
            let card = CGMutablePath()
            card.move(to: CGPoint(x: -0.35, y: -0.45))
            card.addLine(to: CGPoint(x: 0.17, y: -0.45))
            card.addLine(to: CGPoint(x: 0.35, y: -0.27))
            card.addLine(to: CGPoint(x: 0.35, y: 0.45))
            card.addLine(to: CGPoint(x: -0.35, y: 0.45))
            card.closeSubpath()
            fill(card, PropInk.card, in: cg)
            let fold = CGMutablePath()
            fold.move(to: CGPoint(x: 0.17, y: -0.45))
            fold.addLine(to: CGPoint(x: 0.17, y: -0.27))
            fold.addLine(to: CGPoint(x: 0.35, y: -0.27))
            fill(fold, PropInk.cardEdge, in: cg)
            if rich {
                switch kind {
                case .doc, .text:
                    for k in 0..<4 {
                        let y = -0.12 + CGFloat(k) * 0.13
                        let wline: CGFloat = k == 3 ? 0.3 : 0.5
                        fill(rrect(-0.25, y, wline, 0.05, 0.025), kind == .doc ? PropInk.doc.opacity(0.7) : PropInk.line, in: cg)
                    }
                case .pdf:
                    fill(rrect(-0.35, 0.02, 0.7, 0.2, 0.0), PropInk.pdf, in: cg)
                    for k in 0..<3 { fill(rrect(-0.22 + CGFloat(k) * 0.16, 0.06, 0.1, 0.12, 0.02), .white, in: cg) }
                case .image:
                    fill(rrect(-0.27, -0.2, 0.54, 0.5, 0.03), PropInk.sky, in: cg)
                    fill(Self.ellipse(CGPoint(x: 0.12, y: -0.06), 0.07, 0.07), PropInk.sun, in: cg)
                    let hill = CGMutablePath()
                    hill.move(to: CGPoint(x: -0.27, y: 0.3))
                    hill.addLine(to: CGPoint(x: -0.05, y: 0.02))
                    hill.addLine(to: CGPoint(x: 0.1, y: 0.18))
                    hill.addLine(to: CGPoint(x: 0.2, y: 0.08))
                    hill.addLine(to: CGPoint(x: 0.27, y: 0.3))
                    hill.closeSubpath()
                    fill(hill, PropInk.hill, in: cg)
                case .audio:
                    for k in 0..<6 {
                        let hgt: CGFloat = [0.12, 0.3, 0.2, 0.38, 0.16, 0.26][k]
                        fill(rrect(-0.24 + CGFloat(k) * 0.09, 0.1 - hgt / 2, 0.05, hgt, 0.025), PropInk.doc, in: cg)
                    }
                case .video:
                    fill(rrect(-0.27, -0.16, 0.54, 0.44, 0.04), PropInk.dark, in: cg)
                    let tri = CGMutablePath()
                    tri.move(to: CGPoint(x: -0.08, y: -0.06))
                    tri.addLine(to: CGPoint(x: 0.12, y: 0.06))
                    tri.addLine(to: CGPoint(x: -0.08, y: 0.18))
                    tri.closeSubpath()
                    fill(tri, .white, in: cg)
                case .link:
                    let globe = Self.ellipse(CGPoint(x: 0, y: 0.08), 0.2, 0.2)
                    fill(globe, PropInk.sky, in: cg)
                    stroke(globe, PropInk.doc, 0.9, width: 0.03, in: cg)
                    stroke(Self.ellipse(CGPoint(x: 0, y: 0.08), 0.09, 0.2), PropInk.doc, 0.9, width: 0.025, in: cg)
                    let eq = CGMutablePath()
                    eq.move(to: CGPoint(x: -0.2, y: 0.08)); eq.addLine(to: CGPoint(x: 0.2, y: 0.08))
                    stroke(eq, PropInk.doc, 0.9, width: 0.025, in: cg)
                case .folder:
                    break
                }
            }
            outline(card)
        case .page:
            let sheet = rrect(-0.22, -0.28, 0.44, 0.56, 0.02)
            fill(sheet, PropInk.card, in: cg)
            if rich { for k in 0..<3 { fill(rrect(-0.14, -0.14 + CGFloat(k) * 0.12, k == 2 ? 0.18 : 0.28, 0.04, 0.02), PropInk.line, in: cg) } }
            outline(sheet)
        case .book:
            let cover = rrect(-0.3, -0.38, 0.6, 0.76, 0.03)
            fill(cover, PropInk.bookRed, in: cg)
            fill(rrect(-0.3, -0.38, 0.1, 0.76, 0.03), PropInk.bookDark, in: cg)
            fill(rrect(-0.16, -0.38, 0.46, 0.06, 0.0), PropInk.pages, in: cg)
            if rich { fill(rrect(-0.1, -0.1, 0.3, 0.05, 0.02), PropInk.ribbon, in: cg) }
            outline(cover)
        case .phone:
            let body = rrect(-0.17, -0.32, 0.34, 0.64, 0.07)
            fill(body, PropInk.dark, in: cg)
            fill(rrect(-0.14, -0.27, 0.28, 0.54, 0.04), PropInk.screen, in: cg)
            if rich {
                fill(Self.ellipse(CGPoint(x: 0, y: 0.14), 0.07, 0.07), PropInk.green, in: cg)
                let wave = CGMutablePath()
                wave.move(to: CGPoint(x: -0.09, y: -0.08))
                wave.addCurve(to: CGPoint(x: 0.09, y: -0.08), control1: CGPoint(x: -0.04, y: -0.2), control2: CGPoint(x: 0.04, y: 0.04))
                stroke(wave, PropInk.green, 0.9, width: 0.03, in: cg)
            }
            outline(body)
        case .mug:
            let cup = rrect(-0.22, -0.2, 0.44, 0.42, 0.06)
            let handle = CGMutablePath()
            handle.addArc(center: CGPoint(x: 0.22, y: 0.0), radius: 0.12, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false)
            stroke(handle, PropInk.ink, 0.85, width: 0.1 + lw, in: cg)
            stroke(handle, PropInk.mugWhite, 1, width: 0.1, in: cg)
            fill(cup, PropInk.mugWhite, in: cg)
            fill(Self.ellipse(CGPoint(x: 0, y: -0.2), 0.2, 0.05), PropInk.coffee, in: cg)
            if rich {
                fill(rrect(-0.22, 0.05, 0.44, 0.06, 0.0), theme.mid.opacity(0.8), in: cg)
                for sx in [-0.08, 0.06] as [CGFloat] {
                    let steam = CGMutablePath()
                    steam.move(to: CGPoint(x: sx, y: -0.26))
                    steam.addCurve(to: CGPoint(x: sx + 0.02, y: -0.48), control1: CGPoint(x: sx - 0.08, y: -0.34), control2: CGPoint(x: sx + 0.1, y: -0.4))
                    stroke(steam, .white, 0.55, width: 0.03, in: cg)
                }
            }
            outline(cup)
        case .pen:
            let shaft = rrect(-0.055, -0.3, 0.11, 0.5, 0.0)
            fill(shaft, PropInk.pencil, in: cg)
            fill(rrect(-0.055, -0.36, 0.11, 0.08, 0.03), PropInk.eraser, in: cg)
            let tip = CGMutablePath()
            tip.move(to: CGPoint(x: -0.055, y: 0.2))
            tip.addLine(to: CGPoint(x: 0.055, y: 0.2))
            tip.addLine(to: CGPoint(x: 0, y: 0.34))
            tip.closeSubpath()
            fill(tip, PropInk.wood, in: cg)
            let lead = CGMutablePath()
            lead.move(to: CGPoint(x: -0.02, y: 0.29)); lead.addLine(to: CGPoint(x: 0.02, y: 0.29)); lead.addLine(to: CGPoint(x: 0, y: 0.34)); lead.closeSubpath()
            fill(lead, PropInk.ink, in: cg)
            let whole = CGMutablePath()
            whole.addPath(rrect(-0.055, -0.36, 0.11, 0.56, 0.03)); whole.addPath(tip)
            outline(rrect(-0.055, -0.36, 0.11, 0.56, 0.03))
            outline(tip)
        case .magnifier:
            let glass = Self.ellipse(CGPoint(x: -0.06, y: -0.08), 0.2, 0.2)
            fill(glass, PropInk.sky, 0.45, in: cg)
            stroke(glass, PropInk.steelDark, 1, width: 0.06, in: cg)
            let handle = CGMutablePath()
            handle.move(to: CGPoint(x: 0.08, y: 0.06)); handle.addLine(to: CGPoint(x: 0.26, y: 0.3))
            stroke(handle, PropInk.ink, 0.85, width: 0.1 + lw, in: cg)
            stroke(handle, PropInk.steelDark, 1, width: 0.1, in: cg)
            if rich { fill(Self.ellipse(CGPoint(x: -0.13, y: -0.15), 0.05, 0.03), .white, 0.8, in: cg) }
        case .mic:
            let head = rrect(-0.13, -0.3, 0.26, 0.36, 0.13)
            let handle = rrect(-0.05, 0.02, 0.1, 0.3, 0.04)
            fill(handle, PropInk.steelDark, in: cg)
            fill(head, PropInk.steel, in: cg)
            if rich {
                for k in 0..<3 {
                    let y = -0.24 + CGFloat(k) * 0.1
                    let line = CGMutablePath(); line.move(to: CGPoint(x: -0.11, y: y)); line.addLine(to: CGPoint(x: 0.11, y: y))
                    stroke(line, PropInk.steelDark, 0.6, width: 0.02, in: cg)
                }
                fill(Self.ellipse(CGPoint(x: -0.05, y: -0.22), 0.04, 0.03), .white, 0.7, in: cg)
            }
            outline(head)
            outline(handle)
        case .bell:
            let bell = CGMutablePath()
            bell.move(to: CGPoint(x: -0.26, y: 0.16))
            bell.addQuadCurve(to: CGPoint(x: -0.17, y: -0.02), control: CGPoint(x: -0.17, y: 0.12))
            bell.addCurve(to: CGPoint(x: 0.17, y: -0.02), control1: CGPoint(x: -0.17, y: -0.36), control2: CGPoint(x: 0.17, y: -0.36))
            bell.addQuadCurve(to: CGPoint(x: 0.26, y: 0.16), control: CGPoint(x: 0.17, y: 0.12))
            bell.closeSubpath()
            fill(bell, PropInk.gold, in: cg)
            fill(rrect(-0.26, 0.1, 0.52, 0.07, 0.03), PropInk.goldDark, in: cg)
            fill(Self.ellipse(CGPoint(x: 0, y: 0.2), 0.05, 0.05), PropInk.goldDark, in: cg)
            fill(Self.ellipse(CGPoint(x: 0, y: -0.26), 0.04, 0.04), PropInk.goldDark, in: cg)
            if rich { fill(Self.ellipse(CGPoint(x: -0.08, y: -0.12), 0.04, 0.07), .white, 0.65, in: cg) }
            outline(bell)
        case .mask:
            let face = Self.ellipse(.zero, 0.28, 0.34)
            fill(face, .white, in: cg)
            for sx in [-0.11, 0.11] as [CGFloat] { fill(Self.ellipse(CGPoint(x: sx, y: -0.08), 0.06, 0.05), PropInk.ink, in: cg) }
            let smile = CGMutablePath()
            smile.move(to: CGPoint(x: -0.1, y: 0.1)); smile.addQuadCurve(to: CGPoint(x: 0.1, y: 0.1), control: CGPoint(x: 0, y: 0.2))
            stroke(smile, PropInk.ink, 0.9, width: 0.03, in: cg)
            if rich { fill(Self.ellipse(CGPoint(x: -0.16, y: 0.06), 0.04, 0.025), theme.blush, 0.8, in: cg); fill(Self.ellipse(CGPoint(x: 0.16, y: 0.06), 0.04, 0.025), theme.blush, 0.8, in: cg) }
            outline(face)
        case .heart:
            let h = BodyPath.heart(center: .zero, size: 0.42).cgPath
            fill(h, theme.blush, in: cg)
            if rich { fill(Self.ellipse(CGPoint(x: -0.1, y: -0.1), 0.05, 0.035), .white, 0.8, in: cg) }
            outline(h)
        case .gift:
            let box = rrect(-0.28, -0.14, 0.56, 0.42, 0.03)
            fill(box, PropInk.gift, in: cg)
            fill(rrect(-0.3, -0.2, 0.6, 0.12, 0.03), PropInk.gift.mixed(with: .white, 0.15), in: cg)
            fill(rrect(-0.05, -0.2, 0.1, 0.48, 0.0), PropInk.ribbon, in: cg)
            fill(rrect(-0.3, -0.17, 0.6, 0.07, 0.0), PropInk.ribbon, in: cg)
            if rich {
                for sx in [-1.0, 1.0] as [CGFloat] { fill(Self.ellipse(CGPoint(x: sx * 0.08, y: -0.26), 0.08, 0.05), PropInk.ribbon, in: cg) }
            }
            outline(box)
        }
    }

    /// Removes the eaten part of a card: everything above the bite line, with a scalloped edge.
    private func clipBites(_ bites: Double, top: CGFloat, height: CGFloat, width: CGFloat, in cg: CGContext) {
        guard bites > 0.001 else { return }
        let line = top + height * CGFloat(min(1, bites))
        // The kept part: from a scalloped bite line down to below the card.
        let keep = CGMutablePath()
        let r = width * 0.16
        keep.move(to: CGPoint(x: -width, y: line))
        var x = -width / 2 + r * 0.6
        var k = 0
        while x + 2 * r <= width / 2 + r * 0.6 {
            keep.addLine(to: CGPoint(x: x, y: line))
            keep.addQuadCurve(to: CGPoint(x: x + 2 * r, y: line), control: CGPoint(x: x + r, y: line + r * (k % 2 == 0 ? 1.7 : 1.2)))
            x += 2 * r
            k += 1
        }
        keep.addLine(to: CGPoint(x: width, y: line))
        keep.addLine(to: CGPoint(x: width, y: top + height + 0.2))
        keep.addLine(to: CGPoint(x: -width, y: top + height + 0.2))
        keep.closeSubpath()
        cg.addPath(keep)
        cg.clip()
    }

    // MARK: Inside the jelly

    func drawInnerItems(in cg: CGContext) {
        for item in frame.innerItems where item.opacity > 0.01 {
            let c = px(item.position)
            cg.saveGState()
            cg.translateBy(x: c.x, y: c.y)
            cg.rotate(by: CGFloat(item.angle))
            let u = R * CGFloat(item.size)
            cg.scaleBy(x: u, y: u)
            switch item.kind {
            case .page:
                let sheet = CGPath(roundedRect: CGRect(x: -0.5, y: -0.65, width: 1, height: 1.3), cornerWidth: 0.05, cornerHeight: 0.05, transform: nil)
                fill(sheet, PropInk.card, 0.62 * item.opacity, in: cg)
                for k in 0..<4 {
                    fill(CGPath(rect: CGRect(x: -0.32, y: -0.38 + CGFloat(k) * 0.24, width: k == 3 ? 0.4 : 0.64, height: 0.09), transform: nil), PropInk.line, 0.5 * item.opacity, in: cg)
                }
            }
            cg.restoreGState()
        }
    }
}
