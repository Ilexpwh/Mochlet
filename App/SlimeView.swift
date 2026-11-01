import SwiftUI

enum SlimeMood: String, CaseIterable { case idle, listening, working, chewing, attention, success, disconnected, error }

struct JellyShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        func q(_ x: CGFloat, _ y: CGFloat) -> CGPoint { .init(x: r.minX+x*r.width, y: r.minY+y*r.height) }
        p.move(to:q(0.17,0.83))
        p.addCurve(to:q(0.21,0.49),control1:q(0.06,0.76),control2:q(0.18,0.62))
        p.addCurve(to:q(0.51,0.13),control1:q(0.23,0.20),control2:q(0.34,0.10))
        p.addCurve(to:q(0.81,0.49),control1:q(0.70,0.07),control2:q(0.81,0.29))
        p.addCurve(to:q(0.85,0.85),control1:q(0.84,0.64),control2:q(0.97,0.80))
        p.addCurve(to:q(0.59,0.88),control1:q(0.75,0.94),control2:q(0.70,0.84))
        p.addCurve(to:q(0.32,0.89),control1:q(0.47,0.95),control2:q(0.42,0.85))
        p.addCurve(to:q(0.17,0.83),control1:q(0.18,0.94),control2:q(0.12,0.89)); p.closeSubpath();return p
    }
}

struct SlimeView: View {
    var mood: SlimeMood = .idle
    var tint: Color = .mint
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var blink = false
    @State private var lifted = false
    private let face = Color(red:0.07,green:0.23,blue:0.16)
    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width
            ZStack {
                Ellipse().fill(.black.opacity(0.09)).frame(width:s*0.57,height:s*0.06).offset(y:s*0.37)
                ZStack {
                    JellyShape().fill(LinearGradient(colors:[tint.opacity(0.45),tint,tint.mix(with:.black,by:0.15)],startPoint:.topLeading,endPoint:.bottomTrailing))
                    JellyShape().stroke(.white.opacity(0.24),lineWidth:1)
                    Capsule().fill(.white.opacity(0.45)).frame(width:s*0.22,height:s*0.04).rotationEffect(.degrees(-30)).offset(x:-s*0.13,y:-s*0.24)
                    HStack(spacing:s*0.23) {
                        ForEach(0..<2) { _ in
                            Capsule().fill(face).frame(width:s*0.045,height:blink ? s*0.018 : s*(mood == .attention ? 0.09 : 0.075))
                        }
                    }.offset(y:s*0.035)
                    mouth.frame(width:s*0.1,height:s*0.065).offset(y:s*0.16)
                    HStack(spacing:s*0.39) { ForEach(0..<2) { _ in Ellipse().fill(.pink.opacity(0.2)).frame(width:s*0.09,height:s*0.035) } }.offset(y:s*0.115)
                }
                .scaleEffect(x:lifted ? 1.025:1,y:lifted ? 0.975:1,anchor:.bottom)
                .rotationEffect(.degrees(mood == .attention ? -5 : 0))
                .saturation(mood == .disconnected ? 0.3:1)
            }
            .animation(reduceMotion ? nil:.spring(response:0.28,dampingFraction:0.7), value:mood)
            .animation(reduceMotion ? nil:.easeInOut(duration:0.18),value:blink)
            .animation(reduceMotion ? nil:.spring(response:0.5,dampingFraction:0.6),value:lifted)
        }
        .aspectRatio(1,contentMode:.fit)
        .accessibilityLabel("Slime, \(mood.rawValue)")
        .task(id: animated && !reduceMotion) {
            guard animated && !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for:.seconds(4.7)); guard !Task.isCancelled else { return }
                blink = true; lifted = mood == .working || mood == .chewing
                try? await Task.sleep(for:.milliseconds(150)); blink = false; lifted = false
            }
        }
    }
    @ViewBuilder private var mouth: some View {
        if mood == .listening || mood == .chewing { Ellipse().fill(face) }
        else { Path { p in p.move(to:.init(x:0,y:3));p.addQuadCurve(to:.init(x:12,y:3),control:.init(x:6,y:mood == .error ? -4:10)) }.stroke(face,style:.init(lineWidth:2,lineCap:.round)) }
    }
}
