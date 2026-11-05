import Foundation

/// xorshift128+ generator seeded explicitly, so every engine, filmstrip and test is reproducible.
public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var s0: UInt64
    private var s1: UInt64

    public init(seed: UInt64) {
        var z = seed
        func splitmix() -> UInt64 {
            z &+= 0x9E37_79B9_7F4A_7C15
            var x = z
            x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
            x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
            return x ^ (x >> 31)
        }
        s0 = splitmix()
        s1 = splitmix()
        if s0 == 0 && s1 == 0 { s1 = 1 }
    }

    public mutating func next() -> UInt64 {
        var x = s0
        let y = s1
        s0 = y
        x ^= x << 23
        s1 = x ^ y ^ (x >> 17) ^ (y >> 26)
        return s1 &+ y
    }

    /// Uniform in [0, 1).
    public mutating func unit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    public mutating func range(_ r: ClosedRange<Double>) -> Double {
        r.lowerBound + (r.upperBound - r.lowerBound) * unit()
    }

    public mutating func chance(_ p: Double) -> Bool { unit() < p }

    /// -1 or +1.
    public mutating func sign() -> Double { unit() < 0.5 ? -1 : 1 }

    public mutating func int(_ r: Range<Int>) -> Int {
        guard r.count > 0 else { return r.lowerBound }
        return r.lowerBound + Int(unit() * Double(r.count))
    }
}

/// 1-D smooth value noise in [-1, 1], hashed from a seed (no tables).
public struct ValueNoise: Sendable, Equatable {
    private let seed: UInt64

    public init(seed: UInt64) { self.seed = seed }

    private func lattice(_ i: Int64) -> Double {
        var x = (UInt64(bitPattern: i) &* 0x9E37_79B9_7F4A_7C15) ^ seed
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        x ^= x >> 31
        return Double(x >> 11) * (1.0 / 9_007_199_254_740_992.0) * 2 - 1
    }

    public func value(at t: Double) -> Double {
        let f = floor(t)
        let i = Int64(f)
        let u = t - f
        let s = u * u * (3 - 2 * u)
        return lattice(i) * (1 - s) + lattice(i + 1) * s
    }
}
