import SwiftUI
import SlimeKit

/// One sheet of every look preset in a few palettes and at the three pixel sizes the app uses,
/// for image review (`slimekit-tools render-catalog`).
public enum Catalog {
    @MainActor
    public static func render(palettes: [SlimeTheme] = [.rimuru, .ruby, .obsidian], looks: [SlimeLook] = SlimeLook.all,
                              radius: CGFloat = 56, columns: Int? = nil) throws -> CGImage {
        var images: [CGImage] = []
        var labels: [String] = []
        let sizes: [CGFloat] = [radius, 22, 15]
        for look in looks {
            for palette in palettes {
                images.append(try cell(look: look, palette: palette, radius: radius, cellRadius: radius))
                labels.append("\(look.name) · \(palette.name)")
            }
            for r in sizes.dropFirst() {
                images.append(try cell(look: look, palette: palettes[0], radius: r, cellRadius: radius))
                labels.append("\(look.name) · R \(Int(r))")
            }
        }
        let cols = columns ?? (palettes.count + sizes.count - 1)
        guard let sheet = Filmstrip.contactSheet(images, labels: labels, columns: cols) else {
            throw NSError(domain: "SlimeKitUI.Catalog", code: 1, userInfo: [NSLocalizedDescriptionKey: "contact sheet failed"])
        }
        return sheet
    }

    /// One settled slime drawn at `radius` px/R inside a cell sized for `cellRadius`.
    @MainActor
    static func cell(look: SlimeLook, palette: SlimeTheme, radius: CGFloat, cellRadius: CGFloat) throws -> CGImage {
        guard let cg = render(look: look, palette: palette, radius: radius, cellRadius: cellRadius, scale: 1, background: .black) else {
            throw NSError(domain: "SlimeKitUI.Catalog", code: 2, userInfo: [NSLocalizedDescriptionKey: "render failed for \(look.name)"])
        }
        return cg
    }

    /// A transparent thumbnail of one look for pickers (settings, menus); `scale` is the backing
    /// scale, so the image is `4.2·radius × 3.1·radius` points.
    @MainActor
    public static func thumbnail(look: SlimeLook, palette: SlimeTheme, radius: CGFloat = 16, scale: CGFloat = 2) -> CGImage? {
        render(look: look, palette: palette, radius: radius, cellRadius: radius, scale: scale, background: .clear)
    }

    @MainActor
    static func render(look: SlimeLook, palette: SlimeTheme, radius: CGFloat, cellRadius: CGFloat, scale: CGFloat, background: Color) -> CGImage? {
        let engine = SlimeEngine(profile: .main, seed: 3)
        engine.appearance = SlimeAppearance(look: look, palette: palette)
        engine.detail = DetailLevel(pixelsPerUnit: Double(radius * scale))
        engine.simulate(1.4)
        let size = CGSize(width: cellRadius * 4.2, height: cellRadius * 3.1)
        let origin = CGPoint(x: size.width * 0.5, y: size.height - radius * 0.3)
        let view = SlimeFrameView(frame: engine.frame(), appearance: engine.appearance, radius: radius, size: size, origin: origin, background: background)
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        renderer.isOpaque = background != .clear
        renderer.proposedSize = ProposedViewSize(size)
        return renderer.cgImage
    }
}
