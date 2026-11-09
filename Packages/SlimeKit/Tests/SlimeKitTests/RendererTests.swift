import Testing
import CoreGraphics
import SlimeKit
@testable import SlimeKitUI

/// The CoreGraphics renderer draws every palette, look and detail level without crashing and
/// actually puts paint on the canvas.
@Suite struct RendererTests {
    static func canvas(_ w: Int, _ h: Int) -> CGContext {
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        return CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)!
    }

    static func paintedPixels(_ cg: CGContext) -> Int {
        guard let data = cg.data else { return 0 }
        let n = cg.bytesPerRow * cg.height
        let bytes = data.bindMemory(to: UInt8.self, capacity: n)
        var count = 0
        var i = 3
        while i < n { if bytes[i] > 0 { count += 1 }; i += 4 }
        return count
    }

    @MainActor @Test func everyPaletteAndLookDraws() {
        for look in SlimeLook.all {
            let engine = SlimeEngine(profile: .main, seed: 5)
            engine.appearance = SlimeAppearance(look: look, dressForOccasion: false)
            engine.simulate(1.2)
            let frame = engine.frame()
            for palette in SlimeTheme.all {
                let appearance = SlimeAppearance(look: look, palette: palette, dressForOccasion: false)
                for r in [56.0, 22.0, 15.0] as [CGFloat] {
                    let cg = Self.canvas(Int(r * 5), Int(r * 3.4))
                    SlimeCGRenderer.draw(frame, appearance: appearance, in: cg, origin: CGPoint(x: r * 2.5, y: r * 3.1), radius: r)
                    let painted = Self.paintedPixels(cg)
                    #expect(painted > Int(r * r * 2), "\(look.name) \(palette.name) R \(Int(r)) painted \(painted) px")
                }
            }
        }
    }

    @MainActor @Test func tintsEmotesAndFloorShadowsDraw() {
        let engine = SlimeEngine(profile: .main, seed: 9)
        engine.simulate(1)
        engine.agent(.error)
        engine.simulate(0.4)
        let frame = engine.frame()
        for shadow in [SlimeCGRenderer.FloorShadow.none, .glow, .dark] {
            let cg = Self.canvas(300, 200)
            SlimeCGRenderer.draw(frame, appearance: .rimuru, in: cg, origin: CGPoint(x: 150, y: 180), radius: 56, floorShadow: shadow)
            #expect(Self.paintedPixels(cg) > 5000)
        }
        // The grown glyph and arms share the material.
        let busy = SlimeEngine(profile: .main, seed: 9)
        busy.simulate(0.5)
        busy.startQuestion()
        busy.simulate(0.6)
        let cg = Self.canvas(300, 240)
        SlimeCGRenderer.draw(busy.frame(), appearance: .rimuru, in: cg, origin: CGPoint(x: 150, y: 220), radius: 56)
        #expect(Self.paintedPixels(cg) > 5000)
    }
}
