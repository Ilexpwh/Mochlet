import Foundation

/// 1 + A·sin(phase) + A·0.35·noise. Phase accumulates so rate changes never jump.
public struct BreathOscillator: Sendable, Equatable {
    public var amplitude = AnimatedValue(0.02)
    public var rate = AnimatedValue(0.21)
    public var noiseWeight: Double = 0.35
    public private(set) var value: Double = 1
    private var phase: Double
    private let noise: ValueNoise

    public init(seed: UInt64, phase: Double = 0) {
        noise = ValueNoise(seed: seed &+ 77)
        self.phase = phase
        let a = amplitude.value
        value = 1 + a * sin(phase) + a * noiseWeight * noise.value(at: 0)
    }

    public mutating func advance(dt: Double, time: Double) {
        amplitude.advance(to: time)
        rate.advance(to: time)
        phase += 2 * .pi * rate.value * dt
        let a = amplitude.value
        value = 1 + a * sin(phase) + a * noiseWeight * noise.value(at: time * 0.4)
    }
}
