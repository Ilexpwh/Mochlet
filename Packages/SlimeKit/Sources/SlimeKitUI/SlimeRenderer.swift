import SwiftUI
import simd
import SlimeKit

/// Pure function of a `SlimeFrame`: draws one slime into a GraphicsContext.
/// `origin` is the pixel position of the contact point (centre bottom), `R` the pixels per unit.
public struct SlimeRenderer {
    public let frame: SlimeFrame
    public let theme: SlimeTheme
    public let origin: CGPoint
    public let R: CGFloat

    private let rim: RGBA
    private let deep: RGBA
    private let mid: RGBA
    private let core: RGBA

    public init(frame: SlimeFrame, theme: SlimeTheme, origin: CGPoint, radius: CGFloat) {
        self.frame = frame
        self.theme = theme
        self.origin = origin
        self.R = radius
        let t = frame.tint
        rim = theme.rim.mixed(with: t.color, t.opacity).desaturated(t.desaturation)
        deep = theme.deep.mixed(with: t.color, t.opacity * 0.8).desaturated(t.desaturation)
        mid = theme.mid.mixed(with: t.color, t.opacity * 0.6).desaturated(t.desaturation)
        core = theme.core.desaturated(t.desaturation)
    }

    public static func draw(_ frame: SlimeFrame, theme: SlimeTheme, in ctx: inout GraphicsContext, origin: CGPoint, radius: CGFloat) {
        SlimeRenderer(frame: frame, theme: theme, origin: origin, radius: radius).draw(in: &ctx)
    }

    // MARK: Coordinates

    @inline(__always) func px(_ v: SIMD2<Double>) -> CGPoint {
        CGPoint(x: origin.x + CGFloat(v.x) * R, y: origin.y + CGFloat(v.y) * R)
    }

    /// Transform mapping reference-local R units to pixels through the body's affine fit.
    var localTransform: CGAffineTransform {
        let a = frame.body.matrix
        let t = frame.body.origin - a * frame.body.referenceCentroid
        return CGAffineTransform(a: R * a.columns.0.x, b: R * a.columns.0.y,
                                 c: R * a.columns.1.x, d: R * a.columns.1.y,
                                 tx: origin.x + R * t.x, ty: origin.y + R * t.y)
    }

    var bodyCenterLocal: CGPoint {
        CGPoint(x: frame.body.referenceCentroid.x, y: frame.body.referenceCentroid.y)
    }

    func color(_ c: RGBA, _ opacity: Double = 1) -> GraphicsContext.Shading {
        .color(Color(c.opacity(opacity)))
    }

    // MARK: Draw

    public func draw(in context: inout GraphicsContext) {
        var ctx = context
        ctx.opacity = frame.opacity
        if frame.profile == .ghost {
            let c = px(frame.body.origin)
            ctx.translateBy(x: c.x, y: c.y)
            ctx.rotate(by: .radians(frame.ghostHeading))
            ctx.scaleBy(x: frame.ghostStretch.x, y: frame.ghostStretch.y)
            ctx.rotate(by: .radians(-frame.ghostHeading))
            ctx.translateBy(x: -c.x, y: -c.y)
        }
        let pts = frame.ring.map(px)
        let bodyPath = BodyPath.closed(through: pts)
        drawGlow(in: &ctx)
        if frame.blobs.isEmpty {
            drawBodyFill(in: &ctx, bodyPath: bodyPath)
        } else {
            drawMetaballBody(in: &ctx, bodyPath: bodyPath)
        }
        drawFace(in: &ctx, bodyPath: bodyPath)
        drawAccessories(in: &ctx)
        drawParticles(in: &ctx)
    }

    // 1. Floor contact glow (the notch is black, so no dark shadow).
    func drawGlow(in ctx: inout GraphicsContext) {
        guard frame.profile != .ghost else { return }
        let lift = max(0, -frame.root.y)
        let fade = 1 - smoothstep(0, 0.9, lift)
        guard fade > 0.01 else { return }
        let w = (CGFloat(frame.contactWidth) + 0.5) * R * (1 + 0.4 * CGFloat(frame.glowBoost))
        let hgt = 0.16 * R
        let cx = origin.x + CGFloat(frame.root.x) * R
        let rect = CGRect(x: cx - w / 2, y: origin.y - hgt / 2, width: w, height: hgt)
        let stops = [Gradient.Stop(color: Color(mid.opacity(0.22 * fade * (1 + 0.6 * frame.glowBoost))), location: 0),
                     Gradient.Stop(color: Color(mid.opacity(0)), location: 1)]
        ctx.fill(Path(ellipseIn: rect), with: .radialGradient(Gradient(stops: stops), center: CGPoint(x: rect.midX, y: rect.midY), startRadius: 0, endRadius: w / 2))
    }

    // 2–6. The jelly: gradient fill, lagging core, rim darkening, inner stroke, highlights.
    func drawBodyFill(in ctx: inout GraphicsContext, bodyPath: Path) {
        var lc = ctx
        lc.clip(to: bodyPath)
        lc.concatenate(localTransform)
        let c = bodyCenterLocal
        let big = CGRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7)
        // Body gradient centred up-left of the centre.
        let gc = CGPoint(x: c.x - 0.35, y: c.y - 0.40)
        let fill = Gradient(stops: [.init(color: Color(core), location: 0), .init(color: Color(mid), location: 0.55), .init(color: Color(rim), location: 1)])
        lc.fill(Path(big), with: .radialGradient(fill, center: gc, startRadius: 0, endRadius: 1.35))
        // Rim darkening toward the silhouette.
        let rimG = Gradient(stops: [.init(color: Color(deep.opacity(0)), location: 0.62), .init(color: Color(deep.opacity(0.35)), location: 1)])
        lc.fill(Path(big), with: .radialGradient(rimG, center: c, startRadius: 0, endRadius: 1.02))
        // Bottom-right bounce light.
        let bounce = Gradient(stops: [.init(color: Color(mid.opacity(0.28)), location: 0), .init(color: Color(mid.opacity(0)), location: 1)])
        lc.fill(Path(big), with: .radialGradient(bounce, center: CGPoint(x: c.x + 0.45, y: c.y + 0.42), startRadius: 0, endRadius: 0.65))
        // Inner core that sloshes (world space, clipped).
        var cc = ctx
        cc.clip(to: bodyPath)
        let coreCenter = px(frame.core)
        let sx = CGFloat(frame.body.scaleX) * CGFloat(frame.sizeScale == 0 ? 1 : 1)
        let sy = CGFloat(frame.body.scaleY)
        let cw = 0.62 * R * sx
        let ch = 0.50 * R * sy
        let boost = CGFloat(frame.coreBoost)
        let coreG = Gradient(stops: [.init(color: Color(core.opacity(0.55 + 0.35 * boost)), location: 0), .init(color: Color(core.opacity(0)), location: 1)])
        cc.fill(Path(ellipseIn: CGRect(x: coreCenter.x - cw, y: coreCenter.y - ch, width: 2 * cw, height: 2 * ch)),
                with: .radialGradient(coreG, center: coreCenter, startRadius: 0, endRadius: max(cw, ch)))
        // Inner stroke (half clipped away).
        cc.stroke(bodyPath, with: color(.white, 0.25), lineWidth: 0.08 * R)
        // Specular highlights, shifted against the gaze.
        let shift = CGPoint(x: frame.highlightShift.x, y: frame.highlightShift.y)
        if frame.profile != .mini {
            let hc = CGPoint(x: c.x - 0.36 + shift.x, y: c.y - 0.44 + shift.y)
            let ell = Path(ellipseIn: CGRect(x: -0.30, y: -0.18, width: 0.60, height: 0.36))
                .applying(CGAffineTransform(rotationAngle: -35 * .pi / 180))
                .applying(CGAffineTransform(translationX: hc.x, y: hc.y))
            lc.fill(ell, with: color(theme.highlight, 0.85))
        }
        let dc = CGPoint(x: c.x - 0.18 + shift.x * 0.7, y: c.y - 0.62 + shift.y * 0.7)
        let dr: CGFloat = frame.profile == .mini ? 0.11 : 0.07
        lc.fill(Path(ellipseIn: CGRect(x: dc.x - dr, y: dc.y - dr, width: 2 * dr, height: 2 * dr)), with: color(theme.highlight, 0.95))
    }

    /// Same jelly but drawn over the union of the body and the extra blobs (split, pinch, merge).
    func drawMetaballBody(in ctx: inout GraphicsContext, bodyPath: Path) {
        let blobPaths: [Path] = frame.blobs.map { b in
            let c = px(b.position)
            let r = CGFloat(b.radius) * R
            let s = CGFloat(max(0.2, b.stretch))
            return Path(ellipseIn: CGRect(x: -r * s, y: -r / s, width: 2 * r * s, height: 2 * r / s))
                .applying(CGAffineTransform(rotationAngle: CGFloat(b.heading)))
                .applying(CGAffineTransform(translationX: c.x, y: c.y))
        }
        ctx.drawLayer { layer in
            layer.drawLayer { inner in
                inner.addFilter(.alphaThreshold(min: 0.5, color: Color(mid)))
                inner.addFilter(.blur(radius: 0.12 * R))
                inner.fill(bodyPath, with: .color(.white))
                for p in blobPaths { inner.fill(p, with: .color(.white)) }
            }
            layer.blendMode = .sourceAtop
            var lc = layer
            lc.concatenate(localTransform)
            let c = bodyCenterLocal
            let big = CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)
            let fill = Gradient(stops: [.init(color: Color(core), location: 0), .init(color: Color(mid), location: 0.55), .init(color: Color(rim), location: 1)])
            lc.fill(Path(big), with: .radialGradient(fill, center: CGPoint(x: c.x - 0.35, y: c.y - 0.40), startRadius: 0, endRadius: 1.35))
            let rimG = Gradient(stops: [.init(color: Color(deep.opacity(0)), location: 0.62), .init(color: Color(deep.opacity(0.35)), location: 1)])
            lc.fill(Path(big), with: .radialGradient(rimG, center: c, startRadius: 0, endRadius: 1.02))
            for b in frame.blobs {
                let bc = px(b.position)
                let r = CGFloat(b.radius) * R
                let g = Gradient(stops: [.init(color: Color(core.opacity(0.9)), location: 0), .init(color: Color(mid), location: 0.6), .init(color: Color(rim), location: 1)])
                layer.fill(Path(ellipseIn: CGRect(x: bc.x - r * 1.4, y: bc.y - r * 1.4, width: r * 2.8, height: r * 2.8)),
                           with: .radialGradient(g, center: CGPoint(x: bc.x - r * 0.35, y: bc.y - r * 0.4), startRadius: 0, endRadius: r * 1.4))
                let hl = CGPoint(x: bc.x - r * 0.3, y: bc.y - r * 0.45)
                layer.fill(Path(ellipseIn: CGRect(x: hl.x - r * 0.18, y: hl.y - r * 0.12, width: r * 0.36, height: r * 0.24)), with: color(theme.highlight, 0.9))
            }
            let shift = CGPoint(x: frame.highlightShift.x, y: frame.highlightShift.y)
            let hc = CGPoint(x: c.x - 0.36 + shift.x, y: c.y - 0.44 + shift.y)
            let ell = Path(ellipseIn: CGRect(x: -0.30, y: -0.18, width: 0.60, height: 0.36))
                .applying(CGAffineTransform(rotationAngle: -35 * .pi / 180))
                .applying(CGAffineTransform(translationX: hc.x, y: hc.y))
            lc.fill(ell, with: color(theme.highlight, 0.85))
        }
    }

    // 7–9. Blush, eyes, mouth (clipped to the body).
    func drawFace(in ctx: inout GraphicsContext, bodyPath: Path) {
        guard frame.faceOpacity > 0.005 else { return }
        var fc = ctx
        fc.opacity = ctx.opacity * frame.faceOpacity
        fc.clip(to: bodyPath)
        let rot = CGFloat(frame.body.rotation)
        let sx = CGFloat(frame.body.scaleX)
        let sy = CGFloat(frame.body.scaleY)
        if frame.blush > 0.01 {
            for (i, c) in frame.blushCenters.enumerated() {
                let f = frame.blushForeshorten[i]
                let w = 0.22 * R * CGFloat(f.x) * sx
                let h = 0.13 * R * CGFloat(f.y) * sy
                let p = px(c)
                var bc = fc
                bc.translateBy(x: p.x, y: p.y)
                bc.rotate(by: .radians(rot))
                let g = Gradient(stops: [.init(color: Color(theme.blush.opacity(0.85 * frame.blush)), location: 0),
                                         .init(color: Color(theme.blush.opacity(0.55 * frame.blush)), location: 0.6),
                                         .init(color: Color(theme.blush.opacity(0)), location: 1)])
                bc.fill(Path(ellipseIn: CGRect(x: -w, y: -h, width: 2 * w, height: 2 * h)),
                        with: .radialGradient(g, center: .zero, startRadius: 0, endRadius: max(w, h)))
            }
        }
        for e in frame.eyes where e.visible {
            drawEye(e, rotation: rot, scale: CGPoint(x: sx, y: sy), in: &fc)
        }
        if frame.mouth.visible {
            drawMouth(frame.mouth, rotation: rot, scale: CGPoint(x: sx, y: sy), in: &fc)
        }
    }

    func drawEye(_ e: EyeFrame, rotation: CGFloat, scale: CGPoint, in fc: inout GraphicsContext) {
        let c = px(e.center)
        let w = R * CGFloat(e.radius * e.scale * e.foreshorten.x) * scale.x
        let h = R * CGFloat(e.radius * e.aspect * e.scale * e.foreshorten.y) * scale.y
        let ink = max(1.2, 0.06 * R)
        var ec = fc
        ec.translateBy(x: c.x, y: c.y)
        ec.rotate(by: .radians(rotation))
        let inkShade = color(theme.ink)
        let style = StrokeStyle(lineWidth: ink, lineCap: .round, lineJoin: .round)
        let open = CGFloat(e.openness)
        var shape = e.shape
        let ball: Set<EyeShape> = [.open, .half, .wide, .focused, .tired, .dot]
        if ball.contains(shape), open < 0.12 { shape = .closedLine }
        switch shape {
        case .open, .half, .wide, .focused, .tired, .dot:
            var ww = w
            var hh = h
            if shape == .wide { ww *= 1.15; hh *= 1.1 }
            if shape == .dot { ww *= 0.6; hh = ww }
            hh *= open
            var eye = ec
            switch shape {
            case .half: eye.clip(to: Path(CGRect(x: -ww * 1.5, y: 0, width: ww * 3, height: hh * 2)))
            case .focused: eye.clip(to: Path(CGRect(x: -ww * 1.5, y: -hh * 0.5, width: ww * 3, height: hh * 3)))
            case .tired:
                var lid = Path()
                lid.move(to: CGPoint(x: -ww * 1.5, y: -hh * 0.3))
                lid.addQuadCurve(to: CGPoint(x: ww * 1.5, y: -hh * 0.3), control: CGPoint(x: 0, y: hh * 0.25))
                lid.addLine(to: CGPoint(x: ww * 1.5, y: hh * 2))
                lid.addLine(to: CGPoint(x: -ww * 1.5, y: hh * 2))
                lid.closeSubpath()
                eye.clip(to: lid)
            default: break
            }
            eye.fill(Path(ellipseIn: CGRect(x: -ww, y: -hh, width: 2 * ww, height: 2 * hh)), with: inkShade)
            if open > 0.45 {
                let cr = ww * (shape == .wide ? 0.36 : 0.3)
                let cp = CGPoint(x: -ww * 0.32, y: -hh * 0.36)
                eye.fill(Path(ellipseIn: CGRect(x: cp.x - cr, y: cp.y - cr, width: 2 * cr, height: 2 * cr)), with: color(.white, 0.95))
                let sr = ww * 0.13
                let sp = CGPoint(x: ww * 0.3, y: hh * 0.32)
                eye.fill(Path(ellipseIn: CGRect(x: sp.x - sr, y: sp.y - sr, width: 2 * sr, height: 2 * sr)), with: color(.white, 0.75))
            }
        case .closedLine:
            var p = Path()
            p.move(to: CGPoint(x: -w, y: 0))
            p.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: 0, y: h * 0.5))
            ec.stroke(p, with: inkShade, style: style)
        case .happyArc:
            var p = Path()
            p.move(to: CGPoint(x: -w, y: h * 0.3))
            p.addQuadCurve(to: CGPoint(x: w, y: h * 0.3), control: CGPoint(x: 0, y: -h * 0.95))
            ec.stroke(p, with: inkShade, style: StrokeStyle(lineWidth: ink * 1.15, lineCap: .round, lineJoin: .round))
        case .squint:
            var p = Path()
            let dir: CGFloat = e.side < 0 ? 1 : -1
            p.move(to: CGPoint(x: -0.7 * w * dir, y: -0.75 * h))
            p.addLine(to: CGPoint(x: 0.55 * w * dir, y: 0))
            p.addLine(to: CGPoint(x: -0.7 * w * dir, y: 0.75 * h))
            ec.stroke(p, with: inkShade, style: style)
        case .spiral:
            var p = Path()
            let turns = 2.2
            let steps = 48
            for i in 0...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let a = t * CGFloat(turns) * 2 * .pi * (e.side < 0 ? 1 : -1)
                let r = t * min(w, h) * 0.95
                let pt = CGPoint(x: cos(a) * r, y: sin(a) * r)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            ec.stroke(p, with: inkShade, style: StrokeStyle(lineWidth: ink * 0.8, lineCap: .round, lineJoin: .round))
        case .cross:
            var p = Path()
            p.move(to: CGPoint(x: -0.7 * w, y: -0.7 * h)); p.addLine(to: CGPoint(x: 0.7 * w, y: 0.7 * h))
            p.move(to: CGPoint(x: 0.7 * w, y: -0.7 * h)); p.addLine(to: CGPoint(x: -0.7 * w, y: 0.7 * h))
            ec.stroke(p, with: inkShade, style: style)
        case .heart:
            ec.fill(BodyPath.heart(center: CGPoint(x: 0, y: -h * 0.1), size: w * 0.95), with: color(RGBA(hex: 0xFF5C8A)))
        case .star:
            ec.fill(BodyPath.star(center: .zero, radius: max(w, h) * 1.05), with: color(RGBA(hex: 0xFFC83D)))
            ec.stroke(BodyPath.star(center: .zero, radius: max(w, h) * 1.05), with: inkShade, lineWidth: ink * 0.5)
        case .flat:
            var p = Path()
            p.move(to: CGPoint(x: -0.9 * w, y: 0)); p.addLine(to: CGPoint(x: 0.9 * w, y: 0))
            ec.stroke(p, with: inkShade, style: style)
        }
    }

    func drawMouth(_ m: MouthFrame, rotation: CGFloat, scale: CGPoint, in fc: inout GraphicsContext) {
        guard m.shape != .none else { return }
        let c = px(m.center)
        var mc = fc
        mc.translateBy(x: c.x, y: c.y)
        mc.rotate(by: .radians(rotation))
        let fx = CGFloat(m.foreshorten.x) * scale.x
        let fy = CGFloat(m.foreshorten.y) * scale.y
        let open = CGFloat(m.open)
        let ink = color(theme.ink)
        let style = StrokeStyle(lineWidth: max(1.1, 0.045 * R), lineCap: .round, lineJoin: .round)
        switch m.shape {
        case .none:
            break
        case .smileTiny:
            let w = 0.16 * R * fx
            var p = Path()
            p.move(to: CGPoint(x: -w, y: 0))
            p.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: 0, y: 0.14 * R * fy))
            mc.stroke(p, with: ink, style: style)
        case .omega:
            let s = 0.95 * R
            var p = Path()
            p.move(to: CGPoint(x: -0.32 * s * fx, y: -0.05 * s * fy))
            p.addCurve(to: CGPoint(x: 0, y: 0.02 * s * fy),
                       control1: CGPoint(x: -0.30 * s * fx, y: 0.20 * s * fy), control2: CGPoint(x: -0.12 * s * fx, y: 0.20 * s * fy))
            p.addCurve(to: CGPoint(x: 0.32 * s * fx, y: -0.05 * s * fy),
                       control1: CGPoint(x: 0.12 * s * fx, y: 0.20 * s * fy), control2: CGPoint(x: 0.30 * s * fx, y: 0.20 * s * fy))
            mc.stroke(p, with: ink, style: style)
        case .openRound:
            let w = (0.10 + 0.16 * open) * R * fx
            let h = (0.04 + 0.22 * open) * R * fy
            mc.fill(Path(ellipseIn: CGRect(x: -w, y: -h, width: 2 * w, height: 2 * h)), with: ink)
            if open > 0.3 {
                let tw = w * 0.7
                let th = h * 0.45
                var t = mc
                t.clip(to: Path(ellipseIn: CGRect(x: -w, y: -h, width: 2 * w, height: 2 * h)))
                t.fill(Path(ellipseIn: CGRect(x: -tw, y: h * 0.25, width: 2 * tw, height: 2 * th)), with: color(RGBA(hex: 0xE2607F), 0.9))
            }
        case .o:
            let r = (0.06 + 0.07 * open) * R
            mc.fill(Path(ellipseIn: CGRect(x: -r * fx, y: -r * fy, width: 2 * r * fx, height: 2 * r * fy)), with: ink)
        case .flat:
            let w = 0.17 * R * fx
            var p = Path()
            p.move(to: CGPoint(x: -w, y: 0)); p.addLine(to: CGPoint(x: w, y: 0))
            mc.stroke(p, with: ink, style: style)
        case .wavy:
            let w = 0.2 * R * fx
            let a = 0.05 * R * fy
            var p = Path()
            let steps = 24
            for i in 0...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let pt = CGPoint(x: -w + 2 * w * t, y: sin(t * 4 * .pi) * a)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            mc.stroke(p, with: ink, style: style)
        case .sleepy:
            let r = 0.055 * R
            mc.fill(Path(ellipseIn: CGRect(x: -r * fx, y: -r * fy, width: 2 * r * fx, height: 2 * r * fy)), with: color(theme.ink, 0.75))
        }
    }

    // 10. Accessories, outside the body clip.
    func drawAccessories(in ctx: inout GraphicsContext) {
        for a in frame.accessories where a.pop > 0.01 {
            let p = px(a.anchor)
            var ac = ctx
            ac.translateBy(x: p.x, y: p.y)
            ac.scaleBy(x: CGFloat(a.pop), y: CGFloat(a.pop))
            switch a.kind {
            case .question, .exclamation, .dots:
                let r = 0.5 * R
                let fillColor: RGBA = a.kind == .exclamation ? RGBA(hex: 0xFFC14D) : RGBA(hex: 0xFFFFFF)
                var tail = Path()
                tail.move(to: CGPoint(x: -r * 0.55, y: r * 0.45))
                tail.addLine(to: CGPoint(x: -r * 0.95, y: r * 0.95))
                tail.addLine(to: CGPoint(x: -r * 0.1, y: r * 0.85))
                tail.closeSubpath()
                ac.fill(tail, with: color(fillColor, 0.96))
                ac.fill(Path(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r)), with: color(fillColor, 0.96))
                if a.kind == .dots {
                    for i in 0..<3 {
                        let ph = a.phase * 4 - Double(i) * 1.0
                        let o = 0.25 + 0.75 * max(0, sin(ph))
                        let dr = 0.085 * R
                        let dx = CGFloat(i - 1) * 0.26 * R
                        ac.fill(Path(ellipseIn: CGRect(x: dx - dr, y: -dr, width: 2 * dr, height: 2 * dr)), with: color(theme.ink, o))
                    }
                } else {
                    var text = ac.resolve(Text(a.kind == .question ? "?" : "!").font(.system(size: 0.78 * R, weight: .heavy, design: .rounded)))
                    text.shading = color(theme.ink)
                    ac.draw(text, at: CGPoint(x: 0, y: -0.02 * R), anchor: .center)
                }
            case .badge:
                for i in 0..<3 {
                    let ph = a.phase * 5 - Double(i) * 1.1
                    let o = 0.3 + 0.7 * max(0, sin(ph))
                    let dr = 0.07 * R
                    let dx = CGFloat(i - 1) * 0.2 * R
                    ac.fill(Path(ellipseIn: CGRect(x: dx - dr, y: -dr, width: 2 * dr, height: 2 * dr)), with: color(.white, o * 0.85))
                }
            case .micBars:
                let bw = 0.12 * R
                let gap = 0.08 * R
                let total = 5 * bw + 4 * gap
                for i in 0..<5 {
                    let level = i < a.levels.count ? a.levels[i] : 0
                    let hgt = R * CGFloat(0.22 + 0.9 * level)
                    let x = -total / 2 + CGFloat(i) * (bw + gap)
                    ac.fill(Path(roundedRect: CGRect(x: x, y: -hgt / 2, width: bw, height: hgt), cornerRadius: bw / 2), with: color(mid, 0.95))
                }
            case .recDot:
                let r = 0.14 * R
                let o = 0.55 + 0.45 * sin(2 * .pi * a.phase)
                ac.fill(Path(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r)), with: color(RGBA(hex: 0xFF3B30), o))
                ac.stroke(Path(ellipseIn: CGRect(x: -r * 1.6, y: -r * 1.6, width: 3.2 * r, height: 3.2 * r)), with: color(RGBA(hex: 0xFF3B30), 0.5), lineWidth: max(1, 0.03 * R))
            }
        }
    }

    // 11. Particles.
    func drawParticles(in ctx: inout GraphicsContext) {
        for p in frame.particles {
            let c = px(p.position)
            let t = CGFloat(p.progress)
            let size = CGFloat(p.size) * R
            switch p.kind {
            case .sparkle:
                let s = size * sin(t * .pi)
                var pc = ctx
                pc.translateBy(x: c.x, y: c.y)
                pc.rotate(by: .radians(p.spin * p.age))
                pc.fill(BodyPath.sparkle(center: .zero, radius: s), with: color(.white, 0.95))
                pc.fill(Path(ellipseIn: CGRect(x: -s * 0.22, y: -s * 0.22, width: s * 0.44, height: s * 0.44)), with: color(mid, 0.9))
            case .heart:
                var pc = ctx
                pc.translateBy(x: c.x, y: c.y)
                pc.rotate(by: .radians(sin(p.age * 3 + p.seed * 6) * 0.3))
                pc.fill(BodyPath.heart(center: .zero, size: size * (0.7 + 0.3 * sin(t * .pi))), with: color(theme.blush, 1 - t * t))
            case .star:
                var pc = ctx
                pc.translateBy(x: c.x, y: c.y)
                pc.rotate(by: .radians(p.spin * p.age))
                pc.fill(BodyPath.star(center: .zero, radius: size * (1 - t * 0.3)), with: color(RGBA(hex: 0xFFC83D), 1 - t))
            case .zzz:
                var text = ctx.resolve(Text("z").font(.system(size: size * (1 + t * 0.9), weight: .bold, design: .rounded)))
                text.shading = color(theme.core, (1 - t) * 0.9)
                ctx.draw(text, at: c, anchor: .center)
            case .drop:
                ctx.fill(BodyPath.teardrop(center: c, radius: size * 0.55), with: color(mid, 0.95 * (1 - t * t)))
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - size * 0.22, y: c.y - size * 0.18, width: size * 0.2, height: size * 0.2)), with: color(.white, 0.8 * (1 - t)))
            case .dust:
                let r = size * (1 + t * 0.8)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: color(.white, 0.35 * (1 - t)))
            }
        }
    }
}
