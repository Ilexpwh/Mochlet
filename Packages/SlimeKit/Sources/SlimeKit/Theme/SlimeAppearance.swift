import Foundation

/// How marks like `?` and `!` are drawn: grown out of the body as slime, or in a speech bubble.
public enum GlyphStyle: String, Sendable, Codable, CaseIterable {
    case grown, bubble
}

/// Everything about how a slime looks, independent of what it is doing: species, colour, clothes
/// and a few drawing preferences. One value drives the main slime, its minis and the ghost.
public struct SlimeAppearance: Sendable, Codable, Equatable, Hashable {
    public var look: SlimeLook
    public var palette: SlimeTheme
    public var outfit: SlimeOutfit
    public var glyphStyle: GlyphStyle
    /// Ink-stroke face (the anime) or round ball eyes.
    public var faceStyle: FaceStyle
    public var armsEnabled: Bool
    /// Minis use the same palette, or a lighter tint of it.
    public var lighterMinis: Bool
    /// Situational pieces (reading glasses while eating, a nightcap asleep) over the chosen outfit.
    public var dressForOccasion: Bool

    public init(look: SlimeLook = .plain, palette: SlimeTheme = .rimuru, outfit: SlimeOutfit = SlimeOutfit(),
                glyphStyle: GlyphStyle = .grown, faceStyle: FaceStyle = .anime, armsEnabled: Bool = true, lighterMinis: Bool = false,
                dressForOccasion: Bool = true) {
        self.look = look
        self.palette = palette
        self.outfit = outfit
        self.glyphStyle = glyphStyle
        self.faceStyle = faceStyle
        self.armsEnabled = armsEnabled
        self.lighterMinis = lighterMinis
        self.dressForOccasion = dressForOccasion
    }

    enum CodingKeys: String, CodingKey { case look, palette, outfit, glyphStyle, faceStyle, armsEnabled, lighterMinis, dressForOccasion }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        look = try c.decodeIfPresent(SlimeLook.self, forKey: .look) ?? .rimuru
        palette = try c.decodeIfPresent(SlimeTheme.self, forKey: .palette) ?? .rimuru
        outfit = try c.decodeIfPresent(SlimeOutfit.self, forKey: .outfit) ?? SlimeOutfit()
        glyphStyle = try c.decodeIfPresent(GlyphStyle.self, forKey: .glyphStyle) ?? .grown
        faceStyle = try c.decodeIfPresent(FaceStyle.self, forKey: .faceStyle) ?? .anime
        armsEnabled = try c.decodeIfPresent(Bool.self, forKey: .armsEnabled) ?? true
        lighterMinis = try c.decodeIfPresent(Bool.self, forKey: .lighterMinis) ?? false
        dressForOccasion = try c.decodeIfPresent(Bool.self, forKey: .dressForOccasion) ?? true
    }

    /// The plain dome in the Rimuru palette: the engine default (the app's "rimuru" look adds the tip).
    public static let rimuru = SlimeAppearance()

    /// The appearance of a mini split from this slime: same species without wings or tail, no
    /// clothes, optionally a lighter palette.
    public var forMini: SlimeAppearance {
        var a = self
        a.look = look.mini
        a.outfit = SlimeOutfit()
        if lighterMinis {
            a.palette.mid = palette.mid.mixed(with: palette.core, 0.35)
            a.palette.rim = palette.rim.mixed(with: palette.mid, 0.35)
            a.palette.deep = palette.deep.mixed(with: palette.rim, 0.35)
        }
        return a
    }

    /// The drag-out ghost: the same slime without clothes.
    public var forGhost: SlimeAppearance {
        var a = self
        a.outfit = SlimeOutfit()
        return a
    }
}
