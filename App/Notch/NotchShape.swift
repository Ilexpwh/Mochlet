import SwiftUI

/// The island outline. `topRadius` ≥ 0 gives convex rounded top corners (expanded); < 0 gives
/// concave "ears" that blend the compact strip into the notch.
struct NotchShape: Shape {
    var width: CGFloat
    var height: CGFloat
    var cornerRadius: CGFloat
    var topRadius: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat>, CGFloat> {
        get { .init(.init(.init(width, height), cornerRadius), topRadius) }
        set {
            width = newValue.first.first.first
            height = newValue.first.first.second
            cornerRadius = newValue.first.second
            topRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let cr = max(0, min(cornerRadius, min(width / 2, height / 2)))
        var p = Path()
        if topRadius >= 0 {
            let tr = min(topRadius, min(width / 2, height / 2))
            p.move(to: CGPoint(x: tr, y: 0))
            p.addLine(to: CGPoint(x: width - tr, y: 0))
            p.addArc(center: CGPoint(x: width - tr, y: tr), radius: tr, startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
            p.addLine(to: CGPoint(x: width, y: height - cr))
            p.addArc(center: CGPoint(x: width - cr, y: height - cr), radius: cr, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            p.addLine(to: CGPoint(x: cr, y: height))
            p.addArc(center: CGPoint(x: cr, y: height - cr), radius: cr, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            p.addLine(to: CGPoint(x: 0, y: tr))
            p.addArc(center: CGPoint(x: tr, y: tr), radius: tr, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        } else {
            let er = -topRadius
            p.move(to: CGPoint(x: 0, y: 0))
            p.addArc(center: CGPoint(x: 0, y: er), radius: er, startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
            p.addLine(to: CGPoint(x: width - er, y: er))
            p.addArc(center: CGPoint(x: width, y: er), radius: er, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
            p.addLine(to: CGPoint(x: width, y: height - cr))
            p.addArc(center: CGPoint(x: width - cr, y: height - cr), radius: cr, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            p.addLine(to: CGPoint(x: cr, y: height))
            p.addArc(center: CGPoint(x: cr, y: height - cr), radius: cr, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            p.addLine(to: CGPoint(x: 0, y: 0))
        }
        p.closeSubpath()
        return p
    }
}
