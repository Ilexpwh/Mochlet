import Foundation
import simd

/// Rigid blob with root physics: split droplets and minis in flight.
public struct Droplet: Sendable, Equatable, Identifiable {
    public let id: Int
    public var position: SIMD2<Double>
    public var velocity: SIMD2<Double>
    public var radius: Double
    public var restitution: Double = 0.45
    public var friction: Double = 0.8
    public var bounces: Int = 0
    public var age: Double = 0

    public init(id: Int, position: SIMD2<Double>, velocity: SIMD2<Double>, radius: Double) {
        self.id = id
        self.position = position
        self.velocity = velocity
        self.radius = radius
    }

    /// Returns true when it bounced on the floor this step.
    public mutating func step(h: Double, gravity: Double) -> Bool {
        age += h
        velocity.y += gravity * h
        position += velocity * h
        let floor = -radius
        if position.y > floor {
            position.y = floor
            if velocity.y > 0 {
                velocity.y = -velocity.y * restitution
                velocity.x *= friction
                if abs(velocity.y) < 0.15 { velocity.y = 0 }
                bounces += 1
                return abs(velocity.y) > 0.3
            }
        }
        return false
    }

    public var speed: Double { simd_length(velocity) }

    /// Stretch along the velocity: 1 + 0.18·min(1, |v|/4).
    public var stretch: Double { 1 + 0.18 * min(1, speed / 4) }

    public var heading: Double { atan2(velocity.y, velocity.x) }
}
