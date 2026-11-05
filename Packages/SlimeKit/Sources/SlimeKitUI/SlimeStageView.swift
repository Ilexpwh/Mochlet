import SwiftUI
import simd
import SlimeKit

/// Live view of a whole stage (main, minis, droplets, ghost). One Canvas, one TimelineView;
/// cues drained each frame go to `sink`.
public struct SlimeStageView: View {
    public let stage: SlimeStage
    public var radius: CGFloat
    public var paused: Bool
    public var sink: SoundSink?
    public var probe: PerfProbe?
    /// Set false on secondary views of the same stage so they do not overwrite the pointer.
    public var updatesPointer = true
    /// Pixel position of the main contact point for a given canvas size.
    public var origin: @MainActor (CGSize) -> CGPoint
    /// Pointer in canvas coordinates, nil when away.
    public var pointer: @MainActor () -> CGPoint?

    @State private var interval: TimeInterval? = 1.0 / 30.0

    public init(stage: SlimeStage, radius: CGFloat, paused: Bool = false, sink: SoundSink? = nil, probe: PerfProbe? = nil,
                updatesPointer: Bool = true,
                origin: @escaping @MainActor (CGSize) -> CGPoint,
                pointer: @escaping @MainActor () -> CGPoint? = { nil }) {
        self.stage = stage
        self.radius = radius
        self.paused = paused
        self.sink = sink
        self.probe = probe
        self.updatesPointer = updatesPointer
        self.origin = origin
        self.pointer = pointer
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: interval, paused: paused)) { timeline in
            let date = timeline.date
            Canvas(rendersAsynchronously: false) { ctx, size in
                probe?.begin()
                let o = origin(size)
                if updatesPointer {
                    if let p = pointer() {
                        stage.pointer(SIMD2(Double((p.x - o.x) / radius), Double((p.y - o.y) / radius)))
                    } else {
                        stage.pointer(nil)
                    }
                }
                stage.advance(to: date.timeIntervalSinceReferenceDate)
                Self.draw(stage.frames(), theme: stage.theme, in: &ctx, origin: o, radius: radius)
                if let sink { sink.play(stage.drainCues()) } else { _ = stage.drainCues() }
                let desired = stage.frameInterval
                if desired != interval {
                    Task { @MainActor in interval = desired }
                }
                probe?.end()
            }
        }
        .onChange(of: paused) { _, isPaused in
            if !isPaused { stage.resume() }
        }
    }

    /// Draws placed slimes: main first, then minis, then the ghost.
    public static func draw(_ placed: [PlacedSlime], theme: SlimeTheme, in ctx: inout GraphicsContext, origin: CGPoint, radius: CGFloat) {
        for p in placed {
            let o = CGPoint(x: origin.x + CGFloat(p.offset.x) * radius, y: origin.y + CGFloat(p.offset.y) * radius)
            SlimeRenderer.draw(p.frame, theme: theme, in: &ctx, origin: o, radius: radius * CGFloat(p.scale))
        }
    }
}
