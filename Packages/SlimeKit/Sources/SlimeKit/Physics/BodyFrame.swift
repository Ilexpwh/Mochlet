import Foundation
import simd

/// Least-squares affine fit of the current ring onto the reference ring. Everything drawn
/// "inside" the body (eyes, blush, core, highlights) is transformed by it so it rides the jelly.
public struct BodyFrame: Sendable, Equatable {
    public var matrix: simd_double2x2
    public var origin: SIMD2<Double>
    public var referenceCentroid: SIMD2<Double>
    /// Extents of the settled rest outline: its half-width and its height above the floor (R).
    /// Constant per look; the renderer and the arms scale their authored offsets by them.
    public var referenceHalfWidth: Double
    public var referenceTopHeight: Double

    public init(matrix: simd_double2x2, origin: SIMD2<Double>, referenceCentroid: SIMD2<Double>,
                referenceHalfWidth: Double = 1.17, referenceTopHeight: Double = 1.70) {
        self.matrix = matrix
        self.origin = origin
        self.referenceCentroid = referenceCentroid
        self.referenceHalfWidth = referenceHalfWidth
        self.referenceTopHeight = referenceTopHeight
    }

    public static let identity = BodyFrame(matrix: matrix_identity_double2x2, origin: .zero, referenceCentroid: .zero)

    public static func fit(reference: [SIMD2<Double>], referenceCentroid rc: SIMD2<Double>, current: [SIMD2<Double>]) -> BodyFrame {
        let n = min(reference.count, current.count)
        var halfWidth = 0.0
        var top = 0.0
        for p in reference {
            halfWidth = max(halfWidth, abs(p.x))
            top = max(top, -p.y)
        }
        if halfWidth == 0 { halfWidth = 1.17 }
        if top == 0 { top = 1.70 }
        guard n >= 3 else {
            return BodyFrame(matrix: matrix_identity_double2x2, origin: current.first ?? .zero, referenceCentroid: rc,
                             referenceHalfWidth: halfWidth, referenceTopHeight: top)
        }
        var qc = SIMD2<Double>.zero
        for i in 0..<n { qc += current[i] }
        qc /= Double(n)
        var m = simd_double2x2(columns: (SIMD2<Double>.zero, SIMD2<Double>.zero))
        var nn = simd_double2x2(columns: (SIMD2<Double>.zero, SIMD2<Double>.zero))
        for i in 0..<n {
            let r = reference[i] - rc
            let q = current[i] - qc
            m += simd_double2x2(columns: (q * r.x, q * r.y))
            nn += simd_double2x2(columns: (r * r.x, r * r.y))
        }
        let det = nn.determinant
        let a = abs(det) > 1e-12 ? m * nn.inverse : matrix_identity_double2x2
        return BodyFrame(matrix: a, origin: qc, referenceCentroid: rc, referenceHalfWidth: halfWidth, referenceTopHeight: top)
    }

    /// Reference-local point (contact point = origin) to world.
    public func transform(_ local: SIMD2<Double>) -> SIMD2<Double> {
        matrix * (local - referenceCentroid) + origin
    }

    public func transformVector(_ v: SIMD2<Double>) -> SIMD2<Double> {
        matrix * v
    }

    public var scaleX: Double { simd_length(matrix.columns.0) }
    public var scaleY: Double { simd_length(matrix.columns.1) }
    public var rotation: Double { atan2(matrix.columns.0.y, matrix.columns.0.x) }
}
