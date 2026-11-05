import AppKit
import QuartzCore
import simd
import SlimeKit

/// AppKit view that draws a stage with CoreGraphics on a display link. It advances the stage
/// every tick but only redraws when the render hash changes, so an idle slime costs a few
/// frames per second instead of thirty; the display link's rate follows `stage.frameInterval`.
@MainActor
public final class SlimeStageLayerView: NSView {
    public let stage: SlimeStage
    public var sink: SoundSink?
    public var probe: PerfProbe?
    /// Pixels per main R unit.
    public var radius: CGFloat
    /// Position of the main contact point for the current view size (y down).
    public var origin: (CGSize) -> CGPoint
    /// Pointer in view coordinates (y down), nil when away.
    public var pointer: () -> CGPoint? = { nil }
    /// Set false on secondary views of the same stage so they do not overwrite the pointer.
    public var updatesPointer = true
    /// Which placed slimes this view draws (the island skips the ghost; a desktop panel draws only the main).
    public var include: (PlacedSlime) -> Bool = { _ in true }
    /// Called first on every tick with the seconds since the previous tick; hosts animate layout here.
    public var onTick: ((SlimeStageLayerView, Double) -> Void)?
    /// Drains cues from the stage; only one view of a stage should own this.
    public var drainsCues = true
    /// Interval between processed ticks while the stage is quiescent. The display link keeps
    /// firing at the panel's rate (60 Hz on non-ProMotion displays whatever range is asked for),
    /// so ticks closer than this are skipped before any work is done. Hosts use ≈1/15 when
    /// nobody is near the slime, 1/30 when the pointer is close and 0 while they animate
    /// layout themselves; tweens and impulses always run at the engine's 60/120 Hz.
    public var idleInterval: Double = 1.0 / 30.0
    /// Sub-pixel motion below this is not redrawn (breathing at R 15 moves points by 0.3 px).
    public var pixelTolerance: Double = 0.5
    public var paused = false {
        didSet {
            guard paused != oldValue else { return }
            link?.isPaused = paused
            if !paused {
                stage.resume()
                lastDrawn = nil
            }
        }
    }

    private var link: CADisplayLink?
    private var lastDrawn: [PlacedSlime]?
    private var lastRadius: CGFloat = 0
    private var lastOrigin: CGPoint = .zero
    private var lastRange: CAFrameRateRange?
    private var lastTick: Double = 0
    private var placed: [PlacedSlime] = []
    public private(set) var redraws = 0
    public private(set) var ticks = 0

    public init(stage: SlimeStage, radius: CGFloat, origin: @escaping (CGSize) -> CGPoint) {
        self.stage = stage
        self.radius = radius
        self.origin = origin
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.isOpaque = false
        layer?.backgroundColor = nil
        // 8-bit backing: AppKit otherwise picks a 16-bit store on wide-gamut displays and every
        // radial gradient rasterises in RGBA64/half-float (3x the idle cost).

    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { false }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { start() } else { stop() }
    }

    private func start() {
        guard link == nil else { return }
        let l = displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        l.isPaused = paused
        link = l
        lastTick = 0
    }

    private func stop() {
        link?.invalidate()
        link = nil
    }

    /// Forces a redraw on the next tick (after a theme or layout change).
    public func invalidate() {
        lastDrawn = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = Date.timeIntervalSinceReferenceDate
        if lastTick != 0 {
            let engine = stage.frameInterval
            let wanted: Double
            switch engine {
            case nil: wanted = 0
            case let i? where i >= 1.0 / 31.0: wanted = max(i, idleInterval)
            case let i?: wanted = i
            }
            // Skip early ticks (half a display frame of slack so 1/30 on a 60 Hz panel is every other tick).
            if wanted > 0, now - lastTick < wanted - 0.009 { return }
        }
        let dt = lastTick == 0 ? 1.0 / 60.0 : min(0.1, now - lastTick)
        lastTick = now
        ticks += 1
        onTick?(self, dt)
        let r = radius
        let o = origin(bounds.size)
        if updatesPointer {
            if let p = pointer() {
                stage.pointer(SIMD2(Double((p.x - o.x) / r), Double((p.y - o.y) / r)))
            } else {
                stage.pointer(nil)
            }
        }
        stage.advance(to: now)
        placed = stage.frames().filter(include)
        let layoutChanged = abs(r - lastRadius) > 0.05 || abs(o.x - lastOrigin.x) > 0.25 || abs(o.y - lastOrigin.y) > 0.25
        if layoutChanged || lastDrawn == nil || PlacedSlime.visuallyDiffer(placed, lastDrawn!, pixelsPerUnit: Double(r), pixelTolerance: pixelTolerance) {
            lastDrawn = placed
            lastRadius = r
            lastOrigin = o
            needsDisplay = true
        }
        if drainsCues {
            if let sink { sink.play(stage.drainCues()) } else { _ = stage.drainCues() }
        }
        let wanted: CAFrameRateRange
        switch stage.frameInterval {
        case nil: wanted = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        case let i? where i <= 1.0 / 59.0: wanted = CAFrameRateRange(minimum: 48, maximum: 60, preferred: 60)
        default:
            let q = Float(max(10, min(30, idleInterval > 0 ? 1 / idleInterval : 30)))
            wanted = CAFrameRateRange(minimum: max(10, q - 5), maximum: q, preferred: q)
        }
        if lastRange != wanted {
            lastRange = wanted
            link.preferredFrameRateRange = wanted
        }
    }

    // The view rasterises into its own 8-bit sRGB bitmap and hands the image to the layer.
    // AppKit's backing store on wide-gamut displays is half-float, which makes every radial
    // gradient three times as expensive, and its display-list replay adds another pass.
    public override var wantsUpdateLayer: Bool { true }

    private var bitmap: CGContext?
    private var bitmapPixels = (w: 0, h: 0)

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    public override func updateLayer() {
        guard let layer else { return }
        let scale = window?.backingScaleFactor ?? 2
        let w = Int((bounds.width * scale).rounded(.up))
        let h = Int((bounds.height * scale).rounded(.up))
        guard w > 0, h > 0 else {
            layer.contents = nil
            return
        }
        if bitmap == nil || bitmapPixels.w != w || bitmapPixels.h != h {
            let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            bitmap = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)
            bitmapPixels = (w, h)
        }
        guard let cg = bitmap else { return }
        probe?.begin()
        redraws += 1
        cg.clear(CGRect(x: 0, y: 0, width: w, height: h))
        cg.saveGState()
        // The renderer works in y-down points (the view is flipped); the bitmap is y-up pixels.
        cg.translateBy(x: 0, y: CGFloat(h))
        cg.scaleBy(x: scale, y: -scale)
        cg.setAllowsAntialiasing(true)
        cg.setShouldAntialias(true)
        Self.draw(placed, theme: stage.theme, in: cg, origin: origin(bounds.size), radius: radius)
        cg.restoreGState()
        layer.contentsScale = scale
        layer.contentsGravity = .resize
        layer.contents = cg.makeImage()
        probe?.end()
    }

    /// Draws placed slimes: main first, then minis, then the ghost.
    public static func draw(_ placed: [PlacedSlime], theme: SlimeTheme, in cg: CGContext, origin: CGPoint, radius: CGFloat) {
        for p in placed {
            let o = CGPoint(x: origin.x + CGFloat(p.offset.x) * radius, y: origin.y + CGFloat(p.offset.y) * radius)
            SlimeCGRenderer.draw(p.frame, theme: theme, in: cg, origin: o, radius: radius * CGFloat(p.scale))
        }
    }
}
