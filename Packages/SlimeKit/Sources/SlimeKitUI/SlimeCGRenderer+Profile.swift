import CoreGraphics
import Foundation
import SwiftUI
import SlimeKit

extension SlimeCGRenderer {
    /// One draw split into its stages with the wall time of each, for `slimekit-tools bench`.
    /// Same work as `draw(in:)`, so the sum is the cost of a frame.
    public static func stageTimings(_ frame: SlimeFrame, appearance: SlimeAppearance, in cg: CGContext,
                                    origin: CGPoint, radius: CGFloat) -> [(String, Double)] {
        let r = SlimeCGRenderer(frame: frame, appearance: appearance, origin: origin, radius: radius)
        var out: [(String, Double)] = []
        func t(_ name: String, _ body: () -> Void) {
            let a = Date.timeIntervalSinceReferenceDate
            body()
            out.append((name, (Date.timeIntervalSinceReferenceDate - a) * 1000))
        }
        cg.saveGState()
        cg.setAlpha(frame.opacity * (1 - clamp(appearance.look.transparency, 0, 0.8)))
        let liveBlobs = frame.blobs.filter { $0.radius > 1e-3 }
        var bodyPath = CGPath(rect: .zero, transform: nil)
        t("contour+bodyPath") {
            if liveBlobs.isEmpty {
                bodyPath = BodyPath.closed(through: frame.ring.map(r.px)).cgPath
            } else {
                let loops = ContourCache.contour(ring: frame.ring, blobs: liveBlobs, options: .forScale(pixelsPerUnit: Double(radius)), pixelsPerUnit: Double(radius))
                if loops.isEmpty {
                    bodyPath = BodyPath.closed(through: frame.ring.map(r.px)).cgPath
                } else {
                    var p = Path()
                    for loop in loops { p.addPath(BodyPath.polyline(loop.map(r.px))) }
                    bodyPath = p.cgPath
                }
            }
        }
        t("glow") { r.drawGlow(in: cg) }
        t("backTraits") { r.drawBackTraits(in: cg) }
        t("bodyFill") { r.drawBodyFill(in: cg, bodyPath: bodyPath, goo: !liveBlobs.isEmpty) }
        t("face") { r.drawFace(in: cg, bodyPath: bodyPath) }
        t("eyewear") { r.drawEyewear(in: cg) }
        t("frontTraits") { r.drawFrontTraits(in: cg) }
        t("props") { r.drawProps(behindHands: true, in: cg); r.drawProps(behindHands: false, in: cg) }
        t("arms") { r.drawArms(in: cg, bodyPath: bodyPath) }
        t("accessories") { r.drawAccessories(in: cg) }
        t("particles") { r.drawParticles(in: cg) }
        cg.restoreGState()
        return out
    }
}
