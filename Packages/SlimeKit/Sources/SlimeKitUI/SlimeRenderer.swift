import SwiftUI
import SlimeKit

/// SwiftUI entry point: draws one slime into a GraphicsContext by handing its CGContext to
/// `SlimeCGRenderer`, so the Canvas (filmstrips, Emote Lab) and the AppKit layer view render
/// pixel-identical slimes from one code path.
public struct SlimeRenderer {
    public let frame: SlimeFrame
    public let appearance: SlimeAppearance
    public let origin: CGPoint
    public let R: CGFloat

    public init(frame: SlimeFrame, appearance: SlimeAppearance, origin: CGPoint, radius: CGFloat) {
        self.frame = frame
        self.appearance = appearance
        self.origin = origin
        self.R = radius
    }

    public init(frame: SlimeFrame, theme: SlimeTheme, origin: CGPoint, radius: CGFloat) {
        self.init(frame: frame, appearance: SlimeAppearance(palette: theme), origin: origin, radius: radius)
    }

    public static func draw(_ frame: SlimeFrame, appearance: SlimeAppearance, in ctx: inout GraphicsContext, origin: CGPoint, radius: CGFloat) {
        SlimeRenderer(frame: frame, appearance: appearance, origin: origin, radius: radius).draw(in: &ctx)
    }

    public static func draw(_ frame: SlimeFrame, theme: SlimeTheme, in ctx: inout GraphicsContext, origin: CGPoint, radius: CGFloat) {
        SlimeRenderer(frame: frame, theme: theme, origin: origin, radius: radius).draw(in: &ctx)
    }

    public func draw(in context: inout GraphicsContext) {
        context.withCGContext { cg in
            SlimeCGRenderer.draw(frame, appearance: appearance, in: cg, origin: origin, radius: R)
        }
    }
}
