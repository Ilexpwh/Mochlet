import Testing
import Foundation
@testable import SlimeKit

@Suite struct ThemeTests {
    @Test func presetsAreNamedAndDistinct() {
        #expect(SlimeTheme.names == SlimeTheme.all.map(\.name))
        #expect(Set(SlimeTheme.names).count == SlimeTheme.all.count)
        #expect(SlimeTheme.named("nope") == .rimuru)
        #expect(SlimeTheme.named("obsidian").isDark)
        #expect(!SlimeTheme.named("lemon").isDark)
    }

    /// Ink must read on the body for every preset and every custom pick.
    @Test func inkContrastsWithTheBody() {
        func check(_ t: SlimeTheme) {
            let d = abs(t.ink.luminance - t.core.luminance)
            #expect(d >= 0.40, "\(t.name) ink/core contrast \(d)")
            let dm = abs(t.ink.luminance - t.mid.luminance)
            #expect(dm >= 0.18, "\(t.name) ink/mid contrast \(dm)")
            #expect(t.rim.luminance < t.core.luminance, "\(t.name) rim darker than core")
            #expect(t.deep.luminance <= t.rim.luminance + 1e-9, "\(t.name) deep darker than rim")
        }
        for t in SlimeTheme.all { check(t) }
        for hue in stride(from: 0.0, to: 360, by: 15) {
            for light in [0.1, 0.18, 0.3, 0.35, 0.5, 0.65, 0.8, 0.9] {
                for sat in [0.0, 0.2, 0.6, 1.0] {
                    check(SlimeTheme.derived(hue: hue, saturation: sat, lightness: light))
                }
            }
        }
    }

    /// The two layers of the material must read as two tones, and the ink on the shell, for
    /// every preset, every custom pick and under the state tints.
    @Test func materialContrast() {
        func check(_ t: SlimeTheme, tint: StateTint = .none, label: String) {
            let m = t.material(tint: tint)
            if t.isDark {
                #expect(m.inner.luminance < m.shell.luminance - 0.03, "\(label) inner darker than shell")
            } else {
                let d = m.shell.luminance - m.inner.luminance
                #expect(d >= 0.15, "\(label) shell/inner contrast \(d)")
            }
            let ink = abs(m.inkLine.luminance - m.shell.luminance)
            #expect(ink >= 0.30, "\(label) ink/shell contrast \(ink)")
            #expect(m.window.a > 0 && m.rimLight.a > 0 && m.glow.a > 0 && m.inkLine.a >= 0.85)
        }
        for t in SlimeTheme.all {
            check(t, label: t.name)
            for tint in [StateTint.error, .thinking, .waiting, .sleeping, .dizzy] { check(t, tint: tint, label: "\(t.name) tinted") }
        }
        for hue in stride(from: 0.0, to: 360, by: 30) {
            for light in [0.15, 0.3, 0.5, 0.7, 0.85] {
                for sat in [0.0, 0.3, 1.0] {
                    check(SlimeTheme.derived(hue: hue, saturation: sat, lightness: light), label: "h\(hue) s\(sat) l\(light)")
                }
            }
        }
        let r = SlimeTheme.rimuru.material()
        #expect(r.shell.luminance > 0.8 && r.inner.luminance < 0.75, "rimuru reads pale shell over a blue core")
    }

    @Test func derivedPaletteFollowsThePick() {
        let t = SlimeTheme.derived(hue: 200, saturation: 0.9, lightness: 0.6)
        let h = t.mid.hsl
        #expect(abs(h.hue - 200) < 1.5)
        #expect(abs(h.saturation - 0.9) < 0.02)
        #expect(abs(h.lightness - 0.6) < 0.02)
        // Blush moves away from a pink body.
        let pink = SlimeTheme.derived(hue: 340, saturation: 0.8, lightness: 0.7)
        #expect(abs(pink.blush.hsl.hue - 20) < 2)
        let blue = SlimeTheme.derived(hue: 200, saturation: 0.8, lightness: 0.7)
        #expect(abs(blue.blush.hsl.hue - 342) < 2)
        // Dark bodies get light ink.
        #expect(SlimeTheme.derived(hue: 270, saturation: 0.5, lightness: 0.2).ink.luminance > 0.8)
    }

    @Test func hslRoundTrips() {
        for (r, g, b) in [(0.5, 0.2, 0.9), (0.1, 0.8, 0.3), (0.9, 0.9, 0.1), (0.3, 0.3, 0.3)] {
            let c = RGBA(r: r, g: g, b: b)
            let h = c.hsl
            let back = RGBA(hue: h.hue, saturation: h.saturation, lightness: h.lightness)
            #expect(abs(back.r - r) < 1e-6 && abs(back.g - g) < 1e-6 && abs(back.b - b) < 1e-6)
        }
        #expect(RGBA(hex: 0x7FD4FF).hex == 0x7FD4FF)
    }

    @Test func appearanceRoundTripsAndToleratesOldJSON() throws {
        var a = SlimeAppearance(look: .cat, palette: .derived(hue: 120, saturation: 0.7, lightness: 0.55), outfit: SlimeOutfit.set(named: "king")!, glyphStyle: .bubble, armsEnabled: false, lighterMinis: true)
        a.look.name = "mine"
        let data = try JSONEncoder().encode(a)
        let back = try JSONDecoder().decode(SlimeAppearance.self, from: data)
        #expect(back == a)
        // Missing keys fall back to the defaults (older settings files).
        let partial = try JSONDecoder().decode(SlimeAppearance.self, from: Data(#"{"palette":{"name":"x","core":{"r":1,"g":1,"b":1,"a":1},"mid":{"r":0.5,"g":0.5,"b":0.5,"a":1},"rim":{"r":0.3,"g":0.3,"b":0.3,"a":1},"deep":{"r":0.2,"g":0.2,"b":0.2,"a":1},"blush":{"r":1,"g":0.6,"b":0.7,"a":1},"ink":{"r":0,"g":0,"b":0,"a":1}}}"#.utf8))
        #expect(partial.look == .rimuru)
        #expect(partial.outfit.isEmpty)
        #expect(partial.palette.accent == RGBA(hex: 0xFFC14D))
        #expect(partial.glyphStyle == .grown)
    }

    @Test func looksAndOutfits() {
        #expect(SlimeLook.names == SlimeLook.all.map(\.name))
        #expect(Set(SlimeLook.names).count == SlimeLook.all.count)
        #expect(SlimeLook.plain.isPlain && !SlimeLook.rimuru.isPlain && SlimeLook.rimuru.tip)
        #expect(!SlimeLook.cat.isPlain)
        #expect(SlimeLook.tempest.mini.wings == .none && SlimeLook.tempest.mini.horns == .dragonPair)
        var custom = SlimeLook.fox
        custom.name = "something"
        #expect(custom.presetName == "fox")
        custom.antenna = true
        #expect(custom.presetName == nil)
        #expect(SlimeOutfit.set(named: "king")?.setName == "king")
        let dressed = SlimeOutfit.set(named: "summer")!.overlaid(with: SlimeOutfit(eyewear: .roundGlasses))
        #expect(dressed.headwear == .strawHat && dressed.eyewear == .roundGlasses)
        let mini = SlimeAppearance(look: .tempest, outfit: SlimeOutfit.set(named: "king")!, lighterMinis: true).forMini
        #expect(mini.outfit.isEmpty && mini.look.tail == .none)
        #expect(mini.palette.mid.luminance > SlimeTheme.rimuru.mid.luminance)
    }
}
