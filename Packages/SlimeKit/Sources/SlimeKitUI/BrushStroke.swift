import CoreGraphics
import Foundation

/// Tapered ink strokes for the anime face: a centre polyline becomes a closed shape whose width
/// swells in the middle and thins to a point at both ends, like one pull of a brush.
enum BrushStroke {
    /// `halfWidth` is the half-width at the middle; the ends keep `minimum` of it before the tip.
    static func path(along pts: [CGPoint], halfWidth: CGFloat, minimum: CGFloat = 0.3, power: Double = 1.6) -> CGPath {
        let path = CGMutablePath()
        guard pts.count >= 2, let last = pts.last else { return path }
        var arc: [CGFloat] = [0]
        arc.reserveCapacity(pts.count)
        for i in 1..<pts.count { arc.append(arc[i - 1] + hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)) }
        let total = max(arc[arc.count - 1], 1e-6)
        var left: [CGPoint] = []
        var right: [CGPoint] = []
        left.reserveCapacity(pts.count)
        right.reserveCapacity(pts.count)
        for i in pts.indices {
            let prev = pts[max(0, i - 1)]
            let next = pts[min(pts.count - 1, i + 1)]
            var tx = next.x - prev.x
            var ty = next.y - prev.y
            let len = hypot(tx, ty)
            if len < 1e-9 { tx = 1; ty = 0 } else { tx /= len; ty /= len }
            let t = Double(arc[i] / total)
            let weight = max(Double(minimum), 1 - pow(abs(2 * t - 1), power))
            let w = halfWidth * CGFloat(weight)
            left.append(CGPoint(x: pts[i].x - ty * w, y: pts[i].y + tx * w))
            right.append(CGPoint(x: pts[i].x + ty * w, y: pts[i].y - tx * w))
        }
        path.move(to: pts[0])
        for q in left { path.addLine(to: q) }
        path.addLine(to: last)
        for q in right.reversed() { path.addLine(to: q) }
        path.closeSubpath()
        return path
    }
}
