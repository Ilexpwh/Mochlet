import SwiftUI

enum SlimeMood: String, CaseIterable {
    case idle, listening, working, chewing, attention, success, disconnected, error
}

/// An original, flat pebble silhouette: no feet, gloss, outline, or permanent mouth.
struct JellyShape: Shape {
    func path(in r: CGRect) -> Path {
        func q(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            .init(x: r.minX + x * r.width, y: r.minY + y * r.height)
        }
        var p = Path()
        p.move(to: q(0.50, 0.15))
        p.addCurve(to: q(0.88, 0.58), control1: q(0.75, 0.15), control2: q(0.86, 0.35))
        p.addCurve(to: q(0.71, 0.85), control1: q(0.94, 0.79), control2: q(0.84, 0.85))
        p.addCurve(to: q(0.29, 0.85), control1: q(0.57, 0.87), control2: q(0.43, 0.87))
        p.addCurve(to: q(0.12, 0.58), control1: q(0.16, 0.85), control2: q(0.06, 0.79))
        p.addCurve(to: q(0.50, 0.15), control1: q(0.14, 0.35), control2: q(0.25, 0.15))
        p.closeSubpath()
        return p
    }
}

struct SlimeView: View {
    var mood: SlimeMood = .idle
    var tint: Color = Color(red: 0.64, green: 0.88, blue: 0.75)
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var blink = false
    @State private var bounce = false
    @State private var gaze: CGSize = .zero
    private let face = Color(red: 0.10, green: 0.15, blue: 0.13)

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                JellyShape().fill(tint)
                HStack(spacing: s * 0.115) {
                    eye(size: s)
                    eye(size: s)
                }
                .offset(x: gaze.width, y: s * 0.045 + gaze.height)
                if mood == .chewing {
                    Capsule().fill(face).frame(width: s * 0.07, height: s * 0.045)
                        .offset(y: s * 0.17)
                }
            }
            .frame(width: s, height: s)
            .scaleEffect(x: bounce ? 1.045 : 1, y: bounce ? 0.95 : 1, anchor: .init(x: 0.5, y: 0.85))
            .rotationEffect(.degrees(mood == .attention ? -6 : mood == .error ? 5 : 0))
            .saturation(mood == .disconnected ? 0.1 : 1)
            .opacity(mood == .disconnected ? 0.65 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.65), value: mood)
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.58), value: bounce)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: blink)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: gaze)
            .onContinuousHover { phase in
                guard animated, !reduceMotion else { gaze = .zero; return }
                switch phase {
                case .active(let point):
                    gaze = .init(width: (point.x / max(s, 1) - 0.5) * s * 0.07,
                                 height: (point.y / max(s, 1) - 0.5) * s * 0.045)
                case .ended: gaze = .zero
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mochlet, \(mood.rawValue)")
        .task(id: "\(animated)-\(reduceMotion)-\(mood.rawValue)") {
            blink = false; bounce = false
            guard animated, !reduceMotion else { return }
            if mood == .success { bounce = true }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(mood == .working || mood == .chewing ? 1.6 : 4.6))
                    blink = true; bounce = mood == .working || mood == .chewing
                    try await Task.sleep(for: .milliseconds(140))
                    blink = false; bounce = false
                } catch { return }
            }
        }
    }

    @ViewBuilder private func eye(size: CGFloat) -> some View {
        if mood == .success {
            UnevenRoundedRectangle(topLeadingRadius: size * 0.04, topTrailingRadius: size * 0.04)
                .stroke(face, style: .init(lineWidth: max(1.5, size * 0.025), lineCap: .round))
                .frame(width: size * 0.075, height: size * 0.035)
        } else {
            Capsule().fill(face)
                .frame(width: size * 0.065,
                       height: blink ? size * 0.017 : size * (mood == .listening || mood == .attention ? 0.15 : 0.115))
        }
    }
}
