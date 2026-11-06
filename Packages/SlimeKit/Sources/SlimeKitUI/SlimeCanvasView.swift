import SwiftUI
import simd
import SlimeKit

/// Live view of one engine: TimelineView → Canvas → engine.advance → SlimeRenderer.
/// The redraw rate follows the engine's activity (30 Hz quiet, 60 Hz lively, display rate in motion).
public struct SlimeCanvasView: View {
    public let engine: SlimeEngine
    public var radius: CGFloat
    public var paused: Bool
    /// Pixel position of the contact point for a given canvas size.
    public var origin: @MainActor (CGSize) -> CGPoint
    /// Pointer in canvas coordinates, nil when away.
    public var pointer: @MainActor () -> CGPoint?

    @State private var interval: TimeInterval? = 1.0 / 30.0

    public init(engine: SlimeEngine, radius: CGFloat, paused: Bool = false,
                origin: @escaping @MainActor (CGSize) -> CGPoint,
                pointer: @escaping @MainActor () -> CGPoint? = { nil }) {
        self.engine = engine
        self.radius = radius
        self.paused = paused
        self.origin = origin
        self.pointer = pointer
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: interval, paused: paused)) { timeline in
            let date = timeline.date
            Canvas(rendersAsynchronously: false) { ctx, size in
                let o = origin(size)
                engine.detail = DetailLevel(pixelsPerUnit: Double(radius))
                if let p = pointer() {
                    engine.pointer(SIMD2(Double((p.x - o.x) / radius), Double((p.y - o.y) / radius)))
                } else {
                    engine.pointer(nil)
                }
                engine.advance(to: date.timeIntervalSinceReferenceDate)
                let frame = engine.frame()
                SlimeRenderer.draw(frame, appearance: engine.appearance, in: &ctx, origin: o, radius: radius)
                let desired = engine.frameInterval
                if desired != interval {
                    Task { @MainActor in interval = desired }
                }
            }
        }
        .onChange(of: paused) { _, isPaused in
            if !isPaused { engine.resume() }
        }
    }
}

/// Static drawing of one frame (filmstrips, previews, the app icon).
public struct SlimeFrameView: View {
    public var frame: SlimeFrame
    public var appearance: SlimeAppearance
    public var radius: CGFloat
    public var size: CGSize
    public var origin: CGPoint
    public var background: Color

    public init(frame: SlimeFrame, appearance: SlimeAppearance, radius: CGFloat, size: CGSize, origin: CGPoint, background: Color = .black) {
        self.frame = frame
        self.appearance = appearance
        self.radius = radius
        self.size = size
        self.origin = origin
        self.background = background
    }

    public init(frame: SlimeFrame, theme: SlimeTheme, radius: CGFloat, size: CGSize, origin: CGPoint, background: Color = .black) {
        self.init(frame: frame, appearance: SlimeAppearance(palette: theme), radius: radius, size: size, origin: origin, background: background)
    }

    public var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, _ in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(background))
            SlimeRenderer.draw(frame, appearance: appearance, in: &ctx, origin: origin, radius: radius)
        }
        .frame(width: size.width, height: size.height)
    }
}
