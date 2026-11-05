import Foundation
import simd

/// Damped spring on a scalar: omega = angular frequency (rad/s), zeta = damping ratio.
public struct Spring1D: Sendable, Equatable {
    public var value: Double
    public var velocity: Double = 0
    public var target: Double
    public var omega: Double
    public var zeta: Double

    public init(value: Double, omega: Double, zeta: Double) {
        self.value = value
        self.target = value
        self.omega = omega
        self.zeta = zeta
    }

    /// SwiftUI-style parameters: response = period of the undamped spring in seconds.
    public init(value: Double, response: Double, dampingFraction: Double) {
        self.init(value: value, omega: 2 * .pi / max(1e-3, response), zeta: dampingFraction)
    }

    public mutating func advance(_ h: Double) {
        let a = -omega * omega * (value - target) - 2 * zeta * omega * velocity
        velocity += a * h
        value += velocity * h
    }

    public mutating func snap(to v: Double) {
        value = v; target = v; velocity = 0
    }
}

public struct Spring2D: Sendable, Equatable {
    public var value: SIMD2<Double>
    public var velocity: SIMD2<Double> = .zero
    public var target: SIMD2<Double>
    public var omega: Double
    public var zeta: Double

    public init(value: SIMD2<Double>, omega: Double, zeta: Double) {
        self.value = value
        self.target = value
        self.omega = omega
        self.zeta = zeta
    }

    public init(value: SIMD2<Double>, response: Double, dampingFraction: Double) {
        self.init(value: value, omega: 2 * .pi / max(1e-3, response), zeta: dampingFraction)
    }

    public mutating func advance(_ h: Double) {
        let a = (value - target) * (-omega * omega) - velocity * (2 * zeta * omega)
        velocity += a * h
        value += velocity * h
    }

    public mutating func snap(to v: SIMD2<Double>) {
        value = v; target = v; velocity = .zero
    }
}
