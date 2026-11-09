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

    /// Hue in degrees (0…360), saturation and lightness in 0…1 (HSL).
    public init(hue: Double, saturation: Double, lightness: Double, alpha: Double = 1) {
        let h = ((hue.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360) / 360
        let s = clamp(saturation, 0, 1)
        let l = clamp(lightness, 0, 1)
        if s == 0 {
            self.init(r: l, g: l, b: l, a: alpha)
            return
        }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func channel(_ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        self.init(r: channel(h + 1.0 / 3), g: channel(h), b: channel(h - 1.0 / 3), a: alpha)
    }

    /// (hue degrees, saturation, lightness).
    public var hsl: (hue: Double, saturation: Double, lightness: Double) {
        let mx = max(r, g, b), mn = min(r, g, b)
        let l = (mx + mn) / 2
        guard mx > mn else { return (0, 0, l) }
        let d = mx - mn
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Double
        if mx == r { h = (g - b) / d + (g < b ? 6 : 0) } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
        h *= 60
        return (h, s, l)
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

    /// Lightness scaled in HSL space (1 = unchanged).
    public func lightened(_ factor: Double) -> RGBA {
        let c = hsl
        return RGBA(hue: c.hue, saturation: c.saturation, lightness: clamp(c.lightness * factor, 0, 1), alpha: a)
    }

    public var hex: UInt32 {
        (UInt32(clamp(r, 0, 1) * 255 + 0.5) << 16) | (UInt32(clamp(g, 0, 1) * 255 + 0.5) << 8) | UInt32(clamp(b, 0, 1) * 255 + 0.5)
    }

    public static let white = RGBA(r: 1, g: 1, b: 1)
    public static let black = RGBA(r: 0, g: 0, b: 0)
    public static let clear = RGBA(r: 0, g: 0, b: 0, a: 0)
}

/// Body colours (the "Colour" of a slime). Rimuru is the default: a glossy sky-blue jelly with
/// pink blush and navy ink. `accent` colours the `!` mark, stars and bells; `tongue` the open mouth.
public struct SlimeTheme: Sendable, Codable, Equatable, Hashable, Identifiable {
    public var name: String
    public var core: RGBA
    public var mid: RGBA
    public var rim: RGBA
    public var deep: RGBA
    public var highlight: RGBA
    public var blush: RGBA
    public var ink: RGBA
    public var accent: RGBA
    public var tongue: RGBA

    public var id: String { name }

    public init(name: String, core: RGBA, mid: RGBA, rim: RGBA, deep: RGBA, highlight: RGBA = .white, blush: RGBA, ink: RGBA,
                accent: RGBA = RGBA(hex: 0xFFC14D), tongue: RGBA = RGBA(hex: 0xE2607F)) {
        self.name = name
        self.core = core; self.mid = mid; self.rim = rim; self.deep = deep
        self.highlight = highlight; self.blush = blush; self.ink = ink
        self.accent = accent; self.tongue = tongue
    }

    enum CodingKeys: String, CodingKey { case name, core, mid, rim, deep, highlight, blush, ink, accent, tongue }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        core = try c.decode(RGBA.self, forKey: .core)
        mid = try c.decode(RGBA.self, forKey: .mid)
        rim = try c.decode(RGBA.self, forKey: .rim)
        deep = try c.decode(RGBA.self, forKey: .deep)
        highlight = try c.decodeIfPresent(RGBA.self, forKey: .highlight) ?? .white
        blush = try c.decode(RGBA.self, forKey: .blush)
        ink = try c.decode(RGBA.self, forKey: .ink)
        accent = try c.decodeIfPresent(RGBA.self, forKey: .accent) ?? RGBA(hex: 0xFFC14D)
        tongue = try c.decodeIfPresent(RGBA.self, forKey: .tongue) ?? RGBA(hex: 0xE2607F)
    }

    // MARK: Material

    /// The two-layer translucent cel material the renderer paints a palette with, as in the
    /// anime: a pale flat shell, a darker inner mass with paler windows, one ink line, a thin
    /// band of reflected light along the lower edge and a soft glow on the floor.
    public struct Material: Sendable, Equatable {
        public var shell: RGBA
        public var inner: RGBA
        /// Alpha included: the pale windows inside the inner mass.
        public var window: RGBA
        /// Alpha included: the outline and the ink of features drawn in the body's own tint.
        public var inkLine: RGBA
        /// Alpha included: light coming back through the jelly along the lower-right edge.
        public var rimLight: RGBA
        /// Alpha included: the contact glow under the body on a dark surface.
        public var glow: RGBA
        public var highlight: RGBA
    }

    /// The material under a transient tint (the tint lands on mid, rim and deep the way the
    /// renderer applies it). Light bodies get a shell between core and mid and an inner mass
    /// between mid and rim, pulled toward deep when the two would read as one tone (lemon, mint,
    /// honey); dark bodies keep the shell dim so white ink still stands out.
    public func material(tint: StateTint = .none) -> Material {
        let t = tint
        let rim = self.rim.mixed(with: t.color, t.opacity).desaturated(t.desaturation)
        let deep = self.deep.mixed(with: t.color, t.opacity * 0.8).desaturated(t.desaturation)
        let mid = self.mid.mixed(with: t.color, t.opacity * 0.6).desaturated(t.desaturation)
        let core = self.core.desaturated(t.desaturation)
        if isDark {
            let shell = core.mixed(with: mid, 0.25)
            let inner = mid.mixed(with: rim, 0.60)
            return Material(shell: shell, inner: inner, window: core.opacity(0.35),
                            inkLine: ink.mixed(with: mid, 0.35).opacity(0.9),
                            rimLight: core.mixed(with: .white, 0.3).opacity(0.30),
                            glow: shell.mixed(with: mid, 0.5).opacity(0.18), highlight: highlight)
        }
        let shell = core.mixed(with: mid, 0.40).desaturated(0.10)
        var inner = mid.mixed(with: rim, 0.55).desaturated(0.15)
        // Pale saturated hues (lemon, mint, a custom yellow) have no dark tone in their own
        // ramp: pull the inner mass toward deep and down in lightness until the two layers read.
        var steps = 0
        while shell.luminance - inner.luminance < 0.20, steps < 8 {
            inner = inner.mixed(with: deep, 0.35).lightened(0.94)
            steps += 1
        }
        return Material(shell: shell, inner: inner, window: shell.mixed(with: core, 0.5).opacity(0.55),
                        inkLine: ink.mixed(with: deep, 0.70).desaturated(0.30),
                        rimLight: shell.mixed(with: .white, 0.5).opacity(0.35),
                        glow: shell.mixed(with: mid, 0.5).opacity(0.18), highlight: highlight)
    }

    /// Heart eyes and hearts: the blush pushed toward a saturated rose.
    public var heart: RGBA { blush.mixed(with: RGBA(hex: 0xFF4F7D), 0.55) }
    /// Stars: the accent pushed toward gold.
    public var star: RGBA { accent.mixed(with: RGBA(hex: 0xFFC83D), 0.5) }
    /// True when the body is dark enough that ink must be light.
    /// A dark-bodied slime (obsidian and custom picks below a third of full luminance) wears light ink.
    public var isDark: Bool { Self.isDarkBody(mid) }

    static func isDarkBody(_ mid: RGBA) -> Bool { mid.luminance < 0.33 }

    // MARK: Presets

    /// The anime's sky-blue jelly: a pale periwinkle shell over a deeper blue core, navy ink.
    public static let rimuru = SlimeTheme(
        name: "rimuru",
        core: RGBA(hex: 0xE6F5FF), mid: RGBA(hex: 0x9FD0F4), rim: RGBA(hex: 0x6AA6E2), deep: RGBA(hex: 0x3F77BC),
        blush: RGBA(hex: 0xF2A2C4), ink: RGBA(hex: 0x2B4C78))

    public static let sakura = SlimeTheme(
        name: "sakura",
        core: RGBA(hex: 0xFFF0F6), mid: RGBA(hex: 0xFFB7D5), rim: RGBA(hex: 0xF27BA8), deep: RGBA(hex: 0xD4507F),
        blush: RGBA(hex: 0xFF6F91), ink: RGBA(hex: 0x4A2538), accent: RGBA(hex: 0xFFD36B))

    public static let ruby = SlimeTheme(
        name: "ruby",
        core: RGBA(hex: 0xFFE3E3), mid: RGBA(hex: 0xFF8A8A), rim: RGBA(hex: 0xE04848), deep: RGBA(hex: 0xB32C2C),
        blush: RGBA(hex: 0xFFB3C6), ink: RGBA(hex: 0x3D1414), accent: RGBA(hex: 0xFFD36B))

    public static let sapphire = SlimeTheme(
        name: "sapphire",
        core: RGBA(hex: 0xD8E4FF), mid: RGBA(hex: 0x6E8FE8), rim: RGBA(hex: 0x3A58C2), deep: RGBA(hex: 0x243B94),
        blush: RGBA(hex: 0xFFA3BE), ink: RGBA(hex: 0x141C3D))

    public static let lilac = SlimeTheme(
        name: "lilac",
        core: RGBA(hex: 0xF4ECFF), mid: RGBA(hex: 0xD0B4FF), rim: RGBA(hex: 0x9A6BF0), deep: RGBA(hex: 0x6E44C8),
        blush: RGBA(hex: 0xFFA3D6), ink: RGBA(hex: 0x2E2345))

    public static let mint = SlimeTheme(
        name: "mint",
        core: RGBA(hex: 0xE6FFF6), mid: RGBA(hex: 0x9BEFD0), rim: RGBA(hex: 0x3FC9A0), deep: RGBA(hex: 0x1F9A78),
        blush: RGBA(hex: 0xFFB0C8), ink: RGBA(hex: 0x1E3A33))

    public static let emerald = SlimeTheme(
        name: "emerald",
        core: RGBA(hex: 0xE0FFF0), mid: RGBA(hex: 0x6FE3A8), rim: RGBA(hex: 0x1FB36B), deep: RGBA(hex: 0x127A48),
        blush: RGBA(hex: 0xFFB0C8), ink: RGBA(hex: 0x123A28), accent: RGBA(hex: 0xFFD36B))

    public static let lemon = SlimeTheme(
        name: "lemon",
        core: RGBA(hex: 0xFFFBE0), mid: RGBA(hex: 0xFFE98A), rim: RGBA(hex: 0xF2C84B), deep: RGBA(hex: 0xD6A21E),
        blush: RGBA(hex: 0xFFA3A3), ink: RGBA(hex: 0x4A3A12), accent: RGBA(hex: 0x6DD3FF))

    public static let honey = SlimeTheme(
        name: "honey",
        core: RGBA(hex: 0xFFF3D6), mid: RGBA(hex: 0xFFCC66), rim: RGBA(hex: 0xE89A2A), deep: RGBA(hex: 0xB86E12),
        blush: RGBA(hex: 0xFF9FB0), ink: RGBA(hex: 0x4A2E0C), accent: RGBA(hex: 0xFF7A59))

    public static let peach = SlimeTheme(
        name: "peach",
        core: RGBA(hex: 0xFFF1E6), mid: RGBA(hex: 0xFFC2A1), rim: RGBA(hex: 0xF28B6A), deep: RGBA(hex: 0xD9603F),
        blush: RGBA(hex: 0xFF8FA3), ink: RGBA(hex: 0x4A2A24), accent: RGBA(hex: 0x6DD3FF))

    public static let slate = SlimeTheme(
        name: "slate",
        core: RGBA(hex: 0xF0F2F5), mid: RGBA(hex: 0xB8C0CC), rim: RGBA(hex: 0x7B8794), deep: RGBA(hex: 0x525C68),
        blush: RGBA(hex: 0xFFA3BE), ink: RGBA(hex: 0x262B33))

    public static let obsidian = SlimeTheme(
        name: "obsidian",
        core: RGBA(hex: 0x5A5F6E), mid: RGBA(hex: 0x2E3240), rim: RGBA(hex: 0x1A1C25), deep: RGBA(hex: 0x0C0D12),
        blush: RGBA(hex: 0xFF6F91), ink: RGBA(hex: 0xF2F4F8), accent: RGBA(hex: 0xFF5A5F))

    public static let all: [SlimeTheme] = [.rimuru, .sakura, .ruby, .sapphire, .lilac, .mint, .emerald, .lemon, .honey, .peach, .slate, .obsidian]

    public static var names: [String] { all.map(\.name) }

    public static func named(_ name: String) -> SlimeTheme {
        all.first { $0.name == name } ?? .rimuru
    }

    /// A whole palette from one colour: `hue` 0…360, `saturation` and `lightness` 0…1 describe the
    /// mid tone; the other tones are derived so any pick reads as the same glossy jelly. Dark bodies
    /// get light ink; blush shifts away from the body hue when the body is already pink.
    public static func derived(hue: Double, saturation: Double, lightness: Double, name: String = "custom") -> SlimeTheme {
        let h = ((hue.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360)
        let s = clamp(saturation, 0, 1)
        let l = clamp(lightness, 0.08, 0.92)
        let mid = RGBA(hue: h, saturation: s, lightness: l)
        // Dark is decided on luminance, not lightness: a saturated blue at half lightness is far
        // darker to the eye than a yellow at the same setting, and the face must read on both.
        let dark = isDarkBody(mid)
        // The core is the body mixed toward white: a soft highlight on a light body, a dim sheen
        // on a dark one so white ink still stands out everywhere on the face.
        let core = mid.mixed(with: .white, dark ? 0.22 : 0.5)
        let rim = RGBA(hue: h, saturation: min(1, s * 1.1), lightness: l * 0.72)
        let deep = RGBA(hue: h, saturation: min(1, s * 1.15), lightness: l * 0.52)
        let ink = dark ? RGBA(hue: h, saturation: 0.12, lightness: 0.95) : RGBA(hue: h, saturation: min(0.4, s * 0.5), lightness: 0.10)
        let pinkish = h >= 300 || h <= 20
        let blushHue = pinkish ? (h + 40).truncatingRemainder(dividingBy: 360) : 342.0
        let blush = RGBA(hue: blushHue, saturation: 0.9, lightness: dark ? 0.68 : 0.78)
        let comp = (h + 180).truncatingRemainder(dividingBy: 360)
        let accent = RGBA(hue: comp, saturation: 0.85, lightness: 0.65)
        return SlimeTheme(name: name, core: core, mid: mid, rim: rim, deep: deep, blush: blush, ink: ink, accent: accent, tongue: RGBA(hex: 0xE2607F))
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
