import CoreGraphics
import SwiftUI
import simd
import SlimeKit

/// Pure function of a `SlimeFrame`: draws one slime into a CGContext whose y axis points down.
/// `origin` is the pixel position of the contact point (centre bottom), `R` the pixels per unit.
/// Used by the AppKit layer view directly and by the SwiftUI Canvas through `withCGContext`.
public struct SlimeCGRenderer {
    public let frame: SlimeFrame
    public let appearance: SlimeAppearance
    public let origin: CGPoint
    public let R: CGFloat
    /// The palette (colours) of `appearance`.
    public var theme: SlimeTheme { appearance.palette }

    /// What goes under the body: a soft glow on the black island, a soft dark shadow on the
    /// desktop, or nothing (thumbnails on a clear background).
    public enum FloorShadow: Sendable, Equatable { case none, glow, dark }
    public let floorShadow: FloorShadow

    let rim: RGBA
    let deep: RGBA
    let mid: RGBA
    let core: RGBA
    /// The two-layer cel material of the palette under the frame's tint.
    let material: SlimeTheme.Material
    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    public init(frame: SlimeFrame, appearance: SlimeAppearance, origin: CGPoint, radius: CGFloat, floorShadow: FloorShadow = .glow) {
        self.frame = frame
        self.appearance = appearance
        self.origin = origin
        self.R = radius
        self.floorShadow = floorShadow
        let theme = appearance.palette
        let t = frame.tint
        rim = theme.rim.mixed(with: t.color, t.opacity).desaturated(t.desaturation)
        deep = theme.deep.mixed(with: t.color, t.opacity * 0.8).desaturated(t.desaturation)
        mid = theme.mid.mixed(with: t.color, t.opacity * 0.6).desaturated(t.desaturation)
        core = theme.core.desaturated(t.desaturation)
        material = theme.material(tint: t)
    }

    public init(frame: SlimeFrame, theme: SlimeTheme, origin: CGPoint, radius: CGFloat) {
        self.init(frame: frame, appearance: SlimeAppearance(palette: theme), origin: origin, radius: radius)
    }

    public static func draw(_ frame: SlimeFrame, appearance: SlimeAppearance, in cg: CGContext, origin: CGPoint, radius: CGFloat,
                            floorShadow: FloorShadow = .glow) {
        SlimeCGRenderer(frame: frame, appearance: appearance, origin: origin, radius: radius, floorShadow: floorShadow).draw(in: cg)
    }

    public static func draw(_ frame: SlimeFrame, theme: SlimeTheme, in cg: CGContext, origin: CGPoint, radius: CGFloat) {
        SlimeCGRenderer(frame: frame, theme: theme, origin: origin, radius: radius).draw(in: cg)
    }

    // MARK: Coordinates and colours

    @inline(__always) func px(_ v: SIMD2<Double>) -> CGPoint {
        CGPoint(x: origin.x + CGFloat(v.x) * R, y: origin.y + CGFloat(v.y) * R)
    }

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

    @inline(__always) func cgc(_ c: RGBA, _ opacity: Double = 1) -> CGColor {
        CGColor(colorSpace: Self.space, components: [c.r, c.g, c.b, c.a * opacity])!
    }

    func gradient(_ stops: [(RGBA, Double)]) -> CGGradient {
        let colors = stops.map { cgc($0.0) } as CFArray
        let locations = stops.map { CGFloat($0.1) }
        return CGGradient(colorsSpace: Self.space, colors: colors, locations: locations)!
    }

    func fillRadial(_ path: CGPath, _ stops: [(RGBA, Double)], center: CGPoint, radius: CGFloat, in cg: CGContext) {
        cg.saveGState()
        cg.addPath(path)
        cg.clip()
        cg.drawRadialGradient(gradient(stops), startCenter: center, startRadius: 0, endCenter: center, endRadius: radius,
                              options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        cg.restoreGState()
    }

    func fill(_ path: CGPath, _ c: RGBA, _ opacity: Double = 1, evenOdd: Bool = false, in cg: CGContext) {
        cg.setFillColor(cgc(c, opacity))
        cg.addPath(path)
        if evenOdd { cg.fillPath(using: .evenOdd) } else { cg.fillPath() }
    }

    func stroke(_ path: CGPath, _ c: RGBA, _ opacity: Double = 1, width: CGFloat, join: CGLineJoin = .round, in cg: CGContext) {
        cg.setStrokeColor(cgc(c, opacity))
        cg.setLineWidth(width)
        cg.setLineCap(.round)
        cg.setLineJoin(join)
        cg.addPath(path)
        cg.strokePath()
    }

    static func ellipse(_ center: CGPoint, _ rx: CGFloat, _ ry: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: center.x - rx, y: center.y - ry, width: 2 * rx, height: 2 * ry), transform: nil)
    }

    // MARK: Draw

    public func draw(in cg: CGContext) {
        cg.saveGState()
        cg.setAlpha(frame.opacity * (1 - clamp(appearance.look.transparency, 0, 0.8)))
        if frame.profile == .ghost {
            let c = px(frame.body.origin)
            cg.translateBy(x: c.x, y: c.y)
            cg.rotate(by: frame.ghostHeading)
            cg.scaleBy(x: frame.ghostStretch.x, y: frame.ghostStretch.y)
            cg.rotate(by: -frame.ghostHeading)
            cg.translateBy(x: -c.x, y: -c.y)
        }
        let bodyPath: CGPath
        // Blobs that have shrunk to nothing (after a pinch-off or merge) must not keep the goo path alive.
        let liveBlobs = frame.blobs.filter { $0.radius > 1e-3 }
        if liveBlobs.isEmpty {
            bodyPath = BodyPath.closed(through: frame.ring.map(px)).cgPath
        } else {
            let loops = ContourCache.contour(ring: frame.ring, blobs: liveBlobs, options: .forScale(pixelsPerUnit: Double(R)), pixelsPerUnit: Double(R))
            if loops.isEmpty {
                bodyPath = BodyPath.closed(through: frame.ring.map(px)).cgPath
            } else {
                var p = Path()
                for loop in loops { p.addPath(BodyPath.polyline(loop.map(px))) }
                bodyPath = p.cgPath
            }
        }
        drawGlow(in: cg)
        drawBackTraits(in: cg)
        drawBodyFill(in: cg, bodyPath: bodyPath, goo: !liveBlobs.isEmpty)
        drawFace(in: cg, bodyPath: bodyPath)
        drawEyewear(in: cg)
        drawFrontTraits(in: cg)
        drawProps(behindHands: true, in: cg)
        drawArms(in: cg, bodyPath: bodyPath)
        drawProps(behindHands: false, in: cg)
        drawAccessories(in: cg)
        drawParticles(in: cg)
        cg.restoreGState()
    }

    // 1. Floor contact: a soft glow of the body's own light on the black island, a soft dark
    //    shadow on the desktop. It widens with the contact patch and fades as the body lifts off.
    func drawGlow(in cg: CGContext) {
        guard frame.profile != .ghost, floorShadow != .none else { return }
        let lift = max(0, -frame.root.y)
        let fade = 1 - smoothstep(0, 0.9, lift)
        guard fade > 0.01 else { return }
        let boost = CGFloat(frame.glowBoost)
        let w = (CGFloat(frame.contactWidth) + 0.7) * R * (1 + 0.4 * boost)
        let hgt = 0.18 * R
        let cx = origin.x + CGFloat(frame.root.x) * R
        let rect = CGRect(x: cx - w / 2, y: origin.y - hgt / 2, width: w, height: hgt)
        let tone: RGBA = floorShadow == .dark ? theme.ink.opacity(0.25) : material.glow.opacity(1 + 0.6 * frame.glowBoost)
        // Squash the gradient to the ellipse by drawing in a scaled space.
        cg.saveGState()
        cg.translateBy(x: rect.midX, y: rect.midY)
        cg.scaleBy(x: 1, y: hgt / w)
        let circle = CGPath(ellipseIn: CGRect(x: -w / 2, y: -w / 2, width: w, height: w), transform: nil)
        fillRadial(circle, [(tone.opacity(fade), 0), (tone.opacity(fade * 0.7), 0.5), (tone.opacity(0), 1)], center: .zero, radius: w / 2, in: cg)
        cg.restoreGState()
    }

    // 2–8. The jelly, in the anime's two-layer translucent cel: a pale flat shell over the whole
    //      silhouette (goo included), the darker inner mass with its windows, droplets, the look's
    //      surface effect, a band of reflected light along the lower edge, hard specular highlights
    //      fixed to the light, and one ink line around everything.
    func drawBodyFill(in cg: CGContext, bodyPath: CGPath, goo: Bool) {
        let m = material
        cg.saveGState()
        cg.addPath(bodyPath)
        cg.clip(using: .evenOdd)
        fill(bodyPath, m.shell, in: cg)
        drawCoreMass(in: cg)
        drawInnerItems(in: cg)

        if goo {
            // Droplets are small bodies of the same material: shell from the fill above, their own
            // inner mass low in the drop, one glint.
            for b in frame.blobs where b.radius > 1e-4 && b.shaded {
                let bc = px(b.position)
                let r = CGFloat(b.radius) * R
                fill(Self.ellipse(CGPoint(x: bc.x + r * 0.05, y: bc.y + r * 0.18), r * 0.78, r * 0.6), m.inner, 0.95, in: cg)
                fill(Self.ellipse(CGPoint(x: bc.x - r * 0.3, y: bc.y - r * 0.45), r * 0.18, r * 0.12), m.highlight, 0.95, in: cg)
            }
        }

        drawSurface(in: cg, bodyPath: bodyPath)

        // Core glow when excited (world space, full detail).
        let boost = frame.coreBoost
        if boost > 0.02, detail >= .full {
            let coreCenter = px(frame.core)
            let cw = 0.62 * R * CGFloat(frame.body.scaleX)
            let ch = 0.50 * R * CGFloat(frame.body.scaleY)
            cg.saveGState()
            cg.translateBy(x: coreCenter.x, y: coreCenter.y)
            cg.scaleBy(x: 1, y: ch / max(cw, 0.001))
            fillRadial(CGPath(ellipseIn: CGRect(x: -cw, y: -cw, width: 2 * cw, height: 2 * cw), transform: nil),
                       [(core.opacity(0.35 * boost), 0), (core.opacity(0), 1)], center: .zero, radius: cw, in: cg)
            cg.restoreGState()
        }

        if detail >= .medium { drawRimBand(in: cg, bodyPath: bodyPath) }
        drawHighlights(in: cg)
        cg.restoreGState()

        // Outline: one thin opaque line in the body's own ink (light on a dark body).
        stroke(bodyPath, m.inkLine, width: max(1.0, 0.035 * R), join: goo ? .bevel : .round, in: cg)
    }

    /// The darker mass inside the shell: a cloud-topped, flat-bottomed body of jelly filling the
    /// lower three quarters, offset a little to the right, with one to three pale windows. It
    /// trails the shell (the core spring) and its upper edge drifts slowly, so the slime reads as
    /// liquid in a skin rather than a painted ball. Drawn in reference space so it squashes,
    /// leans and stretches with the body.
    func drawCoreMass(in cg: CGContext) {
        guard frame.profile != .ghost else { return }
        let m = material
        let bf = frame.body
        let kx = bf.referenceHalfWidth / 1.17
        let ky = bf.referenceTopHeight / 1.70
        // Where the core trails the shell, in reference units (the spring rests 0.04 above the centroid).
        let lagWorld = frame.core - bf.origin - bf.transformVector(SIMD2(0, -0.04))
        let raw = bf.matrix.inverse * lagWorld
        let lag = raw.x.isFinite && raw.y.isFinite ? SIMD2(clamp(raw.x, -0.5, 0.5), clamp(raw.y, -0.5, 0.5)) : SIMD2<Double>.zero
        let centre = SIMD2(0.05 * kx, -0.66 * ky) + lag * 0.6
        let rx = 0.92 * kx
        let ryUp = 0.60 * ky
        let ryDown = 0.58 * ky
        let n = detail == .full ? 20 : (detail == .medium ? 14 : 10)
        let phase = 2 * .pi * frame.time / 12 + 4 * lag.x
        var pts: [CGPoint] = []
        pts.reserveCapacity(n)
        for i in 0..<n {
            let a = Double(i) / Double(n) * 2 * .pi
            let up = sin(a) < 0
            var r = 1.0
            if up {
                r += 0.10 * sin(2.3 * a + phase)
                if detail == .full { r += 0.06 * sin(4.1 * a - 0.7 + 0.6 * phase) }
            }
            let x = centre.x + rx * cos(a) * r
            let y = min(centre.y + (up ? ryUp : ryDown) * sin(a) * r, -0.08 * ky)
            pts.append(CGPoint(x: x, y: y))
        }
        cg.saveGState()
        cg.concatenate(localTransform)
        let path = BodyPath.closed(through: pts).cgPath
        let tone = m.inner.mixed(with: m.shell, 0.3 * frame.coreBoost)
        fill(path, tone, 0.95 * (1 - clamp(look.transparency, 0, 0.8)), in: cg)
        if detail >= .medium {
            cg.saveGState()
            cg.addPath(path)
            cg.clip()
            let win = RGBA(r: m.window.r, g: m.window.g, b: m.window.b, a: min(1, m.window.a + 0.3 * frame.coreBoost))
            let w1 = CGPoint(x: centre.x - 0.26 * kx + 0.4 * lag.x, y: centre.y - 0.12 * ky + 0.4 * lag.y)
            var t1 = CGAffineTransform(translationX: w1.x, y: w1.y).rotated(by: -15 * .pi / 180)
            fill(CGPath(ellipseIn: CGRect(x: -0.15, y: -0.11, width: 0.30, height: 0.22), transform: &t1), win, in: cg)
            let w2 = CGPoint(x: centre.x + 0.36 * kx + 0.4 * lag.x, y: centre.y + 0.08 * ky + 0.4 * lag.y)
            fill(Self.ellipse(w2, 0.075, 0.075), win, in: cg)
            if detail >= .full {
                let w3 = CGPoint(x: centre.x + 0.08 * kx, y: centre.y + 0.30 * ky)
                fill(Self.ellipse(w3, 0.045, 0.045), win, in: cg)
            }
            cg.restoreGState()
        }
        cg.restoreGState()
    }

    /// Reflected light: a thin pale crescent inside the outline along the lower right and the
    /// base, where light comes back through the jelly. The even-odd of the body and a copy of it
    /// shifted toward the light leaves exactly that band. World space, so it stays with the light.
    func drawRimBand(in cg: CGContext, bodyPath: CGPath) {
        let d = 0.075 * R * CGFloat((frame.body.scaleX * frame.body.scaleY).squareRoot())
        var shift = CGAffineTransform(translationX: -d * 0.85, y: -d)
        guard let lit = bodyPath.copy(using: &shift) else { return }
        cg.saveGState()
        cg.addPath(bodyPath)
        cg.addPath(lit)
        cg.clip(using: .evenOdd)
        fill(bodyPath, material.rimLight, in: cg)
        cg.restoreGState()
    }

    /// Specular highlights, hard-edged and never blurred: one long pill upper-left tilted 20°
    /// toward the light, a small dot further down the curve and a tiny one near the crown. They
    /// ride the body's squash and the gaze shift but keep their angle, fixed to the light; minis
    /// and the tiny tier get one short pill.
    func drawHighlights(in cg: CGContext) {
        let bf = frame.body
        let kx = bf.referenceHalfWidth / 1.17
        let ky = bf.referenceTopHeight / 1.70
        let shift = frame.highlightShift
        let s = R * CGFloat((bf.scaleX * bf.scaleY).squareRoot())
        func place(_ local: SIMD2<Double>, _ draw: (CGContext) -> Void) {
            let p = px(bf.transform(local + shift))
            cg.saveGState()
            cg.translateBy(x: p.x, y: p.y)
            cg.rotate(by: -20 * .pi / 180)
            cg.scaleBy(x: s, y: s)
            draw(cg)
            cg.restoreGState()
        }
        let highlight = material.highlight
        if frame.profile == .mini || detail == .tiny {
            place(SIMD2(-0.40 * kx, -1.25 * ky)) { cg in fill(Self.ellipse(.zero, 0.18, 0.065), highlight, in: cg) }
            return
        }
        place(SIMD2(-0.46 * kx, -1.28 * ky)) { cg in fill(Self.ellipse(.zero, 0.225, 0.08), highlight, in: cg) }
        if detail >= .medium {
            place(SIMD2(-0.72 * kx, -1.02 * ky)) { cg in fill(Self.ellipse(.zero, 0.05, 0.05), highlight, in: cg) }
        }
        if detail >= .full {
            place(SIMD2(-0.24 * kx, -1.50 * ky)) { cg in fill(Self.ellipse(.zero, 0.035, 0.035), highlight, in: cg) }
        }
    }

    // 7–9. Blush, eyes, mouth (clipped to the body).
    func drawFace(in cg: CGContext, bodyPath: CGPath) {
        guard frame.faceOpacity > 0.005 else { return }
        cg.saveGState()
        cg.setAlpha(frame.opacity * frame.faceOpacity)
        cg.addPath(bodyPath)
        cg.clip(using: .evenOdd)
        let rot = CGFloat(frame.body.rotation)
        let sx = CGFloat(frame.body.scaleX)
        let sy = CGFloat(frame.body.scaleY)
        if frame.blush > 0.01, appearance.faceStyle == .anime {
            // The anime blush: two flat pink ovals with a hard edge, foreshortening a little as
            // the face turns.
            let mini = frame.profile == .mini
            let bw: CGFloat = mini ? 0.10 : 0.14
            let bh: CGFloat = mini ? 0.06 : 0.08
            for (i, c) in frame.blushCenters.enumerated() {
                let f = frame.blushForeshorten[i]
                let k = CGFloat(0.75 + 0.25 * f.x)
                let w = bw * R * k * sx
                let h = bh * R * k * sy
                let p = px(c)
                var t = CGAffineTransform(translationX: p.x, y: p.y).rotated(by: rot)
                fill(CGPath(ellipseIn: CGRect(x: -w, y: -h, width: 2 * w, height: 2 * h), transform: &t), theme.blush, frame.blush, in: cg)
            }
        } else if frame.blush > 0.01 {
            for (i, c) in frame.blushCenters.enumerated() {
                let f = frame.blushForeshorten[i]
                let w = 0.22 * R * CGFloat(f.x) * sx
                let h = 0.13 * R * CGFloat(f.y) * sy
                let p = px(c)
                cg.saveGState()
                cg.translateBy(x: p.x, y: p.y)
                cg.rotate(by: rot)
                cg.scaleBy(x: 1, y: h / max(w, 0.001))
                fillRadial(CGPath(ellipseIn: CGRect(x: -w, y: -w, width: 2 * w, height: 2 * w), transform: nil),
                           [(theme.blush.opacity(0.85 * frame.blush), 0), (theme.blush.opacity(0.55 * frame.blush), 0.6), (theme.blush.opacity(0), 1)],
                           center: .zero, radius: w, in: cg)
                cg.restoreGState()
            }
        }
        for e in frame.eyes where e.visible {
            drawEye(e, rotation: rot, scale: CGPoint(x: sx, y: sy), in: cg)
        }
        if frame.mouth.visible {
            drawMouth(frame.mouth, rotation: rot, scale: CGPoint(x: sx, y: sy), in: cg)
        }
        cg.restoreGState()
    }

    /// Half the brush width of an anime eye stroke at its middle, in pixels: 0.09 R wide, and
    /// never under 2 px so the face still reads on a compact mini.
    var strokeHalfWidth: CGFloat { max(0.95, 0.045 * R) }

    /// The face is inked darker than the outline, as on the figures: the outline is a soft
    /// edge, the strokes carry the expression.
    var faceInk: RGBA { appearance.faceStyle == .anime && !theme.isDark ? theme.ink.mixed(with: .black, 0.3) : theme.ink }

    func drawEye(_ e: EyeFrame, rotation: CGFloat, scale: CGPoint, in cg: CGContext) {
        let c = px(e.center)
        let w = R * CGFloat(e.radius * e.scale * e.foreshorten.x) * scale.x
        let h = R * CGFloat(e.radius * e.aspect * e.scale * e.foreshorten.y) * scale.y
        let ink = max(1.2, 0.06 * R)
        let anime = appearance.faceStyle == .anime
        cg.saveGState()
        cg.translateBy(x: c.x, y: c.y)
        cg.rotate(by: rotation)
        let open = CGFloat(e.openness)
        var shape = e.shape
        if shape.isBall, open < 0.12 { shape = .closedLine }
        // Toward the middle of the face (+x for the left eye).
        let inward: CGFloat = e.side < 0 ? 1 : -1

        // Line shapes share one centre polyline: a tapered brush stroke on the anime face (where a
        // blink flattens the polyline toward the eye line instead of switching shapes), a round-
        // capped line on the round face.
        func line(_ pts: [CGPoint], widthScale: CGFloat = 1, opacity: Double = 1) {
            var p = pts
            if anime, open < 0.999 { p = p.map { CGPoint(x: $0.x, y: $0.y * open) } }
            if anime {
                fill(BrushStroke.path(along: p, halfWidth: strokeHalfWidth * widthScale), faceInk, opacity, in: cg)
            } else {
                let path = CGMutablePath()
                path.addLines(between: p)
                stroke(path, theme.ink, opacity, width: ink * widthScale, in: cg)
            }
        }
        func quad(_ a: CGPoint, _ b: CGPoint, control k: CGPoint, samples: Int = 14) -> [CGPoint] {
            (0...samples).map { i in
                let t = CGFloat(i) / CGFloat(samples)
                let u = 1 - t
                return CGPoint(x: u * u * a.x + 2 * u * t * k.x + t * t * b.x, y: u * u * a.y + 2 * u * t * k.y + t * t * b.y)
            }
        }
        let chevron = [CGPoint(x: -0.7 * w * inward, y: -0.75 * h), CGPoint(x: 0.55 * w * inward, y: 0), CGPoint(x: -0.7 * w * inward, y: 0.75 * h)]

        switch shape {
        case .open, .half, .wide, .focused, .tired, .dot, .smug, .sideGlance, .glare, .teary:
            var ww = w
            var hh = h
            if shape == .wide { ww *= 1.15; hh *= 1.1 }
            if shape == .dot { ww *= 0.6; hh = ww }
            if shape == .glare { hh *= 0.92 }
            hh *= open
            // Side glances and smug looks slide the ball the same way in both eyes.
            let shift: CGFloat = shape == .sideGlance ? 0.3 * ww : shape == .smug ? 0.16 * ww : 0
            cg.saveGState()
            switch shape {
            case .half: cg.clip(to: CGRect(x: -ww * 1.5, y: 0, width: ww * 3, height: hh * 2))
            case .smug: cg.clip(to: CGRect(x: -ww * 1.5, y: -hh * 0.12, width: ww * 3, height: hh * 2))
            case .focused: cg.clip(to: CGRect(x: -ww * 1.5, y: -hh * 0.5, width: ww * 3, height: hh * 3))
            case .tired:
                let lid = CGMutablePath()
                lid.move(to: CGPoint(x: -ww * 1.5, y: -hh * 0.3))
                lid.addQuadCurve(to: CGPoint(x: ww * 1.5, y: -hh * 0.3), control: CGPoint(x: 0, y: hh * 0.25))
                lid.addLine(to: CGPoint(x: ww * 1.5, y: hh * 2))
                lid.addLine(to: CGPoint(x: -ww * 1.5, y: hh * 2))
                lid.closeSubpath()
                cg.addPath(lid)
                cg.clip()
            case .glare:
                // The brow slopes down toward the middle of the face.
                let lid = CGMutablePath()
                lid.move(to: CGPoint(x: -inward * ww * 1.6, y: -hh * 0.95))
                lid.addLine(to: CGPoint(x: inward * ww * 1.6, y: -hh * 0.15))
                lid.addLine(to: CGPoint(x: inward * ww * 1.6, y: hh * 2))
                lid.addLine(to: CGPoint(x: -inward * ww * 1.6, y: hh * 2))
                lid.closeSubpath()
                cg.addPath(lid)
                cg.clip()
            default: break
            }
            cg.translateBy(x: shift, y: 0)
            fill(Self.ellipse(.zero, ww, hh), theme.ink, in: cg)
            if open > 0.45 {
                let cr = ww * (shape == .wide ? 0.36 : 0.3)
                fill(Self.ellipse(CGPoint(x: -ww * 0.32, y: -hh * 0.36), cr, cr), .white, 0.95, in: cg)
                let sr = ww * 0.13
                fill(Self.ellipse(CGPoint(x: ww * 0.3, y: hh * 0.32), sr, sr), .white, 0.75, in: cg)
            }
            cg.restoreGState()
            switch shape {
            case .smug:
                let lid = CGMutablePath()
                lid.move(to: CGPoint(x: -ww * 1.1 + shift, y: -hh * 0.12))
                lid.addLine(to: CGPoint(x: ww * 1.1 + shift, y: -hh * 0.12))
                stroke(lid, theme.ink, width: ink, in: cg)
            case .glare:
                let brow = CGMutablePath()
                brow.move(to: CGPoint(x: -inward * ww * 1.25, y: -hh * 0.98))
                brow.addLine(to: CGPoint(x: inward * ww * 1.05, y: -hh * 0.2))
                stroke(brow, theme.ink, width: ink * 1.1, in: cg)
            case .teary:
                // Tears well up over the lower half of the eye.
                let pool = Self.ellipse(CGPoint(x: 0, y: hh * 0.5), ww * 0.95, hh * 0.52)
                fill(pool, RGBA(hex: 0xBFE9FF), 0.92, in: cg)
                fill(Self.ellipse(CGPoint(x: -ww * 0.3, y: hh * 0.42), ww * 0.2, hh * 0.1), .white, 0.9, in: cg)
            default: break
            }
        case .content:
            // The content face from the figure sheets: a bold dash with a hint of an upward bow,
            // tilted a little inward-down, and two short parallel lash ticks at its inner end.
            line(quad(CGPoint(x: -inward * w, y: -h * 0.10), CGPoint(x: inward * w * 0.5, y: h * 0.12), control: CGPoint(x: -inward * w * 0.2, y: -h * 0.12)))
            line([CGPoint(x: inward * w * 0.62, y: -h * 0.48), CGPoint(x: inward * w * 1.02, y: -h * 0.16)], widthScale: 0.6)
            line([CGPoint(x: inward * w * 0.62, y: h * 0.26), CGPoint(x: inward * w * 1.02, y: h * 0.58)], widthScale: 0.6)
        case .sad:
            // Outward-down arcs with a slight bow.
            line(quad(CGPoint(x: inward * w, y: -h * 0.4), CGPoint(x: -inward * w, y: h * 0.4), control: CGPoint(x: 0, y: -h * 0.3)))
        case .relaxed:
            // "ー" with a small tick at the outer corner.
            line(quad(CGPoint(x: -w, y: 0), CGPoint(x: w, y: 0), control: CGPoint(x: 0, y: h * 0.22)))
            line([CGPoint(x: -inward * w, y: h * 0.05), CGPoint(x: -inward * w * 1.2, y: h * 0.42)], widthScale: 0.7)
        case .squeeze:
            // "> <" with three effort ticks radiating from the outer side.
            line(chevron)
            for k in -1...1 {
                let a = CGFloat(k) * 0.55
                let dx = -inward * cos(a), dy = sin(a)
                line([CGPoint(x: dx * w * 1.0, y: dy * h * 0.9), CGPoint(x: dx * w * 1.4, y: dy * h * 1.25)], widthScale: 0.6)
            }
        case .squint:
            line(chevron)
        case .pleased:
            // "︶": a soft bowl, the eyes closed in contentment.
            line(quad(CGPoint(x: -w, y: -h * 0.25), CGPoint(x: w, y: -h * 0.25), control: CGPoint(x: 0, y: h * 0.85)), widthScale: 1.1)
        case .shock:
            // Concentric rings with a pin-point pupil.
            stroke(Self.ellipse(.zero, w * 1.05, h * 0.95), theme.ink, width: ink * 0.9, in: cg)
            stroke(Self.ellipse(.zero, w * 0.6, h * 0.55), theme.ink, 0.85, width: ink * 0.7, in: cg)
            fill(Self.ellipse(.zero, w * 0.22, w * 0.22), theme.ink, in: cg)
        case .closedLine:
            line(quad(CGPoint(x: -w, y: 0), CGPoint(x: w, y: 0), control: CGPoint(x: 0, y: h * 0.5)))
        case .happyArc:
            line(quad(CGPoint(x: -w, y: h * 0.3), CGPoint(x: w, y: h * 0.3), control: CGPoint(x: 0, y: -h * 0.95)), widthScale: 1.15)
        case .cryStream:
            // A closed stroke with two tear ribbons running down the cheek.
            line(quad(CGPoint(x: -w, y: 0), CGPoint(x: w, y: 0), control: CGPoint(x: 0, y: h * 0.3)))
            let tear = RGBA(hex: 0xBFE9FF)
            let len = 0.45 * R * scale.y
            let top = h * 0.15
            for sx in [-0.35, 0.35] as [CGFloat] {
                let x = sx * w
                let ribbon = CGPath(roundedRect: CGRect(x: x - 0.045 * R, y: top, width: 0.09 * R, height: len),
                                    cornerWidth: 0.04 * R, cornerHeight: 0.04 * R, transform: nil)
                fill(ribbon, tear, 0.92, in: cg)
                let gleam = CGMutablePath()
                gleam.move(to: CGPoint(x: x - 0.018 * R, y: top + 0.06 * R))
                gleam.addLine(to: CGPoint(x: x - 0.018 * R, y: top + len - 0.07 * R))
                stroke(gleam, .white, 0.85, width: max(1, 0.018 * R), in: cg)
            }
        case .sparkle:
            let star = BodyPath.sparkle(center: .zero, radius: max(w, h) * 1.1).cgPath
            fill(star, theme.star, in: cg)
            stroke(star, theme.ink, width: ink * 0.5, in: cg)
        case .spiral:
            let p = CGMutablePath()
            let turns = 2.2
            let steps = 48
            for i in 0...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let a = t * CGFloat(turns) * 2 * .pi * (e.side < 0 ? 1 : -1)
                let r = t * min(w, h) * 0.95
                let pt = CGPoint(x: cos(a) * r, y: sin(a) * r)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            stroke(p, theme.ink, width: ink * 0.8, in: cg)
        case .cross:
            line([CGPoint(x: -0.7 * w, y: -0.7 * h), CGPoint(x: 0.7 * w, y: 0.7 * h)])
            line([CGPoint(x: 0.7 * w, y: -0.7 * h), CGPoint(x: -0.7 * w, y: 0.7 * h)])
        case .heart:
            fill(BodyPath.heart(center: CGPoint(x: 0, y: -h * 0.1), size: w * 0.95).cgPath, theme.heart, in: cg)
        case .star:
            let star = BodyPath.star(center: .zero, radius: max(w, h) * 1.05).cgPath
            fill(star, theme.star, in: cg)
            stroke(star, theme.ink, width: ink * 0.5, in: cg)
        case .flat:
            line([CGPoint(x: -0.9 * w, y: 0), CGPoint(x: 0.9 * w, y: 0)])
        }
        cg.restoreGState()
    }

    func drawMouth(_ m: MouthFrame, rotation: CGFloat, scale: CGPoint, in cg: CGContext) {
        guard m.shape != .none else { return }
        let c = px(m.center)
        cg.saveGState()
        cg.translateBy(x: c.x, y: c.y)
        cg.rotate(by: rotation)
        let fx = CGFloat(m.foreshorten.x) * scale.x
        let fy = CGFloat(m.foreshorten.y) * scale.y
        let open = CGFloat(m.open)
        let lw = max(1.1, 0.045 * R)
        switch m.shape {
        case .none:
            break
        case .caret:
            // The small "∧" pout of the stroke face, as one tapered brush stroke.
            let pts = [CGPoint(x: -0.07 * R * fx, y: 0.035 * R * fy), CGPoint(x: 0, y: -0.035 * R * fy), CGPoint(x: 0.07 * R * fx, y: 0.035 * R * fy)]
            fill(BrushStroke.path(along: pts, halfWidth: strokeHalfWidth * 0.8), faceInk, in: cg)
        case .smileTiny:
            let w = 0.16 * R * fx
            let p = CGMutablePath()
            p.move(to: CGPoint(x: -w, y: 0))
            p.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: 0, y: 0.14 * R * fy))
            stroke(p, theme.ink, width: lw, in: cg)
        case .omega:
            let s = 0.95 * R
            let p = CGMutablePath()
            p.move(to: CGPoint(x: -0.32 * s * fx, y: -0.05 * s * fy))
            p.addCurve(to: CGPoint(x: 0, y: 0.02 * s * fy),
                       control1: CGPoint(x: -0.30 * s * fx, y: 0.20 * s * fy), control2: CGPoint(x: -0.12 * s * fx, y: 0.20 * s * fy))
            p.addCurve(to: CGPoint(x: 0.32 * s * fx, y: -0.05 * s * fy),
                       control1: CGPoint(x: 0.12 * s * fx, y: 0.20 * s * fy), control2: CGPoint(x: 0.30 * s * fx, y: 0.20 * s * fy))
            stroke(p, theme.ink, width: lw, in: cg)
        case .openRound:
            let w = (0.10 + 0.16 * open) * R * fx
            let h = (0.04 + 0.22 * open) * R * fy
            fill(Self.ellipse(.zero, w, h), theme.ink, in: cg)
            if open > 0.3 {
                cg.saveGState()
                cg.addPath(Self.ellipse(.zero, w, h))
                cg.clip()
                fill(Self.ellipse(CGPoint(x: 0, y: h * 0.25 + h * 0.45), w * 0.7, h * 0.45), theme.tongue, 0.9, in: cg)
                cg.restoreGState()
            }
        case .o:
            let r = (0.06 + 0.07 * open) * R
            fill(Self.ellipse(.zero, r * fx, r * fy), theme.ink, in: cg)
        case .flat:
            let w = 0.17 * R * fx
            let p = CGMutablePath()
            p.move(to: CGPoint(x: -w, y: 0)); p.addLine(to: CGPoint(x: w, y: 0))
            stroke(p, theme.ink, width: lw, in: cg)
        case .wavy:
            let w = 0.2 * R * fx
            let a = 0.05 * R * fy
            let p = CGMutablePath()
            let steps = 24
            for i in 0...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let pt = CGPoint(x: -w + 2 * w * t, y: sin(t * 4 * .pi) * a)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            stroke(p, theme.ink, width: lw, in: cg)
        case .sleepy:
            let r = 0.055 * R
            fill(Self.ellipse(.zero, r * fx, r * fy), theme.ink, 0.75, in: cg)
        case .openWide:
            // The big rounded shout from the references, tongue at the bottom.
            let w = (0.2 + 0.12 * open) * R * fx
            let h = (0.1 + 0.26 * open) * R * fy
            let m = CGMutablePath()
            m.move(to: CGPoint(x: -w, y: -h * 0.35))
            m.addQuadCurve(to: CGPoint(x: w, y: -h * 0.35), control: CGPoint(x: 0, y: -h * 0.75))
            m.addCurve(to: CGPoint(x: -w, y: -h * 0.35), control1: CGPoint(x: w * 1.1, y: h * 1.3), control2: CGPoint(x: -w * 1.1, y: h * 1.3))
            m.closeSubpath()
            fill(m, theme.ink, in: cg)
            cg.saveGState()
            cg.addPath(m)
            cg.clip()
            fill(Self.ellipse(CGPoint(x: 0, y: h * 0.75), w * 0.62, h * 0.5), theme.tongue, 0.95, in: cg)
            cg.restoreGState()
        case .pout:
            // A small puckered bud with two short curved whiskers.
            fill(Self.ellipse(.zero, 0.065 * R * fx, 0.05 * R * fy), theme.ink, in: cg)
            let p = CGMutablePath()
            for side in [-1.0, 1.0] {
                let x = CGFloat(side) * 0.13 * R * fx
                p.move(to: CGPoint(x: x, y: -0.06 * R * fy))
                p.addQuadCurve(to: CGPoint(x: x, y: 0.06 * R * fy), control: CGPoint(x: x + CGFloat(side) * 0.04 * R * fx, y: 0))
            }
            stroke(p, theme.ink, width: lw * 0.8, in: cg)
        case .tongue:
            let w = 0.2 * R * fx
            let p = CGMutablePath()
            p.move(to: CGPoint(x: -w, y: 0))
            p.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: 0, y: 0.16 * R * fy))
            stroke(p, theme.ink, width: lw, in: cg)
            let t = Self.ellipse(CGPoint(x: 0.03 * R * fx, y: 0.1 * R * fy), 0.095 * R * fx, 0.1 * R * fy)
            fill(t, theme.tongue, in: cg)
            stroke(t, theme.ink, width: lw * 0.6, in: cg)
            let line = CGMutablePath()
            line.move(to: CGPoint(x: 0.03 * R * fx, y: 0.1 * R * fy))
            line.addLine(to: CGPoint(x: 0.03 * R * fx, y: 0.19 * R * fy))
            stroke(line, theme.ink, 0.6, width: lw * 0.5, in: cg)
        case .grin:
            // A wide D-shaped grin with a band of teeth.
            let w = 0.3 * R * fx
            let g = CGMutablePath()
            g.move(to: CGPoint(x: -w, y: 0))
            g.addLine(to: CGPoint(x: w, y: 0))
            g.addQuadCurve(to: CGPoint(x: -w, y: 0), control: CGPoint(x: 0, y: 0.46 * R * fy))
            g.closeSubpath()
            fill(g, theme.ink, in: cg)
            cg.saveGState()
            cg.addPath(g)
            cg.clip()
            fill(CGPath(rect: CGRect(x: -w, y: 0, width: 2 * w, height: 0.085 * R * fy), transform: nil), .white, 0.95, in: cg)
            cg.restoreGState()
            stroke(g, theme.ink, width: lw * 0.6, in: cg)
        case .squiggle:
            // Three droopy bumps, ends turned down.
            let w = 0.2 * R * fx
            let a = 0.04 * R * fy
            let p = CGMutablePath()
            let steps = 30
            for i in 0...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let droop = pow(abs(2 * t - 1), 2) * 0.07 * R * fy
                let pt = CGPoint(x: -w + 2 * w * t, y: sin(t * 3 * .pi) * a + droop)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            stroke(p, theme.ink, width: lw, in: cg)
        }
        cg.restoreGState()
    }

    // 10. Accessories, outside the body clip. Glyphs are paths so no font metrics are involved.
    func drawAccessories(in cg: CGContext) {
        for a in frame.accessories where a.pop > 0.01 {
            let p = px(a.anchor)
            if a.grown, let b = a.bead, a.beadRadius > 1e-3 {
                // The bead on the head under the mark: the same jelly, with its own rim and glint.
                let c = px(b), br = CGFloat(a.beadRadius) * R
                let dot = Self.ellipse(c, br, br)
                fill(dot, material.shell, in: cg)
                cg.saveGState()
                cg.addPath(dot)
                cg.clip()
                fill(Self.ellipse(CGPoint(x: c.x + br * 0.05, y: c.y + br * 0.3), br * 0.8, br * 0.55), material.inner, 0.95, in: cg)
                cg.restoreGState()
                stroke(dot, material.inkLine, width: max(1, 0.03 * R), in: cg)
                fill(Self.ellipse(CGPoint(x: c.x - br * 0.3, y: c.y - br * 0.35), br * 0.3, br * 0.2), material.highlight, 0.9, in: cg)
            }
            cg.saveGState()
            cg.translateBy(x: p.x, y: p.y)
            if a.grown {
                // Leans a little with the direction it rose in, grows with the pop.
                cg.rotate(by: CGFloat(atan2(a.direction.x, -a.direction.y)) * 0.3)
                cg.scaleBy(x: CGFloat(a.pop), y: CGFloat(a.pop))
                drawGrownGlyph(a.kind, in: cg)
                cg.restoreGState()
                continue
            }
            cg.scaleBy(x: CGFloat(a.pop), y: CGFloat(a.pop))
            switch a.kind {
            case .anger:
                // The anime's anger mark on the brow: four curved ticks, pulsing.
                let s = 0.2 * R * (1 + 0.08 * CGFloat(sin(2 * .pi * 3 * a.phase)))
                let m = CGMutablePath()
                for i in 0..<4 {
                    let ang = CGFloat.pi / 4 + CGFloat(i) * CGFloat.pi / 2
                    let d = CGPoint(x: cos(ang), y: sin(ang))
                    let n = CGPoint(x: -d.y, y: d.x)
                    m.move(to: CGPoint(x: d.x * s * 0.35, y: d.y * s * 0.35))
                    m.addQuadCurve(to: CGPoint(x: d.x * s, y: d.y * s), control: CGPoint(x: d.x * s * 0.7 + n.x * s * 0.18, y: d.y * s * 0.7 + n.y * s * 0.18))
                }
                stroke(m, theme.ink, 0.92, width: max(1, 0.055 * R), in: cg)
            case .question, .exclamation, .dots, .note:
                let r = 0.5 * R
                let fillColor: RGBA = a.kind == .exclamation ? theme.accent : .white
                let tail = CGMutablePath()
                tail.move(to: CGPoint(x: -r * 0.55, y: r * 0.45))
                tail.addLine(to: CGPoint(x: -r * 0.95, y: r * 0.95))
                tail.addLine(to: CGPoint(x: -r * 0.1, y: r * 0.85))
                tail.closeSubpath()
                fill(tail, fillColor, 0.96, in: cg)
                fill(Self.ellipse(.zero, r, r), fillColor, 0.96, in: cg)
                switch a.kind {
                case .dots:
                    for i in 0..<3 {
                        let ph = a.phase * 4 - Double(i) * 1.0
                        let o = 0.25 + 0.75 * max(0, sin(ph))
                        let dr = 0.085 * R
                        fill(Self.ellipse(CGPoint(x: CGFloat(i - 1) * 0.26 * R, y: 0), dr, dr), theme.ink, o, in: cg)
                    }
                case .question:
                    let g = CGMutablePath()
                    g.move(to: CGPoint(x: -0.19 * R, y: -0.17 * R))
                    g.addCurve(to: CGPoint(x: 0.19 * R, y: -0.17 * R),
                               control1: CGPoint(x: -0.19 * R, y: -0.46 * R), control2: CGPoint(x: 0.19 * R, y: -0.46 * R))
                    g.addQuadCurve(to: CGPoint(x: 0, y: 0.06 * R), control: CGPoint(x: 0.21 * R, y: 0.04 * R))
                    g.addLine(to: CGPoint(x: 0, y: 0.13 * R))
                    stroke(g, theme.ink, width: 0.11 * R, in: cg)
                    fill(Self.ellipse(CGPoint(x: 0, y: 0.31 * R), 0.068 * R, 0.068 * R), theme.ink, in: cg)
                case .note:
                    fill(Self.noteGlyph(scale: 0.72 * R, stroke: 0.1 * R), theme.ink, in: cg)
                default:
                    let g = CGMutablePath()
                    g.move(to: CGPoint(x: 0, y: -0.3 * R))
                    g.addLine(to: CGPoint(x: 0, y: 0.08 * R))
                    stroke(g, theme.ink, width: 0.13 * R, in: cg)
                    fill(Self.ellipse(CGPoint(x: 0, y: 0.3 * R), 0.075 * R, 0.075 * R), theme.ink, in: cg)
                }
            case .badge:
                for i in 0..<3 {
                    let ph = a.phase * 5 - Double(i) * 1.1
                    let o = 0.3 + 0.7 * max(0, sin(ph))
                    let dr = 0.07 * R
                    fill(Self.ellipse(CGPoint(x: CGFloat(i - 1) * 0.2 * R, y: 0), dr, dr), .white, o * 0.85, in: cg)
                }
            case .micBars:
                let bw = 0.12 * R
                let gap = 0.08 * R
                let total = 5 * bw + 4 * gap
                for i in 0..<5 {
                    let level = i < a.levels.count ? a.levels[i] : 0
                    let hgt = R * CGFloat(0.22 + 0.9 * level)
                    let x = -total / 2 + CGFloat(i) * (bw + gap)
                    let bar = CGPath(roundedRect: CGRect(x: x, y: -hgt / 2, width: bw, height: hgt), cornerWidth: bw / 2, cornerHeight: bw / 2, transform: nil)
                    fill(bar, mid, 0.95, in: cg)
                }
            case .recDot:
                let r = 0.14 * R
                let o = 0.55 + 0.45 * sin(2 * .pi * a.phase)
                fill(Self.ellipse(.zero, r, r), RGBA(hex: 0xFF3B30), o, in: cg)
                stroke(Self.ellipse(.zero, r * 1.6, r * 1.6), RGBA(hex: 0xFF3B30), 0.5, width: max(1, 0.03 * R), in: cg)
            }
            cg.restoreGState()
        }
    }

    // 11. Particles.
    func drawParticles(in cg: CGContext) {
        for p in frame.particles {
            let c = px(p.position)
            let t = CGFloat(p.progress)
            let size = CGFloat(p.size) * R
            switch p.kind {
            case .sparkle:
                let s = size * sin(t * .pi)
                cg.saveGState()
                cg.translateBy(x: c.x, y: c.y)
                cg.rotate(by: p.spin * p.age)
                fill(BodyPath.sparkle(center: .zero, radius: s).cgPath, .white, 0.95, in: cg)
                fill(Self.ellipse(.zero, s * 0.22, s * 0.22), mid, 0.9, in: cg)
                cg.restoreGState()
            case .heart:
                cg.saveGState()
                cg.translateBy(x: c.x, y: c.y)
                cg.rotate(by: sin(p.age * 3 + p.seed * 6) * 0.3)
                fill(BodyPath.heart(center: .zero, size: size * (0.7 + 0.3 * sin(t * .pi))).cgPath, theme.blush, 1 - t * t, in: cg)
                cg.restoreGState()
            case .star:
                cg.saveGState()
                cg.translateBy(x: c.x, y: c.y)
                cg.rotate(by: p.spin * p.age)
                fill(BodyPath.star(center: .zero, radius: size * (1 - t * 0.3)).cgPath, theme.star, 1 - t, in: cg)
                cg.restoreGState()
            case .zzz:
                let s = size * (1 + t * 0.9) * 0.5
                let z = CGMutablePath()
                z.move(to: CGPoint(x: c.x - 0.55 * s, y: c.y - 0.5 * s))
                z.addLine(to: CGPoint(x: c.x + 0.55 * s, y: c.y - 0.5 * s))
                z.addLine(to: CGPoint(x: c.x - 0.55 * s, y: c.y + 0.5 * s))
                z.addLine(to: CGPoint(x: c.x + 0.55 * s, y: c.y + 0.5 * s))
                stroke(z, theme.core, (1 - t) * 0.9, width: max(1, 0.22 * s), in: cg)
            case .drop:
                fill(BodyPath.teardrop(center: c, radius: size * 0.55).cgPath, mid, 0.95 * (1 - t * t), in: cg)
                fill(Self.ellipse(CGPoint(x: c.x - size * 0.12, y: c.y - size * 0.08), size * 0.1, size * 0.1), .white, 0.8 * (1 - t), in: cg)
            case .dust:
                let r = size * (1 + t * 0.8)
                fill(Self.ellipse(c, r, r), .white, 0.35 * (1 - t), in: cg)
            case .wisp, .spark, .glint, .drip, .bubble:
                drawSurfaceParticle(p, in: cg)
            case .steam:
                let r = size * (0.6 + 0.7 * t)
                let o = 0.55 * (1 - t) * min(1, 4 * Double(t) + 0.3)
                fill(Self.ellipse(c, r, r * 0.85), .white, o, in: cg)
                fill(Self.ellipse(CGPoint(x: c.x - r * 0.6, y: c.y + r * 0.25), r * 0.7, r * 0.6), .white, o, in: cg)
                fill(Self.ellipse(CGPoint(x: c.x + r * 0.6, y: c.y + r * 0.3), r * 0.65, r * 0.55), .white, o, in: cg)
            case .crumb:
                let s = size * (1 - t * 0.4)
                cg.saveGState()
                cg.translateBy(x: c.x, y: c.y)
                cg.rotate(by: p.spin * p.age + p.seed * 3)
                fill(CGPath(rect: CGRect(x: -s * 0.5, y: -s * 0.4, width: s, height: s * 0.8), transform: nil), RGBA(hex: 0xFFF6E8), 0.95 * (1 - t * t), in: cg)
                cg.restoreGState()
            }
        }
    }
}
