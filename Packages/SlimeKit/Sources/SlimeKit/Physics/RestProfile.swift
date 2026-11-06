import Foundation
import simd

/// The resting outline of a slime body (R units, floor at y = 0, y down): an ellipse with optional
/// bumps and a pinched tip, sampled into the soft body's rest ring. The classic dome is the unit
/// circle centred at −0.86; the floor clamp and the pressure make the contact patch by themselves.
public struct RestProfile: Sendable, Equatable {
    public struct Bump: Sendable, Equatable {
        /// Angle from the top: −π/2 is the top, 0 the right side, π/2 the bottom.
        public var angle: Double
        public var amplitude: Double
        public var width: Double
        public init(angle: Double, amplitude: Double, width: Double) {
            self.angle = angle; self.amplitude = amplitude; self.width = width
        }
    }

    public var width: Double = 1
    public var height: Double = 1
    public var centerY: Double = -0.86
    /// Upward pull and pinch of the top (teardrop).
    public var tip: Double = 0
    public var bumps: [Bump] = []
    /// Ring points this outline wants (bumps need more).
    public var pointCount: Int = 24

    public init() {}

    public static let dome = RestProfile()

    /// Height of the outline above the floor before settling.
    public var topHeight: Double { height - centerY + tip }

    public static func forSilhouette(_ s: SlimeLook.Silhouette, mini: Bool = false) -> RestProfile {
        var p = RestProfile()
        switch s {
        case .dome:
            p.pointCount = mini ? 16 : 24
        case .drop:
            p.width = 0.96
            p.tip = 0.32
            p.pointCount = mini ? 18 : 28
        case .puddle:
            p.width = 1.28
            p.height = 0.80
            p.centerY = -0.70
            p.pointCount = mini ? 18 : 28
        case .loaf:
            p.width = 1.12
            p.height = 0.95
            p.centerY = -0.82
            p.pointCount = mini ? 16 : 24
        case .spiky:
            let top = -Double.pi / 2
            p.bumps = [0, -0.75, 0.75, -1.5, 1.5].map { Bump(angle: top + $0, amplitude: 0.13, width: 0.17) }
            p.pointCount = mini ? 24 : 36
        case .tall:
            p.width = 0.9
            p.height = 1.1
            p.centerY = -0.95
            p.pointCount = mini ? 16 : 24
        }
        return p
    }

    /// Smallest signed difference between two angles.
    static func angleDelta(_ a: Double, _ b: Double) -> Double {
        var d = (a - b).truncatingRemainder(dividingBy: 2 * .pi)
        if d > .pi { d -= 2 * .pi }
        if d < -.pi { d += 2 * .pi }
        return d
    }

    /// The rest ring, point i at angle −π/2 + 2πi/n (clockwise on screen from the top).
    public func ring(count n: Int) -> [SIMD2<Double>] {
        var out: [SIMD2<Double>] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let theta = -Double.pi / 2 + 2 * Double.pi * Double(i) / Double(n)
            var r = 1.0
            for b in bumps {
                let d = Self.angleDelta(theta, b.angle)
                r += b.amplitude * exp(-(d * d) / (b.width * b.width))
            }
            var x = width * cos(theta) * r
            var y = height * sin(theta) * r
            if tip > 0 {
                let d = Self.angleDelta(theta, -Double.pi / 2)
                let t = exp(-(d * d) / 0.25)
                y -= tip * t
                x *= 1 - 0.45 * t
            }
            out.append(SIMD2(x, centerY + y))
        }
        return out
    }
}
