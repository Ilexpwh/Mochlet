import CoreGraphics
import Foundation
import SwiftUI
import SlimeKit

// Marks that grow out of the body as slime (`GlyphStyle.grown`): the stalk is part of the goo
// silhouette (blobs from the engine); the glyph itself is a filled path in the same jelly material
// with a cel shadow, rim line and highlight, so a "?" reads as a piece of the slime, not a bubble.
extension SlimeCGRenderer {
    /// The hooked "?" from the anime as a filled outline, centred on the glyph's middle.
    static func questionGlyph(scale R: CGFloat, stroke w: CGFloat) -> CGPath {
        let g = CGMutablePath()
        g.move(to: CGPoint(x: -0.26 * R, y: -0.2 * R))
        g.addCurve(to: CGPoint(x: 0.26 * R, y: -0.2 * R),
                   control1: CGPoint(x: -0.26 * R, y: -0.6 * R), control2: CGPoint(x: 0.26 * R, y: -0.6 * R))
        g.addQuadCurve(to: CGPoint(x: 0, y: 0.08 * R), control: CGPoint(x: 0.3 * R, y: 0.06 * R))
        g.addLine(to: CGPoint(x: 0, y: 0.17 * R))
        let hook = g.copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 10).normalized(using: .winding)
        let dot = CGPath(ellipseIn: CGRect(x: -0.1 * R, y: 0.3 * R, width: 0.2 * R, height: 0.2 * R), transform: nil)
        return hook.union(dot)
    }

    /// Bar-and-dot "!".
    static func exclamationGlyph(scale R: CGFloat, stroke w: CGFloat) -> CGPath {
        let bar = CGMutablePath()
        bar.move(to: CGPoint(x: 0, y: -0.42 * R))
        bar.addLine(to: CGPoint(x: 0, y: 0.1 * R))
        let b = bar.copy(strokingWithWidth: w * 1.15, lineCap: .round, lineJoin: .round, miterLimit: 10).normalized(using: .winding)
        let dot = CGPath(ellipseIn: CGRect(x: -0.105 * R, y: 0.29 * R, width: 0.21 * R, height: 0.21 * R), transform: nil)
        return b.union(dot)
    }

    /// An eighth note "♪": tilted oval head, stem and a flag curling to the right.
    static func noteGlyph(scale R: CGFloat, stroke w: CGFloat) -> CGPath {
        let stem = CGMutablePath()
        stem.move(to: CGPoint(x: 0.04 * R, y: 0.3 * R))
        stem.addLine(to: CGPoint(x: 0.04 * R, y: -0.42 * R))
        stem.addQuadCurve(to: CGPoint(x: 0.3 * R, y: -0.1 * R), control: CGPoint(x: 0.08 * R, y: -0.22 * R))
        let s = stem.copy(strokingWithWidth: w * 0.85, lineCap: .round, lineJoin: .round, miterLimit: 10).normalized(using: .winding)
        var t = CGAffineTransform(translationX: -0.1 * R, y: 0.32 * R).rotated(by: -0.35)
        let head = CGPath(ellipseIn: CGRect(x: -0.19 * R, y: -0.13 * R, width: 0.38 * R, height: 0.26 * R), transform: &t)
        return s.union(head)
    }

    /// Glyph outline and its cel-shadow band for a kind at a size. The path booleans are not cheap,
    /// and the result depends only on (kind, R), so it is built once per size.
    nonisolated(unsafe) private static var glyphCache: [String: (path: CGPath, shade: CGPath)] = [:]
    private static let glyphLock = NSLock()

    static func grownGlyph(_ kind: AccessoryKind, scale R: CGFloat) -> (path: CGPath, shade: CGPath)? {
        let key = "\(kind.rawValue)@\(Int((R * 4).rounded()))"
        glyphLock.lock()
        defer { glyphLock.unlock() }
        if let hit = glyphCache[key] { return hit }
        let path: CGPath
        switch kind {
        case .question: path = questionGlyph(scale: R, stroke: 0.17 * R)
        case .exclamation: path = exclamationGlyph(scale: R, stroke: 0.17 * R)
        case .note: path = noteGlyph(scale: R, stroke: 0.15 * R)
        default: return nil
        }
        var lit = CGAffineTransform(translationX: -0.055 * R, y: -0.085 * R)
        let shade = path.copy(using: &lit).map { path.subtracting($0) } ?? CGMutablePath()
        if glyphCache.count > 24 { glyphCache.removeAll() }
        glyphCache[key] = (path, shade)
        return (path, shade)
    }

    func drawGrownGlyph(_ kind: AccessoryKind, in cg: CGContext) {
        guard let (path, shade) = Self.grownGlyph(kind, scale: R) else { return }
        // Jelly fill: light from the top-left, a flat cel shadow toward the bottom-right.
        fillRadial(path, [(core.mixed(with: mid, 0.25), 0), (mid, 0.7), (mid.mixed(with: rim, 0.4), 1)],
                   center: CGPoint(x: -0.16 * R, y: -0.26 * R), radius: 0.8 * R, in: cg)
        cg.saveGState()
        cg.addPath(path)
        cg.clip()
        fill(shade, jellyShade, 0.8, in: cg)
        cg.restoreGState()
        stroke(path, inkLine, 0.8, width: max(1, 0.03 * R), in: cg)
        // One soft highlight near the top of the glyph.
        fill(Self.ellipse(CGPoint(x: -0.1 * R, y: -0.36 * R), 0.07 * R, 0.045 * R), theme.highlight, 0.85, in: cg)
    }
}
