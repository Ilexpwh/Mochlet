import Foundation
import simd

/// What the pointer is over, in stage space.
public enum StageHit: Equatable, Sendable {
    case main
    case mini(String)
    case none
}

/// One drawable slime with its placement relative to the main slime's contact point.
public struct PlacedSlime: Sendable, Equatable {
    /// nil = main, "ghost", or the mini's session id.
    public var id: String?
    public var frame: SlimeFrame
    /// Render scale relative to the main R.
    public var scale: Double
    /// Offset of this slime's contact origin from the main origin, in main R units (y down).
    public var offset: SIMD2<Double>

    public init(id: String?, frame: SlimeFrame, scale: Double, offset: SIMD2<Double>) {
        self.id = id
        self.frame = frame
        self.scale = scale
        self.offset = offset
    }
}

/// A mini slime: one per agent session, pinched off the main slime and merged back when it ends.
@MainActor
public final class MiniSlime: Identifiable {
    public enum Phase: Equatable, Sendable { case pinching, flying, live, merging }

    public let id: String
    public let engine: SlimeEngine
    public internal(set) var slot: Int
    public internal(set) var phase: Phase = .pinching
    public let spawnedAt: Double
    var phaseSince: Double

    init(id: String, engine: SlimeEngine, slot: Int, at time: Double) {
        self.id = id
        self.engine = engine
        self.slot = slot
        self.spawnedAt = time
        self.phaseSince = time
    }

    public var row: Int { slot / SlimeStage.slotsPerRow }
    public var column: Int { slot % SlimeStage.slotsPerRow }
}

/// The whole cast: main slime, one mini per session, split droplets and the drag-out ghost.
/// Choreography (split, pinch-off, merge-back, ghost spring) runs on engine time in 1/240 s steps.
@MainActor
public final class SlimeStage {
    public static let miniScale = 0.45
    public static let slotsPerRow = 4
    /// Mini slot k sits at x = side·(firstSlot + column·slotPitch) in main R units.
    public static let firstSlot = 2.1
    public static let slotPitch = 1.15
    /// Where the pinch-off bulge breaks away (main R units).
    public static let pinchReach = 1.3
    public static let rowLift = 0.8

    public let main: SlimeEngine
    public private(set) var minis: [MiniSlime] = []
    public private(set) var ghost: SlimeEngine?
    /// Which side minis pinch off to (+1 right, -1 left).
    public var side: Double = 1
    /// Minis beyond this count are not drawn (the host shows a badge instead).
    public var maxVisibleMinis = 4
    /// 1 = real time; 0.25 = slow motion (Emote Lab).
    public var timeScale: Double = 1
    public var onEvent: ((SlimeEvent) -> Void)?
    public var onMiniEvent: ((String, SlimeEvent) -> Void)?

    public var theme: SlimeTheme {
        didSet { for e in allEngines { e.theme = theme } }
    }

    public var reduceMotion: Bool {
        didSet { for e in allEngines { e.reduceMotion = reduceMotion } }
    }

    public private(set) var time: Double = 0
    private var rng: SeededRandom
    private var wallTime: Double = 0
    private var scaledWall: Double = 0
    private var primed = false
    private let h = SoftBodyParams.substep
    private var stageCues: [SoundCue] = []
    private var nextSeed: UInt64

    // Split
    private struct SplitRun {
        var startedAt: Double
        var droplets: [Droplet]
        var total: Int
        var merged = 0
    }
    private var split: SplitRun?
    public var isSplitting: Bool { split != nil }
    /// Droplets currently in flight (tests, debug overlays).
    public var droplets: [Droplet] { split?.droplets ?? [] }

    // Pinch-off bulges and merge-back blobs, both drawn through the main slime's metaball layer.
    private struct Absorb {
        var position: SIMD2<Double>
        var velocity: SIMD2<Double>
        var radius: Double
        var startedAt: Double
    }
    private var absorbs: [Absorb] = []

    // Ghost
    private var ghostSpring: Spring2D?
    private var ghostReturning = false
    private var ghostLast: SIMD2<Double> = .zero
    private var ghostVelocity: SIMD2<Double> = .zero
    private var awayAt: Double?
    public var isDraggingOut: Bool { ghost != nil && !ghostReturning }

    public init(seed: UInt64 = 1, theme: SlimeTheme = .rimuru, reduceMotion: Bool = false) {
        main = SlimeEngine(profile: .main, seed: seed)
        self.theme = theme
        self.reduceMotion = reduceMotion
        main.theme = theme
        main.reduceMotion = reduceMotion
        rng = SeededRandom(seed: seed &+ 0x9E37)
        nextSeed = seed &+ 101
        main.onEvent = { [weak self] e in self?.handleMain(e) }
    }

    private var allEngines: [SlimeEngine] {
        [main] + minis.map(\.engine) + (ghost.map { [$0] } ?? [])
    }

    // MARK: - Time

    public func advance(to wall: Double) {
        if !primed {
            primed = true
            wallTime = wall
            scaledWall = wall
        }
        scaledWall += (wall - wallTime) * timeScale
        wallTime = wall
        main.advance(to: scaledWall)
        for m in minis { m.engine.advance(to: scaledWall) }
        ghost?.advance(to: scaledWall)
        let target = main.time
        var steps = 0
        while time + h <= target + 1e-9, steps < 48 {
            time += h
            steps += 1
            stepChoreography()
        }
        publishBlobs()
    }

    public func simulate(_ seconds: Double) {
        if !primed { advance(to: wallTime) }
        var remaining = seconds
        while remaining > 1e-12 {
            let chunk = min(remaining, 0.1)
            remaining -= chunk
            advance(to: wallTime + chunk / max(timeScale, 1e-6))
        }
    }

    public func resume() {
        for e in allEngines { e.resume() }
        primed = false
    }

    /// Slowest acceptable redraw interval: nil while anything is in flight.
    public var frameInterval: Double? {
        if split != nil || !absorbs.isEmpty || ghost != nil || minis.contains(where: { $0.phase != .live }) { return nil }
        var best: Double? = 1.0 / 30.0
        for e in allEngines {
            guard let b = best else { return nil }
            guard let f = e.frameInterval else { return nil }
            best = min(b, f)
        }
        return best
    }

    // MARK: - Output

    public func frames() -> [PlacedSlime] {
        var out: [PlacedSlime] = [PlacedSlime(id: nil, frame: main.frame(), scale: 1, offset: .zero)]
        for m in minis where m.phase != .pinching {
            if m.phase == .live, m.slot >= maxVisibleMinis { continue }
            out.append(PlacedSlime(id: m.id, frame: m.engine.frame(), scale: Self.miniScale, offset: SIMD2(0, -Double(m.row) * Self.rowLift)))
        }
        if let g = ghost {
            out.append(PlacedSlime(id: "ghost", frame: g.frame(), scale: 1, offset: .zero))
        }
        return out
    }

    public func drainCues() -> [SoundCue] {
        var cues = stageCues
        stageCues.removeAll()
        for e in allEngines { cues += e.drainCues() }
        return cues
    }

    private func cue(_ s: SlimeSound, rate: Double = 1, gain: Double = 1) {
        stageCues.append(SoundCue(s, rate: rate, gain: gain * s.baseGain))
    }

    /// Number of live minis the host should summarise with a badge.
    public var overflowCount: Int { max(0, minis.filter { $0.phase == .live }.count - maxVisibleMinis) }

    // MARK: - Input

    /// Pointer in main R units relative to the main contact point, or nil when away.
    public func pointer(_ p: SIMD2<Double>?) {
        main.pointer(p)
        for m in minis {
            guard let p else { m.engine.pointer(nil); continue }
            let local = (p - SIMD2(0, -Double(m.row) * Self.rowLift)) / Self.miniScale
            m.engine.pointer(local)
        }
    }

    public func hitTest(_ p: SIMD2<Double>) -> StageHit {
        let mc = main.body.centroid
        if simd_distance(p, mc) < 1.15 * main.body.sizeScale { return .main }
        for m in minis where m.phase == .live && m.slot < maxVisibleMinis {
            let c = m.engine.body.centroid * Self.miniScale + SIMD2(0, -Double(m.row) * Self.rowLift)
            if simd_distance(p, c) < 1.2 * Self.miniScale { return .mini(m.id) }
        }
        return .none
    }

    public func mini(_ id: String) -> MiniSlime? {
        minis.first { $0.id == id }
    }

    // MARK: - Sessions

    /// Pinches a new mini off the main slime. Returns nil when the id already exists.
    @discardableResult
    public func spawnMini(id: String) -> MiniSlime? {
        guard mini(id) == nil else { return nil }
        let engine = SlimeEngine(profile: .mini, seed: nextSeed)
        nextSeed &+= 7919
        engine.theme = theme
        engine.reduceMotion = reduceMotion
        let slot = minis.filter { $0.phase != .merging }.count
        let m = MiniSlime(id: id, engine: engine, slot: slot, at: time)
        engine.onEvent = { [weak self, weak m] e in
            guard let self, let m else { return }
            self.handleMini(m, e)
        }
        minis.append(m)
        if reduceMotion {
            placeAtSlot(m, animated: false)
            m.phase = .live
            m.phaseSince = time
            engine.faceOpacity = 1
        } else {
            engine.faceOpacity = 0
            main.setLean(0.12 * side, duration: 0.3)
            main.glanceAt(SIMD2(0.5 * side, -0.2), for: 0.6)
        }
        updateMainShrink()
        return m
    }

    public func setMiniState(_ id: String, _ s: AgentState) {
        mini(id)?.engine.agent(s)
    }

    /// Ends a session: the mini hops back into the main slime (or vanishes when reduceMotion).
    public func removeMini(_ id: String) {
        guard let m = mini(id) else { return }
        switch m.phase {
        case .merging:
            return
        case .pinching:
            minis.removeAll { $0 === m }
            main.setLean(0, duration: 0.25)
            reslot()
        case .flying, .live:
            if reduceMotion {
                minis.removeAll { $0 === m }
                main.absorbed()
                reslot()
            } else {
                m.phase = .merging
                m.phaseSince = time
                let target = main.body.centroid / Self.miniScale
                let root = m.engine.body.root
                let t = 0.4
                let vx = (target.x - root.x) / t
                let vy = -0.5 * m.engine.body.params.rootGravity * t + (target.y + 0.86 - root.y) / t
                m.engine.launch(velocity: SIMD2(vx, vy))
                m.engine.setFaceOpacity(0, duration: 0.3)
                reslot()
            }
        }
        updateMainShrink()
    }

    private func slotX(_ slot: Int) -> Double {
        side * (Self.firstSlot + Double(slot % Self.slotsPerRow) * Self.slotPitch)
    }

    private func placeAtSlot(_ m: MiniSlime, animated: Bool) {
        let tx = slotX(m.slot) / Self.miniScale
        if !animated || reduceMotion {
            m.engine.teleport(to: SIMD2(tx, 0))
            m.engine.rest()
            return
        }
        let root = m.engine.body.root
        let t = 0.3
        let vx = (tx - root.x) / t
        let vy = -0.5 * m.engine.body.params.rootGravity * t - root.y / t
        m.engine.launch(velocity: SIMD2(vx, vy))
    }

    /// Re-packs slots after a removal so the row never has a gap.
    private func reslot() {
        var k = 0
        for m in minis where m.phase != .merging {
            if m.slot != k {
                m.slot = k
                if m.phase == .live { placeAtSlot(m, animated: true) }
            }
            k += 1
        }
    }

    private func updateMainShrink() {
        let live = minis.filter { $0.phase != .merging }.count
        let s = 1 - 0.03 * Double(min(4, live))
        if split == nil { main.setSizeScale(s, duration: 0.3) }
    }

    private func handleMini(_ m: MiniSlime, _ e: SlimeEvent) {
        if case .landed = e, m.phase == .flying {
            m.phase = .live
            m.phaseSince = time
            m.engine.setFaceOpacity(1, duration: 0.2)
        }
        onMiniEvent?(m.id, e)
    }

    // MARK: - Split

    private func handleMain(_ e: SlimeEvent) {
        if case .splitRequested(let extra) = e { split(extra: extra) }
        onEvent?(e)
    }

    /// Five clicks: the main slime bursts into 3–6 droplets that bounce and flow back by 1.8 s.
    public func split(extra: Int) {
        guard split == nil, ghost == nil else { return }
        if reduceMotion {
            main.startDizzy()
            return
        }
        main.beginSplit()
        let n = max(3, min(6, 3 + extra))
        let r = sqrt(0.75 / Double(n))
        let c = main.body.centroid
        var drops: [Droplet] = []
        for k in 0..<n {
            let u = n == 1 ? 0.5 : Double(k) / Double(n - 1)
            let angle = (-25 - 130 * u) * Double.pi / 180 + rng.range(-0.14...0.14)
            let speed = rng.range(2.2...3.1)
            var d = Droplet(id: k, position: c + SIMD2(cos(angle), sin(angle)) * 0.3, velocity: SIMD2(cos(angle), sin(angle)) * speed, radius: r)
            d.restitution = 0.45
            drops.append(d)
        }
        split = SplitRun(startedAt: time, droplets: drops, total: n)
    }

    private func stepSplit() {
        guard var run = split else { return }
        let t = time - run.startedAt
        let c = main.body.centroid
        var mergedNow: [Int] = []
        for i in run.droplets.indices {
            if t < 0.9 {
                if run.droplets[i].step(h: h, gravity: 10) {
                    cue(.plip, rate: rng.range(0.9...1.25), gain: 0.7)
                }
            } else {
                var d = run.droplets[i]
                let a = (c - d.position) * 40 - d.velocity * 8
                d.velocity += a * h
                d.position += d.velocity * h
                d.position.y = min(d.position.y, -d.radius)
                d.age += h
                run.droplets[i] = d
                if simd_distance(d.position, c) < 0.45 || t >= 1.8 {
                    mergedNow.append(i)
                }
            }
        }
        for i in mergedNow.sorted(by: >) {
            run.droplets.remove(at: i)
            run.merged += 1
            main.impulse(.puff(scale: 0.08))
            cue(.merge, rate: 1 + 0.06 * Double(run.merged))
        }
        if run.droplets.isEmpty {
            split = nil
            main.endSplit()
            updateMainShrink()
        } else {
            split = run
        }
    }

    // MARK: - Pinch-off and merge-back

    private func stepPinches() {
        for m in minis {
            switch m.phase {
            case .pinching:
                let t = time - m.phaseSince
                if t >= 0.52 {
                    // Neck breaks: recoil, then the droplet flies to its slot.
                    main.pinchRecoil(side: side)
                    main.setLean(0, duration: 0.3)
                    let centre = SIMD2(Self.pinchReach * side, -0.45) / Self.miniScale
                    let root = centre + SIMD2(0, 0.86)
                    m.engine.teleport(to: root)
                    let tx = slotX(m.slot) / Self.miniScale
                    let tf = 0.4
                    let vx = (tx - root.x) / tf
                    let vy = -0.5 * m.engine.body.params.rootGravity * tf - root.y / tf
                    m.engine.launch(velocity: SIMD2(vx, vy))
                    m.phase = .flying
                    m.phaseSince = time
                }
            case .flying:
                if time - m.phaseSince > 1.2 {
                    m.phase = .live
                    m.phaseSince = time
                    placeAtSlot(m, animated: false)
                    m.engine.setFaceOpacity(1, duration: 0.2)
                }
            case .merging:
                let centre = m.engine.body.centroid * Self.miniScale + SIMD2(0, -Double(m.row) * Self.rowLift)
                let c = main.body.centroid
                if simd_distance(centre, c) < 1.2 || time - m.phaseSince > 1.5 {
                    absorbs.append(Absorb(position: centre, velocity: m.engine.body.rootVelocity * Self.miniScale,
                                          radius: Self.miniScale * m.engine.body.sizeScale, startedAt: time))
                    minis.removeAll { $0 === m }
                    reslot()
                    updateMainShrink()
                }
            case .live:
                break
            }
        }
        var done: [Int] = []
        let c = main.body.centroid
        for i in absorbs.indices {
            var a = absorbs[i]
            let u = clamp((time - a.startedAt) / 0.25, 0, 1)
            a.velocity += (c - a.position) * 60 * h - a.velocity * 10 * h
            a.position += a.velocity * h
            a.radius = Self.miniScale * (1 - Ease.inQuad.apply(u))
            absorbs[i] = a
            if u >= 1 { done.append(i) }
        }
        for i in done.sorted(by: >) {
            absorbs.remove(at: i)
            main.absorbed()
        }
    }

    private func pinchBlobs() -> [Blob] {
        var out: [Blob] = []
        for m in minis where m.phase == .pinching {
            let t = time - m.phaseSince
            let root = main.body.root
            if t < 0.3 {
                let r = Self.miniScale * Ease.outCubic.apply(t / 0.3)
                out.append(Blob(position: root + SIMD2(0.55 * side, -0.45), radius: r))
            } else {
                let u = Ease.inOutSine.apply(min(1, (t - 0.3) / 0.22))
                let x = 0.55 + (Self.pinchReach - 0.55) * u
                out.append(Blob(position: root + SIMD2(x * side, -0.45), radius: Self.miniScale, stretch: 1 + 0.15 * sin(u * .pi), heading: 0))
            }
        }
        return out
    }

    // MARK: - Ghost (drag-out)

    /// Starts dragging a ghost copy out of the notch. `target` is the pointer in main R units.
    public func beginDragOut(at target: SIMD2<Double>) {
        guard ghost == nil, split == nil else { return }
        let g = SlimeEngine(profile: .ghost, seed: nextSeed)
        nextSeed &+= 7919
        g.theme = theme
        g.reduceMotion = reduceMotion
        g.opacity = 0.7
        let start = main.body.root
        g.teleport(to: start)
        ghost = g
        ghostSpring = Spring2D(value: start, response: 0.45, dampingFraction: 0.75)
        ghostSpring?.target = target
        ghostLast = start
        ghostReturning = false
        main.trigger(.surprised)
        awayAt = time + 0.5
    }

    public func updateDragOut(target: SIMD2<Double>) {
        guard ghost != nil, !ghostReturning else { return }
        ghostSpring?.target = target
    }

    /// `dropped` = the ghost landed on a window; otherwise it springs back into the notch.
    public func endDragOut(dropped: Bool) {
        guard let g = ghost else { return }
        awayAt = nil
        if dropped {
            ghost = nil
            ghostSpring = nil
            main.setAway(false)
            main.trigger(.happy)
        } else {
            ghostReturning = true
            ghostSpring = Spring2D(value: g.body.root, response: 0.32, dampingFraction: 0.6)
            ghostSpring?.target = main.body.root
            ghostSpring?.velocity = ghostVelocity
            g.setEyeOverride(nil)
        }
    }

    private func stepGhost() {
        if let a = awayAt, time >= a {
            main.setAway(true)
            awayAt = nil
        }
        guard let g = ghost, var spring = ghostSpring else { return }
        spring.advance(h)
        ghostSpring = spring
        let p = spring.value
        ghostVelocity = (p - ghostLast) / h
        ghostLast = p
        g.teleport(to: p)
        let speed = simd_length(ghostVelocity)
        let s = 1 + 0.25 * min(1, speed / 40)
        g.ghostStretch = SIMD2(s, 1 / s)
        g.ghostHeading = speed > 0.5 ? atan2(ghostVelocity.y, ghostVelocity.x) : g.ghostHeading
        if speed > 2 {
            let v = ghostVelocity / speed
            g.glanceAt(SIMD2(0.62 * v.x, -0.5 * v.y), for: 0.12)
        }
        if !ghostReturning {
            if speed > 113 { g.setEyeOverride(.squint, for: 0.12) }
        } else if simd_distance(p, main.body.root) < 0.15, speed < 4 {
            ghost = nil
            ghostSpring = nil
            main.setAway(false)
            main.impulse(.puff(scale: 0.08))
            cue(.pop)
        }
    }

    // MARK: - Per-step

    private func stepChoreography() {
        stepSplit()
        stepPinches()
        stepGhost()
    }

    private func publishBlobs() {
        var blobs = pinchBlobs()
        if let run = split {
            for d in run.droplets {
                blobs.append(Blob(position: d.position, radius: d.radius, stretch: d.stretch, heading: d.heading))
            }
        }
        for a in absorbs where a.radius > 0.01 {
            blobs.append(Blob(position: a.position, radius: a.radius))
        }
        if blobs != main.blobs { main.blobs = blobs }
    }
}
