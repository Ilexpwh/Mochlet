import Foundation
import SlimeKit

/// Everything the user chose about the slime's look, stored as one JSON blob under the `character`
/// default. Resolves to the `SlimeAppearance` the stage draws. Fields missing from an older blob
/// keep their defaults, so adding one never resets the character.
struct CharacterConfig: Codable, Equatable, Sendable {
    /// A `SlimeTheme` preset name, or "custom" for the hue/saturation/lightness pick below.
    var paletteName = "rimuru"
    var hue = 200.0
    var saturation = 1.0
    var lightness = 0.75
    /// A `SlimeLook` preset name, or "custom" for `look`.
    var lookName = "rimuru"
    var look = SlimeLook.rimuru
    var outfit = SlimeOutfit()
    /// Situational props (reading glasses while chewing, a phone on a call) over the chosen outfit.
    var dressForOccasion = true
    /// Sound pack name ("puni" or "classic") and the tiny voice squeaks in it.
    var soundPack = "puni"
    var voiceSqueaks = true
    var glyphStyle = GlyphStyle.grown
    /// Ink-stroke face (the anime) or round ball eyes.
    var faceStyle = FaceStyle.anime
    var armsEnabled = true
    var lighterMinis = false

    init() {}

    enum CodingKeys: String, CodingKey {
        case paletteName, hue, saturation, lightness, lookName, look, outfit, dressForOccasion, soundPack, voiceSqueaks, glyphStyle, faceStyle, armsEnabled, lighterMinis
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        paletteName = try c.decodeIfPresent(String.self, forKey: .paletteName) ?? "rimuru"
        hue = try c.decodeIfPresent(Double.self, forKey: .hue) ?? 200
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 1
        lightness = try c.decodeIfPresent(Double.self, forKey: .lightness) ?? 0.75
        lookName = try c.decodeIfPresent(String.self, forKey: .lookName) ?? "rimuru"
        look = try c.decodeIfPresent(SlimeLook.self, forKey: .look) ?? .rimuru
        outfit = try c.decodeIfPresent(SlimeOutfit.self, forKey: .outfit) ?? SlimeOutfit()
        dressForOccasion = try c.decodeIfPresent(Bool.self, forKey: .dressForOccasion) ?? true
        soundPack = try c.decodeIfPresent(String.self, forKey: .soundPack) ?? "puni"
        voiceSqueaks = try c.decodeIfPresent(Bool.self, forKey: .voiceSqueaks) ?? true
        glyphStyle = try c.decodeIfPresent(GlyphStyle.self, forKey: .glyphStyle) ?? .grown
        faceStyle = try c.decodeIfPresent(FaceStyle.self, forKey: .faceStyle) ?? .anime
        armsEnabled = try c.decodeIfPresent(Bool.self, forKey: .armsEnabled) ?? true
        lighterMinis = try c.decodeIfPresent(Bool.self, forKey: .lighterMinis) ?? false
    }

    // MARK: Resolution

    var palette: SlimeTheme {
        paletteName == "custom" ? SlimeTheme.derived(hue: hue, saturation: saturation, lightness: lightness) : SlimeTheme.named(paletteName)
    }

    var resolvedLook: SlimeLook {
        lookName == "custom" ? look : SlimeLook.named(lookName)
    }

    var appearance: SlimeAppearance {
        SlimeAppearance(look: resolvedLook, palette: palette, outfit: outfit, glyphStyle: glyphStyle, faceStyle: faceStyle, armsEnabled: armsEnabled,
                        lighterMinis: lighterMinis, dressForOccasion: dressForOccasion)
    }

    // MARK: Edits

    /// Picks a preset palette and parks the custom sliders on its body colour, so nudging a slider
    /// afterwards starts from the preset instead of jumping.
    mutating func selectPalette(_ name: String) {
        guard SlimeTheme.names.contains(name) else { return }
        paletteName = name
        let h = SlimeTheme.named(name).mid.hsl
        hue = h.hue
        saturation = h.saturation
        lightness = h.lightness
    }

    mutating func setCustom(hue: Double? = nil, saturation: Double? = nil, lightness: Double? = nil) {
        if let hue { self.hue = hue }
        if let saturation { self.saturation = saturation }
        if let lightness { self.lightness = lightness }
        paletteName = "custom"
    }

    mutating func selectLook(_ name: String) {
        guard SlimeLook.names.contains(name) else { return }
        lookName = name
        look = SlimeLook.named(name)
    }
}
