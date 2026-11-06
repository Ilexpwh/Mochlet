import Foundation

/// The species of a slime: its resting silhouette, body features, surface effect and how the jelly
/// feels. Colour is separate (`SlimeTheme`), so any look can wear any palette.
public struct SlimeLook: Sendable, Codable, Equatable, Hashable, Identifiable {
    public enum Silhouette: String, Sendable, Codable, CaseIterable {
        /// The plain Rimuru dome.
        case dome
        /// A narrow peak at the top (ghost, flame).
        case drop
        /// Low and wide (honey, melted).
        case puddle
        /// Wider with two ear bumps of body material (cat, fox).
        case loaf
        /// Six soft bumps (crystal, spark).
        case spiky
        /// Taller than wide.
        case tall
    }

    public enum Ears: String, Sendable, Codable, CaseIterable { case none, cat, fox, ice }
    public enum Horns: String, Sendable, Codable, CaseIterable { case none, demonPair, oniSingle, unicorn, dragonPair }
    public enum Tail: String, Sendable, Codable, CaseIterable { case none, cat, fox, dragon, fish }
    public enum Wings: String, Sendable, Codable, CaseIterable { case none, bat, dragon, fairy }
    public enum Surface: String, Sendable, Codable, CaseIterable { case plain, fire, electric, crystal, ghost, honey, galaxy, bubble }
    /// How the jelly moves: parameter deltas on the soft body.
    public enum Feel: String, Sendable, Codable, CaseIterable { case jelly, firm, runny, airy, bouncy }

    public var name: String
    public var silhouette: Silhouette
    public var ears: Ears
    public var horns: Horns
    public var tail: Tail
    public var wings: Wings
    public var antenna: Bool
    public var surface: Surface
    public var feel: Feel
    /// 0 = opaque jelly, up to ≈0.4 for a ghost.
    public var transparency: Double

    public var id: String { name }

    public init(name: String, silhouette: Silhouette = .dome, ears: Ears = .none, horns: Horns = .none, tail: Tail = .none,
                wings: Wings = .none, antenna: Bool = false, surface: Surface = .plain, feel: Feel = .jelly, transparency: Double = 0) {
        self.name = name
        self.silhouette = silhouette
        self.ears = ears
        self.horns = horns
        self.tail = tail
        self.wings = wings
        self.antenna = antenna
        self.surface = surface
        self.feel = feel
        self.transparency = transparency
    }

    enum CodingKeys: String, CodingKey { case name, silhouette, ears, horns, tail, wings, antenna, surface, feel, transparency }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "custom"
        silhouette = try c.decodeIfPresent(Silhouette.self, forKey: .silhouette) ?? .dome
        ears = try c.decodeIfPresent(Ears.self, forKey: .ears) ?? .none
        horns = try c.decodeIfPresent(Horns.self, forKey: .horns) ?? .none
        tail = try c.decodeIfPresent(Tail.self, forKey: .tail) ?? .none
        wings = try c.decodeIfPresent(Wings.self, forKey: .wings) ?? .none
        antenna = try c.decodeIfPresent(Bool.self, forKey: .antenna) ?? false
        surface = try c.decodeIfPresent(Surface.self, forKey: .surface) ?? .plain
        feel = try c.decodeIfPresent(Feel.self, forKey: .feel) ?? .jelly
        transparency = try c.decodeIfPresent(Double.self, forKey: .transparency) ?? 0
    }

    /// True when nothing but the plain dome is drawn.
    public var isPlain: Bool {
        silhouette == .dome && ears == .none && horns == .none && tail == .none && wings == .none && !antenna && surface == .plain
    }

    /// The same look as a mini slime: ears and horns stay, wings and tails do not fit the row.
    public var mini: SlimeLook {
        var m = self
        m.tail = .none
        m.wings = .none
        return m
    }

    // MARK: Presets

    public static let rimuru = SlimeLook(name: "rimuru")
    public static let tempest = SlimeLook(name: "tempest", horns: .dragonPair, tail: .dragon, wings: .dragon, feel: .bouncy)
    public static let demonLord = SlimeLook(name: "demonLord", horns: .demonPair, feel: .firm)
    public static let oni = SlimeLook(name: "oni", horns: .oniSingle)
    public static let cat = SlimeLook(name: "cat", silhouette: .loaf, ears: .cat, tail: .cat)
    public static let fox = SlimeLook(name: "fox", silhouette: .loaf, ears: .fox, tail: .fox)
    public static let unicorn = SlimeLook(name: "unicorn", silhouette: .loaf, ears: .cat, horns: .unicorn, tail: .fox)
    public static let bat = SlimeLook(name: "bat", wings: .bat, feel: .airy)
    public static let fairy = SlimeLook(name: "fairy", wings: .fairy, antenna: true, feel: .airy)
    public static let flame = SlimeLook(name: "flame", silhouette: .drop, surface: .fire, feel: .bouncy)
    public static let crystal = SlimeLook(name: "crystal", silhouette: .spiky, ears: .ice, surface: .crystal, feel: .firm)
    public static let ghost = SlimeLook(name: "ghost", silhouette: .drop, surface: .ghost, feel: .airy, transparency: 0.35)
    public static let honey = SlimeLook(name: "honey", silhouette: .puddle, surface: .honey, feel: .runny)
    public static let spark = SlimeLook(name: "spark", silhouette: .spiky, antenna: true, surface: .electric, feel: .bouncy)
    public static let galaxy = SlimeLook(name: "galaxy", silhouette: .tall, surface: .galaxy, feel: .airy)

    public static let all: [SlimeLook] = [.rimuru, .tempest, .demonLord, .oni, .cat, .fox, .unicorn, .bat, .fairy, .flame, .crystal, .ghost, .honey, .spark, .galaxy]

    public static var names: [String] { all.map(\.name) }

    public static func named(_ name: String) -> SlimeLook {
        all.first { $0.name == name } ?? .rimuru
    }

    /// The preset this look equals (ignoring its name), if any.
    public var presetName: String? {
        var me = self
        for p in Self.all {
            me.name = p.name
            if me == p { return p.name }
        }
        return nil
    }

    /// Human-readable label for a preset name.
    public static func label(_ name: String) -> String {
        switch name {
        case "rimuru": return "Rimuru"
        case "tempest": return "Tempest"
        case "demonLord": return "Demon Lord"
        case "oni": return "Oni"
        case "cat": return "Cat"
        case "fox": return "Fox"
        case "unicorn": return "Unicorn"
        case "bat": return "Bat"
        case "fairy": return "Fairy"
        case "flame": return "Flame"
        case "crystal": return "Crystal"
        case "ghost": return "Ghost"
        case "honey": return "Honey"
        case "spark": return "Spark"
        case "galaxy": return "Galaxy"
        default: return name.prefix(1).uppercased() + name.dropFirst()
        }
    }
}
