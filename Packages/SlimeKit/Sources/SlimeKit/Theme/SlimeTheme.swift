import Foundation

public struct RGBA: Sendable, Codable, Equatable, Hashable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    public init(hex: UInt32, alpha: Double = 1) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
        a = alpha
    }

    public func opacity(_ o: Double) -> RGBA { RGBA(r: r, g: g, b: b, a: a * o) }

    public func mixed(with other: RGBA, _ t: Double) -> RGBA {
        let k = clamp(t, 0, 1)
        return RGBA(r: r + (other.r - r) * k, g: g + (other.g - g) * k, b: b + (other.b - b) * k, a: a + (other.a - a) * k)
    }

    public var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    public func desaturated(_ amount: Double) -> RGBA {
        let l = luminance
        return mixed(with: RGBA(r: l, g: l, b: l, a: a), amount)
    }

    public static let white = RGBA(r: 1, g: 1, b: 1)
    public static let black = RGBA(r: 0, g: 0, b: 0)
    public static let clear = RGBA(r: 0, g: 0, b: 0, a: 0)
}

/// Body colours. Rimuru is the default: a glossy sky-blue jelly with pink blush and navy ink.
public struct SlimeTheme: Sendable, Codable, Equatable, Hashable, Identifiable {
    public var name: String
    public var core: RGBA
    public var mid: RGBA
    public var rim: RGBA
    public var deep: RGBA
    public var highlight: RGBA
    public var blush: RGBA
    public var ink: RGBA

    public var id: String { name }

    public init(name: String, core: RGBA, mid: RGBA, rim: RGBA, deep: RGBA, highlight: RGBA = .white, blush: RGBA, ink: RGBA) {
        self.name = name
        self.core = core; self.mid = mid; self.rim = rim; self.deep = deep
        self.highlight = highlight; self.blush = blush; self.ink = ink
    }

    public static let rimuru = SlimeTheme(
        name: "rimuru",
        core: RGBA(hex: 0xD6F6FF), mid: RGBA(hex: 0x7FD4FF), rim: RGBA(hex: 0x2F8FE0), deep: RGBA(hex: 0x1C6BC2),
        blush: RGBA(hex: 0xFFA3BE), ink: RGBA(hex: 0x1F2D47))

    public static let peach = SlimeTheme(
        name: "peach",
        core: RGBA(hex: 0xFFF1E6), mid: RGBA(hex: 0xFFC2A1), rim: RGBA(hex: 0xF28B6A), deep: RGBA(hex: 0xD9603F),
        blush: RGBA(hex: 0xFF8FA3), ink: RGBA(hex: 0x4A2A24))

    public static let mint = SlimeTheme(
        name: "mint",
        core: RGBA(hex: 0xE6FFF6), mid: RGBA(hex: 0x9BEFD0), rim: RGBA(hex: 0x3FC9A0), deep: RGBA(hex: 0x1F9A78),
        blush: RGBA(hex: 0xFFB0C8), ink: RGBA(hex: 0x1E3A33))

    public static let lilac = SlimeTheme(
        name: "lilac",
        core: RGBA(hex: 0xF4ECFF), mid: RGBA(hex: 0xD0B4FF), rim: RGBA(hex: 0x9A6BF0), deep: RGBA(hex: 0x6E44C8),
        blush: RGBA(hex: 0xFFA3D6), ink: RGBA(hex: 0x2E2345))

    public static let lemon = SlimeTheme(
        name: "lemon",
        core: RGBA(hex: 0xFFFBE0), mid: RGBA(hex: 0xFFE98A), rim: RGBA(hex: 0xF2C84B), deep: RGBA(hex: 0xD6A21E),
        blush: RGBA(hex: 0xFFA3A3), ink: RGBA(hex: 0x4A3A12))

    public static let all: [SlimeTheme] = [.rimuru, .peach, .mint, .lilac, .lemon]

    public static func named(_ name: String) -> SlimeTheme {
        all.first { $0.name == name } ?? .rimuru
    }
}

/// Transient colour overlays: state tints on rim/deep, desaturation while sleeping.
public struct StateTint: Sendable, Equatable {
    public var color: RGBA
    public var opacity: Double
    public var desaturation: Double

    public init(color: RGBA = .clear, opacity: Double = 0, desaturation: Double = 0) {
        self.color = color; self.opacity = opacity; self.desaturation = desaturation
    }

    public static let none = StateTint()
    public static let error = StateTint(color: RGBA(hex: 0xF0506A), opacity: 0.5)
    public static let thinking = StateTint(color: RGBA(hex: 0xB39CFF), opacity: 0.15)
    public static let waiting = StateTint(color: RGBA(hex: 0xFFC14D), opacity: 0.25)
    public static let sleeping = StateTint(desaturation: 0.30)
    public static let dizzy = StateTint(color: RGBA(hex: 0xFF9AD5), opacity: 0.30)
}
