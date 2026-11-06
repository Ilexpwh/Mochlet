import SwiftUI
import SlimeKit

public enum BodyPath {
    /// Closed Catmull-Rom spline through the ring points, as cubic Béziers
    /// (c1 = P1 + (P2 − P0)/6, c2 = P2 − (P3 − P1)/6).
    /// A dense, already-smoothed loop (a goo contour) as straight segments: cheaper for
    /// CoreGraphics to clip, fill and stroke than cubics, and indistinguishable at ≈ 3 px spacing.
    public static func polyline(_ pts: [CGPoint]) -> Path {
        var path = Path()
        guard pts.count >= 3 else { return path }
        path.addLines(pts)
        path.closeSubpath()
        return path
    }

    public static func closed(through pts: [CGPoint]) -> Path {
        var path = Path()
        let n = pts.count
        guard n >= 3 else { return path }
        path.move(to: pts[0])
        for i in 0..<n {
            let p0 = pts[(i - 1 + n) % n]
            let p1 = pts[i]
            let p2 = pts[(i + 1) % n]
            let p3 = pts[(i + 2) % n]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        path.closeSubpath()
        return path
    }

    public static func heart(center: CGPoint, size: CGFloat) -> Path {
        let s = size
        var p = Path()
        p.move(to: CGPoint(x: center.x, y: center.y + s * 0.95))
        p.addCurve(to: CGPoint(x: center.x - s, y: center.y - s * 0.25),
                   control1: CGPoint(x: center.x - s * 0.9, y: center.y + s * 0.45),
                   control2: CGPoint(x: center.x - s * 1.05, y: center.y + s * 0.1))
        p.addArc(center: CGPoint(x: center.x - s * 0.5, y: center.y - s * 0.3), radius: s * 0.5,
                 startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        p.addArc(center: CGPoint(x: center.x + s * 0.5, y: center.y - s * 0.3), radius: s * 0.5,
                 startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        p.addCurve(to: CGPoint(x: center.x, y: center.y + s * 0.95),
                   control1: CGPoint(x: center.x + s * 1.05, y: center.y + s * 0.1),
                   control2: CGPoint(x: center.x + s * 0.9, y: center.y + s * 0.45))
        p.closeSubpath()
        return p
    }

    public static func star(center: CGPoint, radius: CGFloat, points: Int = 5, inner: CGFloat = 0.45, rotation: CGFloat = -.pi / 2) -> Path {
        var p = Path()
        for i in 0..<(points * 2) {
            let r = i % 2 == 0 ? radius : radius * inner
            let a = rotation + CGFloat(i) * .pi / CGFloat(points)
            let pt = CGPoint(x: center.x + cos(a) * r, y: center.y + sin(a) * r)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }

    public static func sparkle(center: CGPoint, radius: CGFloat) -> Path {
        var p = Path()
        let r = radius
        let w = radius * 0.22
        p.move(to: CGPoint(x: center.x, y: center.y - r))
        p.addQuadCurve(to: CGPoint(x: center.x + r, y: center.y), control: CGPoint(x: center.x + w, y: center.y - w))
        p.addQuadCurve(to: CGPoint(x: center.x, y: center.y + r), control: CGPoint(x: center.x + w, y: center.y + w))
        p.addQuadCurve(to: CGPoint(x: center.x - r, y: center.y), control: CGPoint(x: center.x - w, y: center.y + w))
        p.addQuadCurve(to: CGPoint(x: center.x, y: center.y - r), control: CGPoint(x: center.x - w, y: center.y - w))
        p.closeSubpath()
        return p
    }

    public static func teardrop(center: CGPoint, radius: CGFloat) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: center.x, y: center.y - radius * 1.6))
        p.addQuadCurve(to: CGPoint(x: center.x + radius, y: center.y + radius * 0.2), control: CGPoint(x: center.x + radius * 0.9, y: center.y - radius * 0.6))
        p.addArc(center: CGPoint(x: center.x, y: center.y + radius * 0.2), radius: radius, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
        p.addQuadCurve(to: CGPoint(x: center.x, y: center.y - radius * 1.6), control: CGPoint(x: center.x - radius * 0.9, y: center.y - radius * 0.6))
        p.closeSubpath()
        return p
    }
}

public extension Color {
    init(_ c: RGBA) {
        self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
    }
}
