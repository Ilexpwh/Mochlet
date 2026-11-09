import Foundation
import simd

/// One slime: physics, face, states, emotes and the click grammar, all on engine time.
/// The host feeds pointer/press/audio input and reads `frame()` once per drawn frame.
@MainActor
public final class SlimeEngine {
    public let profile: SlimeProfile
    /// Species, colour and clothes. Set by the stage; the renderer reads it next to the frame.
    /// A new look reshapes the body (silhouette, feel) and refits the face.
    public var appearance: SlimeAppearance = .rimuru {
        didSet {
            if oldValue.look != appearance.look { applyLook() }
            if oldValue.faceStyle != appearance.faceStyle { applyFaceStyle() }
        }
    }
    /// What the host can afford at its pixel size (surface effects and idle flutter need ≥ 24 px/R).
    public var detail: DetailLevel = .full
    public private(set) var traitAnim = TraitAnim()
    private var earTwitch: (side: Double, at: Double)?
    private var nextEarTwitch: Double = 4
    private var tailPhase: Double = 0
    private var tailAmp: Double = 0.18
    private var wingSpring = Spring1D(value: 0, omega: 14, zeta: 0.6)
    private var antennaSpring = Spring1D(value: 0, omega: 10, zeta: 0.35)
    private var prevCentroidX: Double = 0
    private var prevCentroidY: Double = 0
    private var haveCentroid = false
    private var wasAirborne = false
    /// Follow-through: features lag the body and overshoot on landings.
    private var tailSpring = Spring1D(value: 0, omega: 12, zeta: 0.3)
    private var earSpring = Spring1D(value: 0, omega: 18, zeta: 0.3)
    private var tipSpring = Spring1D(value: 0, omega: 16, zeta: 0.28)
    private var hatSpring = Spring2D(value: .zero, omega: 20, zeta: 0.32)

    // Arms, hands and props.
    private var armRig = ArmRig()
    public enum GestureOwner: Sendable, Equatable { case host, emote, state }
    private var gesturePose: ArmPose?
    private var gestureUntil: Double = 0
    private var gestureOwner: GestureOwner = .host
    private var propSpring = Spring2D(value: .zero, omega: 18, zeta: 0.36)
    private var propLive = false
    private var propShownAt: Double = 0
    private var hmmCount = 0
    /// The current arm pose (derived from the chewing timeline, gestures, state and occasion).
    public var armPose: ArmPose { armRig.pose }

    // Chewing v2: catch the file, bite it, digest it, file it.
    public private(set) var chewPhase: ChewPhase?
    private var chewKind: Prop.FileKind = .doc
    private var chewProp: Prop = .file(kind: .doc, bites: 0)
    public private(set) var bites: Double = 0
    private var chewHostDriven = false
    private var hostProgress: Double = 0
    private var digestStartedAt: Double?
    private var filingAt: Double?

    /// What the slime is busy with, as the host sees it; with `dressForOccasion` it adds a prop
    /// or a piece of clothing on top of the chosen outfit (never stored).
    public enum Occasion: String, Sendable, CaseIterable { case reading, call, rest, working }
    public var occasion: Occasion? {
        didSet { if occasion == .call, oldValue != .call { cue(.ring, gain: 0.6) } }
    }

    /// The chosen outfit plus the situational piece for the current state and occasion.
    public var resolvedOutfit: SlimeOutfit {
        var o = appearance.outfit
        guard appearance.dressForOccasion, profile.kind == .main else { return o }
        if o.eyewear == .none, state == .chewing || occasion == .reading { o.eyewear = .roundGlasses }
        if o.headwear == .none, state == .sleeping { o.headwear = .nightcap }
        return o
    }
    private var nextSurfaceEmit: Double = 1
    public var theme: SlimeTheme {
        get { appearance.palette }
        set { appearance.palette = newValue }
    }
    public private(set) var body: SoftBody
    public var eyeRig: EyeRig
    public var gaze = Gaze()
    public private(set) var blink = BlinkScheduler()
    public private(set) var breath: BreathOscillator
    public let scheduler = Scheduler()
    public var reduceMotion = false
    public var onEvent: ((SlimeEvent) -> Void)?
    /// Idle seconds before falling asleep (pointer farther than `sleepDistance` R).
    public var sleepAfter: Double = 120
    public var sleepDistance: Double = 7
    /// Whole-slime opacity (ghost 0.7, dimmed main 0.4). Animate with `setOpacity`.
    public var opacity: Double {
        get { opacityAnim.value }
        set { opacityAnim.set(newValue) }
    }
    /// Face-only opacity (minis fade their eyes in after pinch-off).
    public var faceOpacity: Double {
        get { faceOpacityAnim.value }
        set { faceOpacityAnim.set(newValue) }
    }
    private var opacityAnim = AnimatedValue(1)
    private var faceOpacityAnim = AnimatedValue(1)
    /// Eyes closed and no blinks while the ghost is out (drag-out).
    public private(set) var isAway = false
    /// Extra metaball circles (split droplets, pinch-off bulge) supplied by the stage.
    public var blobs: [Blob] = []
    public var ghostStretch = SIMD2<Double>(1, 1)
    public var ghostHeading: Double = 0
    /// Resting blush of the main slime (Rimuru keeps faint cheek marks).
    public var baseBlush: Double

    private var clock: SlimeClock
    private var rng: SeededRandom
    public private(set) var time: Double = 0
    private var wallTime: Double = 0
    private var alpha: Double = 0
    private let h = SoftBodyParams.substep

    // Body modifiers
    private var lean = AnimatedValue(0)
    private var flatten = AnimatedValue(1)
    private var sizeScale = AnimatedValue(1)
    /// Temporary body morphs (melt spread, puffed cheeks, heart-shaped top): blobs in the silhouette
    /// whose size follows `morphAmount`.
    private enum MorphKind { case melt, puff, heartBody }
    private var morph: MorphKind?
    private var morphAmount = AnimatedValue(0)
    /// The caught file is hugged for a beat before the first bite.
    private var chewHug = false
    private var shakeX = AnimatedValue(0)
    private var shakeY = AnimatedValue(0)
    private var pulse: Double = 0
    /// A hop waiting for its anticipation crouch to finish.
    private var hopAt: (time: Double, v0: Double)?
    /// Vertical stretch while airborne (1 on the floor).
    private var airStretch: Double = 1
    private var coreSpring: Spring2D
    /// The inner core's scale trails the body's and overshoots (secondary motion).
    private var coreScaleSpring = Spring2D(value: SIMD2(1, 1), omega: 10, zeta: 0.35)
    /// The face slides down the body while melting (R, +down).
    private var faceSlide = AnimatedValue(0)
    /// Strain creases radiating from where the body was last squeezed.
    private var strainAngle: Double = 0
    private var strainAmount = AnimatedValue(0)
    /// Quick successive presses: the third one draws a sweat drop.
    private var pressBurst = 0
    private var lastPressAt: Double = -10
    private var tint = StateTint.none
    private var tintTarget = StateTint.none
    private var glowBoost: Double = 0
    private var pendingDust: (speed: Double, until: Double)?

    // Face
    private var eyeScale = AnimatedValue(1)
    private var blush: AnimatedValue
    private var mouthOpen = AnimatedValue(0)
    private var baseEye: EyeShape = .open
    private var baseMouth: MouthShape = .smileTiny
    private var eyeOverride: (left: EyeShape, right: EyeShape, until: Double)?
    private var mouthOverride: (shape: MouthShape, until: Double)?
    private var glance: (target: SIMD2<Double>, until: Double)?
    private var gazeOverride: SIMD2<Double>?
    private var gazeBlend: Double = 0
    private var coreBoost: Double = 0
    private var micLevels: [Double] = Array(repeating: 0, count: 5)

    // State
    public private(set) var agentState: AgentState = .idle
    public private(set) var userState: UserState = .none
    public private(set) var state: SlimeState = .idle
    public private(set) var stateEnteredAt: Double = 0
    public private(set) var emote: SlimeEmote?
    private var emoteUntil: Double = 0
    private var pendingAgentState: AgentState?
    private var chewSide: Double = 1
    private var chewStartedAt: Double = 0
    private var ingestResult: Bool?
    private var lastInteractionAt: Double = 0

    // Interaction
    public private(set) var pointer: SIMD2<Double>?
    public private(set) var isHovering = false
    private var hoverSince: Double = 0
    private var shyFired = false
    public var clickGrammar = ClickGrammar()
    public private(set) var isPressed = false
    public private(set) var isHolding = false
    private var holdStartedAt: Double = 0
    public private(set) var audioLevel: Double = 0
    private var dragDirection: Double?

    // Output
    private var cues: [SoundCue] = []
    private var lastCueAt: [SlimeSound: Double] = [:]
    private var accessories: [AccessoryInstance] = []
    private var particles: [Particle] = []
    private var activity: Int = 0

    private struct AccessoryInstance {
        enum Owner { case state, emote }
        var kind: AccessoryKind
        var startedAt: Double
        var removeAt: Double?
        var owner: Owner
        /// Which cheek a sweat drop sits on (+1 right).
        var side: Double = 1
    }

    private static let stateTag = "state"
    private static let emoteTag = "emote"
    private static let questionTag = "question"

    public init(profile: SlimeProfile = .main, seed: UInt64 = 1) {
        self.profile = profile
        var b = SoftBody(params: profile.body.applying(look: SlimeLook.rimuru, mini: profile.kind == .mini))
        b.floorEnabled = profile.floorEnabled
        body = b
        eyeRig = profile.eyeRig
        rng = SeededRandom(seed: seed)
        clock = SlimeClock(step: SoftBodyParams.substep)
        breath = BreathOscillator(seed: seed, phase: Double(seed % 7) * 0.9)
        coreSpring = Spring2D(value: b.centroid, omega: 10, zeta: 0.35)
        baseBlush = FaceTable.baseBlush(kind: profile.kind, face: .anime, blushEnabled: profile.blushEnabled)
        blush = AnimatedValue(baseBlush)
        blink.prime(at: 0, rng: &rng)
        enterState(.idle)
        applyFaceStyle()
    }

    // MARK: - Time

    /// Advance with a wall-clock timestamp (seconds). Runs the due substeps.
    public func advance(to wall: Double) {
        wallTime = wall
        let (steps, a) = clock.advance(to: wall)
        alpha = a
        for _ in 0..<steps { substep() }
    }

    /// Advance by a duration (tools, tests), in chunks the clock accepts without clamping.
    public func simulate(_ seconds: Double) {
        if !clock.isPrimed { advance(to: wallTime) }
        var remaining = seconds
        while remaining > 1e-12 {
            let chunk = min(remaining, clock.maxFrameDt)
            remaining -= chunk
            advance(to: wallTime + chunk)
        }
    }

    /// Forget the last wall time after a pause so the engine does not catch up in one burst.
    public func resume() {
        clock.resume()
    }

    public var frameInterval: Double? {
        switch activity {
        case 2...: return nil
        case 1: return 1.0 / 60.0
        default: return 1.0 / 30.0
        }
    }

    private func substep() {
        time += h
        scheduler.fire(upTo: time)
        lean.advance(to: time)
        flatten.advance(to: time)
        sizeScale.advance(to: time)
        morphAmount.advance(to: time)
        if morph != nil, !morphAmount.isAnimating, morphAmount.value < 1e-3 { morph = nil }
        faceSlide.advance(to: time)
        strainAmount.advance(to: time)
        for i in accessories.indices where accessories[i].kind == .sweat && accessories[i].removeAt == nil && time - accessories[i].startedAt > 0.62 {
            accessories[i].removeAt = time
        }
        shakeX.advance(to: time)
        shakeY.advance(to: time)
        eyeScale.advance(to: time)
        blush.advance(to: time)
        mouthOpen.advance(to: time)
        opacityAnim.advance(to: time)
        faceOpacityAnim.advance(to: time)
        if let o = eyeOverride, time >= o.until { eyeOverride = nil }
        if let m = mouthOverride, time >= m.until { mouthOverride = nil }
        if let g = glance, time >= g.until { glance = nil }
        if emote != nil, time >= emoteUntil { endEmote() }
        tickState()
        updateGaze()
        blink.advance(to: time, rng: &rng)
        breath.advance(dt: h, time: time)
        if let pending = hopAt, time >= pending.time {
            hopAt = nil
            launchHop(pending.v0)
        }
        // Air stretch: snaps tall at take-off (launchHop) and relaxes toward the speed-based
        // target, so the body is thinnest leaving the floor and round again at the apex.
        let stretchTarget = body.airborne && !reduceMotion ? 1 + min(0.20, 0.08 * abs(body.rootVelocity.y)) : 1
        airStretch = approach(airStretch, toward: stretchTarget, tau: 0.08, dt: h)
        body.squash = flatten.value * breath.value * (1 + pulse) * airStretch
        body.lean = lean.value
        body.offset = SIMD2(shakeX.value, shakeY.value)
        body.sizeScale = sizeScale.value
        if appearance.look.feel == .airy, !body.airborne {
            // Airy slimes hover a touch above their contact patch.
            body.offset.y -= 0.04 + 0.025 * sin(2 * .pi * 0.45 * time)
        }
        let events = body.step(h: h)
        for e in events {
            if case .landed(let speed) = e { landed(speed: speed) }
        }
        tickTraits()
        tickArms()
        if let d = pendingDust {
            if body.bottomY > -0.02 {
                let c = body.centroid
                for side in [-1.0, 1.0] {
                    spawn(.dust, at: SIMD2(c.x + side * (body.contactWidth / 2 + 0.1), -0.05),
                          velocity: SIMD2(side * (1.0 + 0.1 * d.speed), -0.3), life: 0.35, size: 0.1)
                }
                pendingDust = nil
            } else if time > d.until {
                pendingDust = nil
            }
        }
        stepParticles()
        coreSpring.target = body.centroid + SIMD2(0, -0.04)
        coreSpring.advance(h)
        // Extents without allocating: this runs every substep.
        var rMinX = Double.infinity, rMaxX = -Double.infinity, rTop = Double.infinity
        for q in body.referenceRing { rMinX = min(rMinX, q.x); rMaxX = max(rMaxX, q.x); rTop = min(rTop, q.y) }
        var minX = Double.infinity, maxX = -Double.infinity, top = Double.infinity
        for q in body.points { minX = min(minX, q.x); maxX = max(maxX, q.x); top = min(top, q.y) }
        if rMaxX - rMinX > 1e-6, rTop < -1e-6 {
            coreScaleSpring.target = SIMD2((maxX - minX) / (rMaxX - rMinX), top / rTop)
        }
        coreScaleSpring.advance(h)
        tint.opacity = approach(tint.opacity, toward: tintTarget.opacity, tau: 0.25, dt: h)
        tint.desaturation = approach(tint.desaturation, toward: tintTarget.desaturation, tau: 0.25, dt: h)
        if tintTarget.opacity > 0 { tint.color = tintTarget.color }
        glowBoost = max(0, glowBoost - h / 0.15)
        for out in clickGrammar.advance(to: time) { handle(out) }
        if isHovering, !shyFired, state == .idle, time - hoverSince >= 2.5 {
            shyFired = true
            trigger(.shy)
        }
        if state == .idle, !isPressed, time - lastInteractionAt > sleepAfter {
            let far = pointer.map { simd_length($0 - body.centroid) >= sleepDistance } ?? true
            if far { sleepNow() }
        }
    }

    private func landed(speed: Double) {
        glowBoost = 1
        if speed > 0.8 {
            cue(.land, gain: clamp(speed / 5, 0.3, 1))
            if speed > 3.5 { cue(.wobble, gain: 0.35) }
        }
        if speed > 3, !reduceMotion {
            pendingDust = (speed, time + 0.3)
        }
        // Landing squash: the top should drop about 0.55 R on a hard landing (height ≈ 0.68) and
        // less on a hop. The lightly damped ring already compresses by about speed / ω₀ on its
        // own and then rings out, so the scripted flatten only adds what is missing, with two
        // small rebounds; pumping more into the anchors would resonate with the ring.
        if !reduceMotion, morph == nil, state != .sleeping, state != .split, speed > 0.5 {
            let want = 0.55 * clamp(speed / 2.5, 0.3, 1)
            let fromPhysics = speed / (body.params.anchorStiffness + 0.52 * body.params.pressure).squareRoot()
            let depth = max(0, want - fromPhysics) / max(1.0, -body.referenceRing.map(\.y).min()!)
            if depth > 0.01 {
                flatten.animate(keys: [.init(to: 1 - depth, duration: 0.07, ease: .outQuad), .init(to: 1 + 0.3 * depth, duration: 0.16, ease: .inOutSine),
                                       .init(to: 1 - 0.12 * depth, duration: 0.14, ease: .inOutSine), .init(to: 1, duration: 0.20, ease: .outBack)], at: time)
            }
        }
        onEvent?(.landed(speed: speed))
    }

    private func tickState() {
        let elapsed = time - stateEnteredAt
        switch state {
        case .working:
            pulse = 0.01 * sin(2 * .pi * 1.2 * elapsed)
        case .listening:
            pulse = approach(pulse, toward: 0.05 * audioLevel, tau: 0.05, dt: h)
            coreBoost = approach(coreBoost, toward: audioLevel, tau: 0.08, dt: h)
            for i in 0..<micLevels.count {
                let shaped = audioLevel * (0.55 + 0.45 * abs(sin(elapsed * (3.1 + Double(i)) + Double(i))))
                micLevels[i] = approach(micLevels[i], toward: shaped, tau: 0.04 + 0.025 * Double(i), dt: h)
            }
        default:
            pulse = approach(pulse, toward: 0, tau: 0.1, dt: h)
            coreBoost = approach(coreBoost, toward: 0, tau: 0.2, dt: h)
        }
    }

    private func updateGaze() {
        var target = SIMD2<Double>.zero
        if let p = pointer {
            target = gaze.pointerTarget(p - (body.centroid + SIMD2(0, -0.05)))
        }
        if let g = glance {
            target = g.target
        } else if let o = gazeOverride {
            target = target * (1 - gazeBlend) + o * gazeBlend
        }
        switch state {
        case .sleeping: target = SIMD2(0, -0.1)
        case .dizzy: target.x += 0.2 * sin(2 * .pi * 7 * (time - stateEnteredAt))
        case .split: target = .zero
        default: break
        }
        if let d = dragDirection { target.x = 0.5 * d }
        gaze.setTarget(target)
        gaze.advance(dt: h)
    }

    // MARK: - Input

    /// Pointer position in R units relative to the contact point (y down), or nil when away.
    public func pointer(_ local: SIMD2<Double>?) {
        pointer = local
        let hovering = local.map { simd_distance($0, body.centroid) < 1.35 * sizeScale.value } ?? false
        if hovering != isHovering { setHover(hovering) }
        if let l = local, simd_length(l - body.centroid) < sleepDistance {
            lastInteractionAt = time
        }
    }

    public func setHover(_ on: Bool) {
        guard on != isHovering else { return }
        isHovering = on
        if on {
            hoverSince = time
            shyFired = false
            if state.isQuiet || state == .working || state == .thinking {
                eyeScale.animate(to: currentStyle().eyeScale * 1.06, duration: 0.25, ease: .outBack, at: time)
                if !reduceMotion {
                    body.apply(.wobble(angle: rng.range(-2.4...(-0.7)), strength: 0.25))
                }
                cue(.hover, gain: 0.7)
            }
        } else {
            eyeScale.animate(to: currentStyle().eyeScale, duration: 0.3, at: time)
        }
    }

    public func pressBegan(at local: SIMD2<Double>) {
        isPressed = true
        lastInteractionAt = time
        let c = body.centroid
        let side: Double = local.x >= c.x ? 1 : -1
        // ぷにぷに: a local dent under the finger that ripples round the ring, a squint, strain
        // creases that fade, and a sweat drop on the third quick poke.
        strainAngle = atan2(local.y - c.y, local.x - c.x)
        if !reduceMotion { body.apply(.poke(angle: strainAngle, depth: 0.25)) }
        if emote == nil, dragDirection == nil { eyeOverride = (.squint, .squint, time + 0.25) }
        strainAmount = AnimatedValue(1)
        strainAmount.animate(to: 0, duration: 0.5, ease: .outQuad, at: time)
        pressBurst = time - lastPressAt < 0.9 ? pressBurst + 1 : 1
        lastPressAt = time
        if pressBurst == 3 { spawnSweat(side: side) }
        cue(.blip)
        if state == .sleeping { wake() }
        _ = clickGrammar.pressBegan(at: time, position: local)
    }

    public func pressMoved(to local: SIMD2<Double>) {
        guard isPressed else { return }
        for out in clickGrammar.pressMoved(at: time, position: local) { handle(out) }
    }

    public func pressEnded() {
        guard isPressed else { return }
        isPressed = false
        lastInteractionAt = time
        for out in clickGrammar.pressEnded(at: time) { handle(out) }
        if isHolding {
            isHolding = false
            onEvent?(.holdEnded(duration: time - holdStartedAt))
        }
    }

    private func handle(_ out: ClickGrammar.Output) {
        switch out {
        case .holdBegan:
            isHolding = true
            holdStartedAt = time
            onEvent?(.holdBegan)
        case .dragBegan:
            onEvent?(.dragOutBegan)
        case .click(let n):
            // React first so a host that asks a question on the click lets the poke play out.
            switch n {
            case 1:
                trigger(.poked)
            case 2:
                if !reduceMotion { body.apply(.wobble(angle: -.pi / 2, strength: 0.35)) }
            default:
                break
            }
            onEvent?(.clickClassified(count: n))
        case .splitNow(let extra):
            onEvent?(.splitRequested(extra: extra))
        }
    }

    public func setAudioLevel(_ level: Double) {
        audioLevel = approach(audioLevel, toward: clamp(level, 0, 1), tau: 0.03, dt: 1.0 / 60.0)
        if level > 0.05 { lastInteractionAt = time }
    }

    /// A file is being dragged over the slime from `direction` (+1 right, -1 left).
    public func dragEntered(fromDirection direction: Double) {
        let d: Double = direction >= 0 ? 1 : -1
        dragDirection = d
        lean.animate(to: 0.12 * d, duration: 0.3, ease: .outBack, at: time)
        eyeOverride = (.wide, .wide, .greatestFiniteMagnitude)
        mouthOverride = (.o, .greatestFiniteMagnitude)
        mouthOpen.animate(to: 0.5, duration: 0.25, at: time)
        if !reduceMotion { body.apply(.nudge(direction: SIMD2(0.6 * d, -0.2))) }
        lastInteractionAt = time
    }

    public func dragExited() {
        guard dragDirection != nil else { return }
        dragDirection = nil
        eyeOverride = nil
        mouthOverride = nil
        let style = currentStyle()
        lean.animate(to: style.lean, duration: 0.3, ease: .outBack, at: time)
        mouthOpen.animate(to: style.mouthOpen, duration: 0.25, at: time)
    }

    /// The host accepted a drop: the slime starts chewing.
    public func drop(kind: Prop.FileKind = .doc) {
        dragExited()
        onEvent?(.dropAccepted)
        chewKind = kind
        chewProp = .file(kind: kind, bites: 0)
        startChewing()
    }

    /// A one-off arm pose for `duration` seconds on top of whatever the state would show
    /// (thumbs up on an approval, a bell held high for a hot signal).
    public func gesture(_ pose: ArmPose, for duration: Double, owner: GestureOwner = .host) {
        gesturePose = pose
        gestureUntil = time + duration
        gestureOwner = owner
    }

    private func clearGesture(owner: GestureOwner) {
        if gesturePose != nil, gestureOwner == owner { gesturePose = nil }
    }

    /// The host's view of the eating pipeline. Progress holds the bites back until the file is
    /// really read; `digesting` and `filing` move the timeline on. Without it the timeline
    /// runs on its own (previews, filmstrips).
    public func setChewPhase(_ p: ChewPhase) {
        guard state == .chewing, chewPhase != nil else { return }
        switch p {
        case .catching:
            break
        case .biting(let fraction):
            chewHostDriven = true
            hostProgress = max(hostProgress, clamp(fraction, 0, 1))
        case .digesting:
            // The host is analysing: swallow after at least two bites (the next bite does it otherwise).
            chewHostDriven = true
            hostProgress = max(hostProgress, 0.6)
            if digestStartedAt == nil, case .biting = chewPhase ?? .catching, bites >= 0.3 - 1e-9 { startDigesting() }
        case .filing:
            hostProgress = 1
            if digestStartedAt != nil { startFiling() }
        }
    }

    // MARK: - Host state

    public func agent(_ s: AgentState) {
        lastInteractionAt = time
        if state == .error, s != .error, time - stateEnteredAt < 3 {
            pendingAgentState = s
            let at = stateEnteredAt + 3
            scheduler.schedule(at: at, tag: "agent") { [weak self] in
                guard let self, let p = self.pendingAgentState else { return }
                self.pendingAgentState = nil
                self.agent(p)
            }
            return
        }
        pendingAgentState = nil
        scheduler.cancel(tag: "agent")
        agentState = s
        if s != .idle, userState == .sleeping { wake() }
        refreshState()
    }

    public func setRecording(_ on: Bool) {
        lastInteractionAt = time
        if on {
            setUserState(.recording)
        } else if userState == .recording {
            setUserState(.none)
        }
    }

    public func greet() {
        setUserState(.greeting)
    }

    public func startListening() {
        lastInteractionAt = time
        if userState == .sleeping { wake() }
        setUserState(.listening)
    }

    public func stopListening(hadSpeech: Bool) {
        guard userState == .listening else { return }
        setUserState(.none)
        cue(.listenOff)
        if hadSpeech {
            glance = (SIMD2(0, -0.35), time + 0.22)
            scheduler.schedule(at: time + 0.25, tag: Self.emoteTag) { [weak self] in
                self?.trigger(.happy)
            }
        } else {
            flatten.animate(keys: [.init(to: 0.93, duration: 0.12, ease: .outQuad), .init(to: 1, duration: 0.32, ease: .outBack)], at: time)
        }
    }

    public func startChewing() {
        lastInteractionAt = time
        setUserState(.chewing)
    }

    /// Ends chewing with a gulp (success) or a confused shake (failure). Chewing lasts ≥ 0.9 s.
    public func ingestionFinished(success: Bool = true) {
        guard state == .chewing else { return }
        ingestResult = success
        hostProgress = 1
        chewHostDriven = false
        // The arms timeline (catch, bites, digest) needs about two seconds to read as eating.
        let at = max(time, chewStartedAt + (chewPhase != nil ? 2.9 : 0.9))
        if chewPhase != nil, digestStartedAt == nil {
            // Let the bite loop run on to digesting; the gulp waits for it.
            scheduler.schedule(at: at, tag: Self.stateTag) { [weak self] in self?.gulp() }
        } else {
            scheduler.cancel(tag: Self.stateTag)
            scheduler.schedule(at: at, tag: Self.stateTag) { [weak self] in self?.gulp() }
        }
    }

    private func gulp() {
        guard state == .chewing else { return }
        if chewPhase != nil, digestStartedAt == nil {
            // Still catching or biting: push the rest in now, then swallow.
            startDigesting()
            scheduler.schedule(at: time + 0.45, tag: Self.stateTag) { [weak self] in self?.gulp() }
            return
        }
        if chewPhase != nil, filingAt == nil { startFiling() }
        let ok = ingestResult ?? true
        mouthOpen.animate(to: 0, duration: 0.1, at: time)
        if ok {
            flatten.animate(keys: [.init(to: 0.72, duration: 0.08, ease: .outQuad),
                                   .init(to: 1.22, duration: 0.13, ease: .outQuad),
                                   .init(to: 1.0, duration: 0.24, ease: .outBack)], at: time)
            cue(.gulp)
        }
        scheduler.schedule(at: time + 0.42, tag: Self.stateTag) { [weak self] in
            guard let self else { return }
            self.setUserState(.none)
            self.trigger(ok ? .happy : .confused)
            if ok { self.gesture(.cheer, for: 0.7, owner: .emote) }
        }
    }

    private func startDigesting() {
        guard state == .chewing, digestStartedAt == nil else { return }
        chewPhase = .digesting
        digestStartedAt = time
        bites = 1
        chewProp = .file(kind: chewKind, bites: 1)
        scheduler.cancel(tag: Self.stateTag)
        mouthOpen.animate(to: 0.12, duration: 0.25, at: time)
        eyeOverride = (.focused, .focused, time + 1e9)
        cue(.gulp, rate: 1.3, gain: 0.6)
        scheduleDigestSlosh()
    }

    private func scheduleDigestSlosh() {
        scheduler.schedule(at: time + 0.9, tag: Self.stateTag) { [weak self] in
            guard let self, self.state == .chewing else { return }
            if !self.reduceMotion { self.body.apply(.wobble(angle: self.rng.range(-2.6...(-0.5)), strength: 0.2)) }
            self.scheduleDigestSlosh()
        }
    }

    private func startFiling() {
        guard state == .chewing, filingAt == nil else { return }
        if digestStartedAt == nil { digestStartedAt = time - 0.35 }
        chewPhase = .filing
        filingAt = time
        spawnSparkles(count: 1)
        cue(.pika, gain: 0.5)
    }

    private func spawnCrumbs() {
        let m = frameNow().mouth.center
        for side in [-1.0, 1.0] {
            spawn(.crumb, at: m + SIMD2(side * 0.12, 0.08), velocity: SIMD2(side * rng.range(0.25...0.45), 0.2), life: rng.range(0.45...0.65), size: 0.07)
        }
    }

    // MARK: - Arms

    private func desiredArmPose() -> ArmPose {
        guard appearance.armsEnabled, profile.kind == .main else { return .hidden }
        if state == .chewing, let cp = chewPhase {
            switch cp {
            case .catching: return chewHug ? .hug(chewProp) : .holdHigh(chewProp)
            case .biting: return .holdFront(chewProp)
            case .digesting, .filing: return .hidden
            }
        }
        guard detail >= .medium else { return .hidden }
        if let g = gesturePose {
            if time < gestureUntil { return g }
            gesturePose = nil
        }
        switch state {
        case .listening: return detail >= .full ? .holdSide(.mic, side: 1) : .hidden
        case .recording: return .holdSide(.phone, side: -1)
        case .sleeping, .split, .dizzy, .greeting, .chewing: return .hidden
        default: break
        }
        if let o = occasion {
            switch o {
            case .call: return .holdSide(.phone, side: -1)
            case .rest: return .holdSide(.mug, side: 1)
            case .working: return .holdSide(.pen, side: 1)
            case .reading: return .holdFront(.book)
            }
        }
        return .hidden
    }

    private func tickArms() {
        let want = desiredArmPose()
        if want != armRig.pose { armRig.retarget(to: want, at: time) }
        if digestStartedAt != nil, filingAt == nil {
            coreBoost = max(coreBoost, 0.22 + 0.18 * sin(2 * .pi * 0.8 * time))
        }
        guard want.prop != nil else { propLive = false; return }
        let bf = BodyFrame.fit(reference: body.referenceRing, referenceCentroid: body.referenceCentroid, current: body.points)
        let joints = armRig.joints(at: time)
        guard let place = ArmRig.propPlacement(want, joints: joints) else { propLive = false; return }
        let anchor = bf.transform(bf.referenceCentroid + place.offset * Self.armScale(bf))
        if !propLive {
            propLive = true
            propShownAt = time
            propSpring.snap(to: anchor)
            if case .catching = chewPhase {
                // The file falls into the raised hands.
                propSpring.value = anchor + SIMD2(0, -1.3)
                propSpring.velocity = SIMD2(0, 1.2)
            }
        }
        propSpring.target = anchor
        propSpring.advance(h)
        if simd_distance(propSpring.value, anchor) < 1e-3, simd_length(propSpring.velocity) < 1e-3 { propSpring.snap(to: anchor) }
    }

    /// Arm pose targets were authored for a body about 1 R across and 1.8 R tall. The bun (and
    /// every other silhouette) scales them by its own settled extents, so a hand that covered the
    /// eyes still does, and a prop held in front still clears the face.
    static func armScale(_ bf: BodyFrame) -> SIMD2<Double> {
        SIMD2(bf.referenceHalfWidth / 1.0, bf.referenceTopHeight / 1.80)
    }

    private func armFrames(ring: [SIMD2<Double>], bf: BodyFrame) -> (arms: [ArmFrame], props: [PropFrame], inner: [InnerItem], blobs: [Blob]) {
        var arms: [ArmFrame] = []
        var props: [PropFrame] = []
        var goo: [Blob] = []
        let pose = armRig.pose
        if !pose.isHidden || armRig.isAnimating(at: time) {
            let joints = armRig.joints(at: time)
            let bodyScale = (bf.scaleX * bf.scaleY).squareRoot()
            let k = Self.armScale(bf)
            for (i, j) in joints.enumerated() where j.reach > 0.02 {
                let shoulder = ring[TraitRig.index(angle: j.shoulderAngle, count: ring.count)]
                let arm = ArmFrame(side: i == 0 ? -1 : 1, shoulder: shoulder,
                                   elbow: bf.transform(bf.referenceCentroid + j.elbow * k),
                                   hand: bf.transform(bf.referenceCentroid + j.hand * k),
                                   reach: j.reach, handRadius: ArmRig.handRadius, shape: j.shape)
                arms.append(arm)
                goo += ArmRig.blobs(for: arm, bodyScale: bodyScale)
            }
            if let prop = pose.prop, propLive, let place = ArmRig.propPlacement(pose, joints: joints) {
                let lag = propSpring.value - propSpring.target
                let angle = place.angle + clamp(-lag.x * 1.5, -0.35, 0.35) + armRig.sipTilt(at: time)
                let pop = Ease.outBack.apply(min(1, (time - propShownAt) / 0.22))
                props.append(PropFrame(prop: prop, position: propSpring.value, angle: angle, scale: pop, behindHands: place.behindHands))
            }
        }
        var inner: [InnerItem] = []
        if let d = digestStartedAt {
            let age = time - d
            let fadeIn = min(1, age / 0.35)
            let fadeOut = filingAt.map { max(0, 1 - (time - $0) / 0.4) } ?? 1
            let op = fadeIn * fadeOut
            if op > 0.01 {
                for k in 0..<3 {
                    let ang = age * 2 * .pi * 0.45 + Double(k) * 2 * .pi / 3
                    let local = SIMD2(cos(ang) * 0.4, sin(ang) * 0.24 + 0.1)
                    inner.append(InnerItem(kind: .page, position: bf.transform(bf.referenceCentroid + local), angle: ang * 0.6 + Double(k), size: 0.2 - Double(k) * 0.02, opacity: op))
                }
            }
        }
        return (arms, props, inner, goo)
    }

    public func startQuestion() {
        lastInteractionAt = time
        if emote == .poked {
            // Let the poke play out (the question face clears emotes), then ask.
            let at = emoteUntil
            scheduler.schedule(at: at, tag: Self.questionTag) { [weak self] in self?.setUserState(.question) }
            return
        }
        setUserState(.question)
    }

    public func startDizzy() {
        setUserState(.dizzy)
    }

    public func beginSplit() {
        lastInteractionAt = time
        setUserState(.split)
    }

    public func endSplit() {
        guard userState == .split else { return }
        sizeScale.animate(to: 1, duration: 0.22, ease: .outBack, at: time)
        setUserState(.dizzy)
    }

    public func sleepNow() {
        guard state.isQuiet, userState != .sleeping else { return }
        setUserState(.sleeping)
    }

    public func wake() {
        guard userState == .sleeping else { return }
        userState = .none
        lastInteractionAt = time
        flatten.animate(to: 1, duration: 0.5, ease: .outBack, at: time)
        if !reduceMotion { body.apply(.puff(scale: 0.06)) }
        cue(.pop)
        refreshState()
        onEvent?(.wokeUp)
        let yawnToo = rng.chance(0.4)
        scheduler.schedule(at: time + 0.15, tag: Self.stateTag) { [weak self] in
            guard let self else { return }
            self.trigger(.stretch)
            if yawnToo {
                self.scheduler.schedule(at: self.time + 1.35, tag: Self.stateTag) { [weak self] in self?.trigger(.yawn) }
            }
        }
    }

    public func impulse(_ i: Impulse) {
        guard !reduceMotion else { return }
        body.apply(i)
    }

    /// Uniform rest-shape scale (stage choreography: split shrink, grow back).
    public func setSizeScale(_ s: Double, duration: Double, ease: Ease = .outCubic) {
        sizeScale.animate(to: s, duration: duration, ease: ease, at: time)
    }

    public func setFlatten(_ f: Double, duration: Double, ease: Ease = .outBack) {
        flatten.animate(to: f, duration: duration, ease: ease, at: time)
    }

    public func glanceAt(_ target: SIMD2<Double>, for duration: Double) {
        glance = (target, time + duration)
    }

    public func teleport(to root: SIMD2<Double>) {
        body.teleport(root: root)
    }

    public func launch(velocity: SIMD2<Double>) {
        body.launch(velocity: velocity)
    }

    public func rest() {
        body.rest()
    }

    // MARK: - Stage hooks

    public func setOpacity(_ o: Double, duration: Double, ease: Ease = .inOutSine) {
        opacityAnim.animate(to: o, duration: duration, ease: ease, at: time)
    }

    public func setFaceOpacity(_ o: Double, duration: Double, ease: Ease = .inOutSine) {
        faceOpacityAnim.animate(to: o, duration: duration, ease: ease, at: time)
    }

    public func setLean(_ radians: Double, duration: Double, ease: Ease = .outBack) {
        lean.animate(to: radians, duration: duration, ease: ease, at: time)
    }

    /// Eyes closed and dimmed while the ghost copy is being dragged around.
    public func setAway(_ on: Bool) {
        guard on != isAway else { return }
        isAway = on
        lastInteractionAt = time
        if on {
            setOpacity(0.4, duration: 0.35)
        } else {
            setOpacity(1, duration: 0.25)
        }
    }

    /// Temporary eye shapes from the stage (ghost squint, mini surprise).
    public func setEyeOverride(_ shape: EyeShape?, for duration: Double = 0.3) {
        if let shape {
            eyeOverride = (shape, shape, time + duration)
        } else {
            eyeOverride = nil
        }
    }

    /// Neck break at the end of a pinch-off: recoil away from `side` with the pinch sound.
    public func pinchRecoil(side: Double) {
        if !reduceMotion { body.apply(.slap(side: side, strength: 0.6)) }
        cue(.pinch)
    }

    /// A mini just merged back: puff, happy face for 0.8 s, absorb sound.
    public func absorbed() {
        if !reduceMotion { body.apply(.puff(scale: 0.1)) }
        eyeOverride = (.happyArc, .happyArc, time + 0.8)
        mouthOverride = (.omega, time + 0.8)
        blush.animate(keys: [.init(to: max(baseBlush, 0.6), duration: 0.15, ease: .outQuad), .init(to: baseBlush, duration: 0.7, ease: .inOutSine)], at: time)
        cue(.absorb)
    }

    /// Tunables for the Emote Lab.
    public var bodyParams: SoftBodyParams {
        get { body.params }
        set { if newValue.isStable { body.setParams(newValue) } }
    }

    public func setBreath(amplitude: Double, rate: Double, duration: Double = 0.6) {
        breath.amplitude.animate(to: amplitude, duration: duration, ease: .inOutSine, at: time)
        breath.rate.animate(to: rate, duration: duration, ease: .inOutSine, at: time)
    }

    // MARK: - Emotes

    public func trigger(_ e: SlimeEmote) {
        if state == .split || state == .chewing { return }
        endEmote()
        emote = e
        emoteUntil = time + e.duration
        let until = emoteUntil
        onEvent?(.emoteTriggered(e))
        let style = currentStyle()
        let pose = FaceTable.emote(e, faceStyle)
        eyeOverride = (pose.left, pose.right, until)
        if let m = pose.mouth { mouthOverride = (m, until) }
        switch e {
        case .proud, .excited: gesture(.cheer, for: e.duration, owner: .emote)
        case .yawn: gesture(.rubEyes, for: e.duration, owner: .emote)
        case .shy: gesture(.cover, for: e.duration, owner: .emote)
        case .love: gesture(.hug(.heart), for: e.duration, owner: .emote)
        case .confused: gesture(.scratchHead, for: e.duration, owner: .emote)
        case .cheer, .stretch: gesture(.cheer, for: e.duration, owner: .emote)
        case .hug: gesture(.hug(nil), for: e.duration, owner: .emote)
        case .thumbsUp: gesture(.thumbsUp(side: 1), for: e.duration, owner: .emote)
        default: break
        }
        switch e {
        case .happy:
            hop(1.6)
            blush.animate(to: max(baseBlush, 0.55), duration: 0.2, at: time)
        case .love:
            lean.animate(keys: [.init(to: 0.08, duration: 0.3, ease: .inOutSine), .init(to: -0.08, duration: 0.33, ease: .inOutSine),
                                .init(to: 0.08, duration: 0.33, ease: .inOutSine), .init(to: -0.08, duration: 0.33, ease: .inOutSine),
                                .init(to: style.lean, duration: 0.3, ease: .inOutSine)], at: time)
            blush.animate(to: 0.7, duration: 0.3, at: time)
            for k in 0..<4 {
                scheduler.schedule(at: time + Double(k) * 0.25, tag: Self.emoteTag) { [weak self] in
                    guard let self else { return }
                    let c = self.body.centroid
                    self.spawn(.heart, at: SIMD2(c.x + self.rng.range(-0.6...0.6), c.y - 0.9),
                               velocity: SIMD2(self.rng.range(-0.3...0.3), -0.9), life: 1.1, size: 0.2)
                }
            }
            cue(.love)
        case .proud:
            flatten.animate(keys: [.init(to: 0.92, duration: 0.12, ease: .outQuad), .init(to: 1.0, duration: 0.4, ease: .outBack)], at: time)
            lean.animate(keys: [.init(to: 0.1, duration: 0.2, ease: .outBack), .init(to: style.lean, duration: 0.7, ease: .outBack)], at: time)
            let c = body.centroid
            for k in 0..<5 {
                let a = -2.6 + Double(k) * 0.55
                spawn(.star, at: c + SIMD2(cos(a), sin(a)) * 1.35, velocity: SIMD2(cos(a), sin(a)) * 0.5, life: 0.8, size: 0.16)
            }
            cue(.proud)
        case .surprised:
            mouthOpen.animate(to: 0.7, duration: 0.1, at: time)
            eyeScale.animate(keys: [.init(to: style.eyeScale * 1.25, duration: 0.1, ease: .outBack), .init(to: style.eyeScale, duration: 0.5, ease: .outCubic)], at: time)
            hop(1.8)
            addAccessory(.exclamation, owner: .emote)
            cue(.pop)
        case .wink:
            cue(.pop)
        case .yawn:
            mouthOpen.animate(keys: [.init(to: 1, duration: 0.45, ease: .inOutSine), .init(to: 1, duration: 0.4, ease: .linear),
                                     .init(to: style.mouthOpen, duration: 0.5, ease: .inOutSine)], at: time)
            lean.animate(keys: [.init(to: -0.06, duration: 0.5, ease: .inOutSine), .init(to: style.lean, duration: 0.9, ease: .inOutSine)], at: time)
            cue(.sleep, rate: 0.9)
        case .annoyed:
            let side: Double = (pointer?.x ?? 1) >= 0 ? 1 : -1
            lean.animate(to: -0.14 * side, duration: 0.2, ease: .outBack, at: time)
            addAccessory(.anger, owner: .emote)
            cue(.annoyed)
        case .shy:
            blush.animate(to: 0.85, duration: 0.35, at: time)
            sizeScale.animate(to: 0.96, duration: 0.4, ease: .outCubic, at: time)
            let side: Double = (pointer?.x ?? 1) >= 0 ? -1 : 1
            glance = (SIMD2(0.45 * side, -0.05), until)
            cue(.hover, gain: 0.6)
        case .confused:
            glance = (SIMD2(0.3, 0.2), until)
            spawnSweat(side: 1, owner: .emote)
        case .excited:
            hop(1.6)
            scheduler.schedule(at: time + 0.5, tag: Self.emoteTag) { [weak self] in self?.hop(1.6) }
            scheduler.schedule(at: time + 0.2, tag: Self.emoteTag) { [weak self] in self?.spawnSparkles(count: 6) }
            cue(.finish, gain: 0.8)
        case .melt:
            // とけている: the body sags into a puddle and spreads at the base, eyes drooping.
            startMorph(.melt, duration: 0.7, ease: .inOutSine)
            // The release eases straight back: the jelly ring supplies the overshoot on its own.
            // 0.66 keeps the wider bun's puddle inside the expanded island (hero at x 96 of 640).
            flatten.animate(keys: [.init(to: 0.66, duration: 0.7, ease: .inOutSine), .init(to: 0.66, duration: 1.0, ease: .linear),
                                   .init(to: 1, duration: 0.5, ease: .inOutSine)], at: time)
            faceSlide.animate(to: 0.25, duration: 0.6, ease: .inOutSine, at: time)
            scheduler.schedule(at: time + 1.7, tag: Self.emoteTag) { [weak self] in
                guard let self else { return }
                self.morphAmount.animate(to: 0, duration: 0.5, ease: .inOutSine, at: self.time)
                self.faceSlide.animate(to: 0, duration: 0.5, ease: .inOutSine, at: self.time)
            }
            for k in 0..<3 {
                scheduler.schedule(at: time + 0.5 + Double(k) * 0.4, tag: Self.emoteTag) { [weak self] in
                    guard let self else { return }
                    let f = self.frameNow()
                    let side: Double = k % 2 == 0 ? 1 : -1
                    let at = f.body.transform(SIMD2(side * 1.05, -0.5))
                    self.spawn(.drip, at: at, velocity: SIMD2(side * 0.1, 0.1), life: 0.7, size: 0.14)
                }
            }
            cue(.squish, rate: 0.7, gain: 0.8)
        case .puff:
            // ふくらむ: cheeks balloon out, a glare, a pout and steam off the top.
            startMorph(.puff, duration: 0.2, ease: .outBack)
            sizeScale.animate(to: 1.06, duration: 0.3, ease: .outBack, at: time)
            blush.animate(to: max(baseBlush, 0.6), duration: 0.2, at: time)
            for k in 0..<3 {
                scheduler.schedule(at: time + 0.1 + Double(k) * 0.25, tag: Self.emoteTag) { [weak self] in
                    guard let self else { return }
                    let f = self.frameNow()
                    let at = f.body.transform(SIMD2(0.35 - Double(k) * 0.3, -2.05))
                    self.spawn(.steam, at: at, velocity: SIMD2(self.rng.range(-0.15...0.15), -0.7), life: 0.75, size: 0.16)
                }
            }
            cue(.annoyed, rate: 0.85)
        case .shock:
            // A startled jolt: ring eyes, a wide-open mouth, a quick stretch upward and a "!".
            mouthOpen.animate(to: 0.9, duration: 0.08, at: time)
            eyeScale.animate(keys: [.init(to: style.eyeScale * 1.3, duration: 0.08, ease: .outBack), .init(to: style.eyeScale * 1.15, duration: 0.6, ease: .outCubic)], at: time)
            // The jolt is a jump with no anticipation: the air stretch supplies the upward snap.
            hop(1.6, anticipation: 0)
            if !reduceMotion { shakeKicks([(0, -1.8), (0.07, 1.2)]) }
            addAccessory(.exclamation, owner: .emote)
            cue(.pyu, gain: 0.8)
        case .cry:
            // Welling eyes, a droopy mouth and tears running down both cheeks.
            blush.animate(to: max(baseBlush, 0.4), duration: 0.3, at: time)
            flatten.animate(to: 0.94, duration: 0.4, ease: .inOutSine, at: time)
            for k in 0..<5 {
                scheduler.schedule(at: time + 0.25 + Double(k) * 0.3, tag: Self.emoteTag) { [weak self] in
                    guard let self else { return }
                    let f = self.frameNow()
                    for e in f.eyes where e.visible {
                        // Tears fall from the ends of the stroke face's ribbons, or from the welling ball eyes.
                        let at = e.center + SIMD2(e.side * 0.06, self.faceStyle == .anime ? 0.55 : 0.22)
                        self.spawn(.drop, at: at, velocity: SIMD2(e.side * 0.08, 0.3), life: 0.75, size: 0.13)
                    }
                }
            }
            cue(.mu, rate: 0.8, gain: 0.6)
        case .hum:
            // A note grows out of the head and the body sways to it.
            addAccessory(.note, owner: .emote)
            lean.animate(keys: [.init(to: 0.07, duration: 0.45, ease: .inOutSine), .init(to: -0.07, duration: 0.5, ease: .inOutSine),
                                .init(to: 0.07, duration: 0.5, ease: .inOutSine), .init(to: style.lean, duration: 0.45, ease: .inOutSine)], at: time)
            cue(.note, gain: 0.6)
        case .cheer:
            hop(1.7)
            scheduler.schedule(at: time + 0.45, tag: Self.emoteTag) { [weak self] in self?.hop(1.5) }
            let c = body.centroid
            for k in 0..<4 {
                let a = -2.5 + Double(k) * 0.6
                spawn(.star, at: c + SIMD2(cos(a), sin(a)) * 1.4, velocity: SIMD2(cos(a), sin(a)) * 0.6, life: 0.8, size: 0.15)
            }
            cue(.pika)
        case .hug:
            // A self-hug: arms wrap round the belly, the top bulges into a heart, cheeks warm.
            startMorph(.heartBody, duration: 0.45, ease: .outBack)
            blush.animate(to: 0.75, duration: 0.3, at: time)
            lean.animate(keys: [.init(to: 0.06, duration: 0.4, ease: .inOutSine), .init(to: -0.06, duration: 0.5, ease: .inOutSine),
                                .init(to: style.lean, duration: 0.5, ease: .inOutSine)], at: time)
            for k in 0..<2 {
                scheduler.schedule(at: time + 0.3 + Double(k) * 0.4, tag: Self.emoteTag) { [weak self] in
                    guard let self else { return }
                    let c = self.body.centroid
                    self.spawn(.heart, at: SIMD2(c.x + (k == 0 ? -0.5 : 0.5), c.y - 1.0), velocity: SIMD2(0, -0.8), life: 1.0, size: 0.18)
                }
            }
            cue(.love, gain: 0.7)
        case .nod:
            flatten.animate(keys: [.init(to: 0.9, duration: 0.16, ease: .inOutSine), .init(to: 1.0, duration: 0.16, ease: .inOutSine),
                                   .init(to: 0.92, duration: 0.16, ease: .inOutSine), .init(to: 1, duration: 0.3, ease: .outBack)], at: time)
            glance = (SIMD2(0, 0.35), time + 0.3)
            cue(.approve, gain: 0.6)
        case .shakeNo:
            if !reduceMotion { shakeKicks([(0, 2.2), (0.1, -3.6), (0.2, 3.0), (0.3, -1.8)]) }
            lean.animate(keys: [.init(to: 0.1, duration: 0.14, ease: .inOutSine), .init(to: -0.1, duration: 0.16, ease: .inOutSine),
                                .init(to: 0.08, duration: 0.16, ease: .inOutSine), .init(to: style.lean, duration: 0.3, ease: .outBack)], at: time)
            cue(.annoyed, gain: 0.5)
        case .thumbsUp:
            cue(.approve)
        case .stretch:
            // A morning stretch: arms up, the body tall, a small "mu" sigh.
            mouthOpen.animate(keys: [.init(to: 0.45, duration: 0.3, ease: .inOutSine), .init(to: 0.45, duration: 0.4, ease: .linear),
                                     .init(to: style.mouthOpen, duration: 0.3, ease: .inOutSine)], at: time)
            flatten.animate(keys: [.init(to: 1.25, duration: 0.45, ease: .outQuad), .init(to: 1.25, duration: 0.35, ease: .linear),
                                   .init(to: 0.96, duration: 0.2, ease: .inOutSine), .init(to: 1, duration: 0.2, ease: .outBack)], at: time)
            cue(.stretch, gain: 0.6)
        case .poked:
            // ツンツン: a side squish away from the finger with "> <" eyes.
            let side: Double = (pointer?.x ?? 1) >= 0 ? 1 : -1
            mouthOpen.animate(to: 0.25, duration: 0.08, at: time)
            lean.animate(keys: [.init(to: -0.12 * side, duration: 0.1, ease: .outQuad), .init(to: style.lean, duration: 0.45, ease: .outBack)], at: time)
            cue(.puni)
        }
    }

    private func startMorph(_ m: MorphKind, duration: Double, ease: Ease) {
        morph = m
        morphAmount.animate(to: 1, duration: duration, ease: ease, at: time)
    }

    private func endEmote() {
        guard let ended = emote else { return }
        emote = nil
        clearGesture(owner: .emote)
        if let m = morph {
            morphAmount.animate(to: 0, duration: 0.35, ease: .inOutSine, at: time)
            // Everything that stops wobbles once; puffed cheeks let go with a bigger one.
            if !reduceMotion { body.apply(.wobble(angle: -.pi / 2, strength: m == .puff ? 0.3 : 0.12)) }
        }
        switch ended {
        case .melt, .shock, .cry, .nod, .stretch:
            flatten.animate(to: userState == .sleeping ? 0.80 : 1, duration: 0.4, ease: .outBack, at: time)
        default:
            break
        }
        scheduler.cancel(tag: Self.emoteTag)
        if let o = eyeOverride, o.until == emoteUntil { eyeOverride = nil }
        if let m = mouthOverride, m.until == emoteUntil { mouthOverride = nil }
        if let g = glance, g.until == emoteUntil { glance = nil }
        let style = currentStyle()
        blush.animate(to: baseBlush, duration: 0.5, at: time)
        if faceSlide.value > 1e-3 || faceSlide.isAnimating { faceSlide.animate(to: 0, duration: 0.4, ease: .inOutSine, at: time) }
        sizeScale.animate(to: userState == .split ? sizeScale.value : 1, duration: 0.3, ease: .outBack, at: time)
        eyeScale.animate(to: style.eyeScale * (isHovering ? 1.06 : 1), duration: 0.3, at: time)
        lean.animate(to: style.lean, duration: 0.3, ease: .outBack, at: time)
        mouthOpen.animate(to: style.mouthOpen, duration: 0.25, at: time)
        for i in accessories.indices where accessories[i].owner == .emote && accessories[i].removeAt == nil {
            accessories[i].removeAt = time
        }
    }

    /// Horizontal velocity kicks (R/s) at offsets from now: shakes read through the soft body,
    /// anchor offsets do not.
    private func shakeKicks(_ kicks: [(Double, Double)]) {
        for (dt, vx) in kicks {
            if dt <= 0 {
                body.apply(.shake(direction: SIMD2(vx, 0)))
            } else {
                scheduler.schedule(at: time + dt, tag: Self.stateTag) { [weak self] in
                    self?.body.apply(.shake(direction: SIMD2(vx, 0)))
                }
            }
        }
    }

    /// A hop with the anime's anticipation: a quick crouch, then the launch; the air stretch
    /// (`substep`) and the landing squash (`landed`) follow. `anticipation: 0` launches at once.
    private func hop(_ v0: Double, anticipation: Double = 0.12) {
        guard !reduceMotion, !body.airborne, hopAt == nil else { return }
        if anticipation <= 0 {
            launchHop(v0)
            return
        }
        flatten.animate(keys: [.init(to: 0.85, duration: anticipation, ease: .outQuad), .init(to: 1, duration: 0.06, ease: .outQuad)], at: time)
        hopAt = (time + anticipation, v0)
    }

    private func launchHop(_ v0: Double) {
        guard !body.airborne else { return }
        body.apply(.jump(v0: v0))
        airStretch = 1 + min(0.20, 0.08 * v0)
        cue(.pyon, rate: clamp(2.4 / v0, 0.8, 1.2), gain: 0.5)
        if appearance.look.wings != .none { cue(.fuwa, gain: 0.5) }
    }

    // MARK: - State machine

    private func setUserState(_ u: UserState) {
        userState = u
        refreshState()
    }

    private func mapped(_ a: AgentState) -> SlimeState {
        switch a {
        case .idle: return .idle
        case .thinking: return .thinking
        case .working: return .working
        case .waiting: return .waiting
        case .finished: return .finished
        case .error: return .error
        }
    }

    private func mapped(_ u: UserState) -> SlimeState? {
        switch u {
        case .none: return nil
        case .greeting: return .greeting
        case .listening: return .listening
        case .recording: return .recording
        case .chewing: return .chewing
        case .question: return .question
        case .dizzy: return .dizzy
        case .split: return .split
        case .sleeping: return .sleeping
        }
    }

    private func refreshState() {
        let a = mapped(agentState)
        let target: SlimeState
        if let u = mapped(userState), u.priority >= a.priority {
            target = u
        } else {
            target = a
        }
        if target != state { transition(to: target) }
    }

    private func transition(to new: SlimeState) {
        exitState(state)
        state = new
        stateEnteredAt = time
        lastInteractionAt = time
        enterState(new)
        onEvent?(.stateChanged(new))
    }

    private func exitState(_ s: SlimeState) {
        scheduler.cancel(tag: Self.stateTag)
        for i in accessories.indices where accessories[i].owner == .state && accessories[i].removeAt == nil {
            accessories[i].removeAt = time
        }
        pulse = 0
        if s == .chewing {
            mouthOpen.animate(to: 0, duration: 0.2, at: time)
            chewPhase = nil
            digestStartedAt = nil
            filingAt = nil
            bites = 0
            if let o = eyeOverride, o.until > time + 1e8 { eyeOverride = nil }
        }
        clearGesture(owner: .state)
        if s == .sleeping {
            flatten.animate(to: 1, duration: 0.5, ease: .outBack, at: time)
        }
    }

    private func enterState(_ s: SlimeState) {
        let style = currentStyle(s)
        breath.amplitude.animate(to: style.breathAmplitude, duration: 0.8, at: time)
        breath.rate.animate(to: style.breathRate, duration: 0.8, at: time)
        blink.interval = style.blinkInterval
        blink.suppressed = style.blinkSuppressed
        baseEye = style.eye
        baseMouth = style.mouth
        mouthOpen.animate(to: style.mouthOpen, duration: 0.25, at: time)
        eyeScale.animate(to: style.eyeScale * (isHovering ? 1.06 : 1), duration: 0.28, ease: .outBack, at: time)
        lean.animate(to: style.lean, duration: 0.3, ease: .outBack, at: time)
        gazeOverride = style.gazeOverride
        gazeBlend = style.gazeBlend
        tintTarget = style.tint
        if style.clearsEmote { endEmote() }
        if let a = style.accessory { addAccessory(a, owner: .state) }
        if let c = style.entrySound { cue(c.sound, rate: c.rate, gain: c.gain) }
        if let d = s.duration {
            scheduler.schedule(at: time + d, tag: Self.stateTag) { [weak self] in self?.expire(s) }
        }
        switch s {
        case .idle:
            scheduleMicroIdle()
        case .greeting:
            if reduceMotion {
                scheduleGreetingFace(delay: 0.1)
            } else {
                body.drop(fromHeight: 1.6, initialSpeed: 2.0)
                scheduleGreetingFace(delay: 0.55)
            }
        case .listening:
            micLevels = Array(repeating: 0, count: 5)
        case .thinking:
            scheduleHmm()
        case .working:
            scheduleDart()
        case .waiting:
            scheduleHop()
        case .question:
            scheduler.schedule(at: time + 0.3, tag: Self.stateTag) { [weak self] in
                guard let self else { return }
                self.blink.blinkNow(at: self.time, rng: &self.rng)
            }
        case .chewing:
            chewSide = 1
            chewStartedAt = time
            ingestResult = nil
            bites = 0
            chewHostDriven = false
            hostProgress = 0
            digestStartedAt = nil
            filingAt = nil
            chewProp = .file(kind: chewKind, bites: 0)
            chewHug = false
            if appearance.armsEnabled, profile.kind == .main {
                chewPhase = .catching
                scheduler.schedule(at: time + 0.25, tag: Self.stateTag) { [weak self] in
                    guard let self else { return }
                    if !self.reduceMotion { self.body.apply(.landing(speed: 0.9)) }
                    self.glance = (SIMD2(0, -0.7), self.time + 0.45)
                    self.mouthOverride = (.o, self.time + 0.45)
                    self.cue(.rustle)
                }
                // A beat of hugging the catch (the mask-hug from the references), then eating.
                scheduler.schedule(at: time + 0.65, tag: Self.stateTag) { [weak self] in
                    guard let self else { return }
                    self.chewHug = true
                    self.eyeOverride = (.pleased, .pleased, self.time + 0.55)
                    self.mouthOverride = (.smileTiny, self.time + 0.55)
                    self.blush.animate(to: max(self.baseBlush, 0.5), duration: 0.2, at: self.time)
                    self.cue(.kyu, gain: 0.5)
                }
                scheduler.schedule(at: time + 1.2, tag: Self.stateTag) { [weak self] in
                    guard let self else { return }
                    self.chewHug = false
                    self.blush.animate(to: self.baseBlush, duration: 0.4, at: self.time)
                    self.chewPhase = .biting(0)
                    self.scheduleBite()
                }
            } else {
                chewPhase = nil
                scheduleBite()
            }
        case .finished:
            hop(2.6)
            blush.animate(to: max(baseBlush, 0.6), duration: 0.2, at: time)
            scheduler.schedule(at: time + 0.40, tag: Self.stateTag) { [weak self] in self?.spawnSparkles(count: 5) }
            scheduler.schedule(at: time + 1.9, tag: Self.stateTag) { [weak self] in
                guard let self else { return }
                self.blush.animate(to: self.baseBlush, duration: 0.4, at: self.time)
            }
        case .error:
            if !reduceMotion { shakeKicks([(0, 2.6), (0.06, -4.4), (0.13, 3.2), (0.2, -1.6)]) }
            trigger(.shock)
            scheduleSweat()
            scheduler.schedule(at: time + 1.1, tag: Self.stateTag) { [weak self] in self?.gesture(.facepalm, for: 1.3, owner: .state) }
            scheduler.schedule(at: time + 10, tag: Self.stateTag) { [weak self] in
                guard let self, self.state == .error else { return }
                self.trigger(.cry)
            }
        case .sleeping:
            flatten.animate(to: 0.80, duration: 0.9, ease: .inOutSine, at: time)
            scheduler.schedule(at: time + 0.9, tag: Self.stateTag) { [weak self] in self?.baseEye = .closedLine }
            scheduleZzz()
        case .dizzy:
            scheduler.schedule(at: time + 1.3, tag: Self.stateTag) { [weak self] in
                guard let self, !self.reduceMotion else { return }
                self.shakeKicks([(0, 1.6), (0.06, -2.6), (0.12, 1.4)])
            }
        case .recording:
            scheduleRecGlance()
        case .split:
            flatten.animate(keys: [.init(to: 0.55, duration: 0.06, ease: .outQuad), .init(to: 1, duration: 0.3, ease: .outBack)], at: time)
            sizeScale.animate(to: 0.5, duration: 0.12, ease: .outCubic, at: time)
        }
        if profile.kind == .mini, s != .sleeping {
            scheduleWander()
        }
    }

    private func expire(_ s: SlimeState) {
        guard state == s else { return }
        switch s {
        case .greeting, .question, .dizzy, .split:
            if mapped(userState) == s { userState = .none }
        case .finished:
            if agentState == .finished { agentState = .idle }
        default:
            break
        }
        refreshState()
    }

    // MARK: - State loops

    private func scheduleMicroIdle() {
        let dt = rng.range(8...15)
        scheduler.schedule(at: time + dt, tag: Self.stateTag) { [weak self] in
            guard let self else { return }
            self.microIdle()
            self.scheduleMicroIdle()
        }
    }

    private func microIdle() {
        guard state == .idle, !isPressed else { return }
        if time - lastInteractionAt > 90, detail >= .medium, occasion == nil, rng.chance(0.35) {
            gesture(.sip, for: 3.0, owner: .state)
            scheduler.schedule(at: time + 1.1, tag: Self.stateTag) { [weak self] in self?.cue(.sip, gain: 0.5) }
            return
        }
        // A random jiggle, a weight shift, a glance or a half-lid; nothing moves linearly.
        let r = rng.unit()
        if r < 0.45 {
            if !reduceMotion { body.apply(.wobble(angle: rng.range(-2.6...(-0.5)), strength: 0.18)) }
        } else if r < 0.75 {
            let base = currentStyle().lean
            let shift = rng.sign() * 0.07
            lean.animate(keys: [.init(to: base + shift, duration: 1.0, ease: .inOutSine), .init(to: base + shift, duration: 0.6, ease: .linear),
                                .init(to: base, duration: 1.0, ease: .inOutSine)], at: time)
        } else if r < 0.90 {
            glance = (SIMD2(rng.sign() * rng.range(0.3...0.5), rng.range(-0.1...0.25)), time + rng.range(0.6...1.0))
        } else {
            eyeOverride = (.half, .half, time + 0.35)
        }
    }

    private func scheduleWander() {
        scheduler.schedule(at: time + rng.range(1.5...3.5), tag: Self.stateTag) { [weak self] in
            guard let self else { return }
            if self.pointer == nil || self.rng.chance(0.6) {
                self.glance = (SIMD2(self.rng.range(-0.45...0.45), self.rng.range(-0.2...0.3)), self.time + self.rng.range(1.0...2.0))
            }
            self.scheduleWander()
        }
    }

    private func scheduleHmm() {
        scheduler.schedule(at: time + rng.range(2.4...4.0), tag: Self.stateTag) { [weak self] in
            guard let self else { return }
            let s = self.rng.sign()
            self.lean.animate(keys: [.init(to: 0.08 * s, duration: 0.3, ease: .outBack), .init(to: 0, duration: 0.5, ease: .inOutSine)], at: self.time)
            self.hmmCount += 1
            if self.hmmCount % 2 == 0 { self.gesture(.scratchHead, for: 1.1, owner: .state) }
            self.scheduleHmm()
        }
    }

    private func scheduleDart() {
        scheduler.schedule(at: time + rng.range(1.2...2.6), tag: Self.stateTag) { [weak self] in
            guard let self else { return }
            self.glance = (SIMD2(self.rng.range(-0.5...0.5), self.rng.range(-0.3...0.3)), self.time + 0.45)
            self.scheduleDart()
        }
    }

    private func scheduleHop() {
        scheduler.schedule(at: time + rng.range(1.3...1.9), tag: Self.stateTag) { [weak self] in
            guard let self else { return }
            self.hop(1.4)
            self.scheduleHop()
        }
    }

    private func scheduleBite() {
        scheduler.schedule(at: time + 0.45, tag: Self.stateTag) { [weak self] in
            guard let self else { return }
            if !self.reduceMotion { self.body.apply(.bite(side: self.chewSide, strength: 1.0)) }
            self.mouthOpen.animate(keys: [.init(to: 0.15, duration: 0.12, ease: .outQuad), .init(to: 1, duration: 0.25, ease: .outBack)], at: self.time)
            let left: EyeShape = self.chewSide > 0 ? .squint : .open
            let right: EyeShape = self.chewSide > 0 ? .open : .squint
            self.eyeOverride = (left, right, self.time + 0.4)
            self.cue(.hamu, rate: self.chewSide > 0 ? 1 : 1.06)
            self.chewSide = -self.chewSide
            if case .biting = self.chewPhase {
                // Each bite takes 15 % of the file; the host's progress can hold the bites back.
                let cap = self.chewHostDriven ? min(0.6, self.hostProgress * 0.6 + 0.12) : 0.6
                if self.bites < cap { self.bites = min(cap, self.bites + 0.15) }
                self.chewPhase = .biting(self.bites)
                self.chewProp = .file(kind: self.chewKind, bites: self.bites)
                self.spawnCrumbs()
                // Swallow at 60 % eaten, or after two bites once the host is already analysing.
                let enough = self.chewHostDriven && self.hostProgress >= 0.6 ? 0.3 : 0.6
                if self.bites >= enough - 1e-9, !self.chewHostDriven || self.hostProgress >= 0.6 {
                    self.startDigesting()
                    return
                }
            }
            self.scheduleBite()
        }
    }

    private func scheduleSweat() {
        scheduler.schedule(at: time + 2.5, tag: Self.stateTag) { [weak self] in
            guard let self else { return }
            self.spawnSweat()
            self.scheduleSweat()
        }
    }

    private func scheduleZzz() {
        scheduler.schedule(at: time + 1.6, tag: Self.stateTag) { [weak self] in
            guard let self else { return }
            let c = self.body.centroid
            self.spawn(.zzz, at: SIMD2(c.x + 0.75, c.y - 0.95), velocity: SIMD2(0.32, -0.55), life: 1.7, size: 0.22)
            self.scheduleZzz()
        }
    }

    private func scheduleRecGlance() {
        scheduler.schedule(at: time + rng.range(5...9), tag: Self.stateTag) { [weak self] in
            guard let self else { return }
            self.glance = (SIMD2(0.6, 0.3), self.time + 0.5)
            self.scheduleRecGlance()
        }
    }

    private func scheduleGreetingFace(delay: Double) {
        scheduler.schedule(at: time + delay, tag: Self.stateTag) { [weak self] in
            guard let self else { return }
            let until = self.time + 1.3
            self.eyeOverride = (.happyArc, .happyArc, until)
            self.mouthOverride = (.omega, until)
            self.blush.animate(to: max(self.baseBlush, 0.55), duration: 0.25, at: self.time)
            if !self.reduceMotion {
                self.lean.animate(keys: [.init(to: 0.10, duration: 0.125, ease: .inOutSine), .init(to: -0.10, duration: 0.125, ease: .inOutSine),
                                         .init(to: 0.10, duration: 0.125, ease: .inOutSine), .init(to: 0, duration: 0.125, ease: .inOutSine)], at: self.time)
            }
            self.cue(.greet)
            self.gesture(.wave(side: 1), for: 1.3, owner: .state)
            self.scheduler.schedule(at: until, tag: Self.stateTag) { [weak self] in
                guard let self else { return }
                self.blush.animate(to: self.baseBlush, duration: 0.4, at: self.time)
            }
        }
    }

    // MARK: - Particles & accessories

    private func spawn(_ kind: Particle.Kind, at position: SIMD2<Double>, velocity: SIMD2<Double>, life: Double, size: Double) {
        guard particles.count < 40 else { return }
        particles.append(Particle(kind: kind, position: position, velocity: velocity, age: 0, life: life, size: size,
                                  spin: rng.range(-2...2), seed: rng.unit()))
    }

    private func spawnSparkles(count: Int) {
        let c = body.centroid
        for k in 0..<count {
            let a = -2.7 + Double(k) * (2.1 / Double(max(1, count - 1)))
            let dir = SIMD2(cos(a), sin(a))
            spawn(.sparkle, at: c + dir * rng.range(1.25...1.55), velocity: dir * 0.45, life: rng.range(0.5...0.7), size: rng.range(0.12...0.2))
        }
    }

    /// One sweat drop at a time: it rides the upper cheek on `side`, slides down and fades
    /// (0.62 s plus the removal fade).
    private func spawnSweat(side: Double = 1, owner: AccessoryInstance.Owner = .state) {
        if let i = accessories.firstIndex(where: { $0.kind == .sweat }) {
            if accessories[i].removeAt == nil { return }
            accessories.remove(at: i)
        }
        accessories.append(AccessoryInstance(kind: .sweat, startedAt: time, removeAt: nil, owner: owner, side: side))
    }

    private func stepParticles() {
        guard !particles.isEmpty else { return }
        for i in particles.indices {
            var p = particles[i]
            let g: Double
            switch p.kind {
            case .drop: g = 5
            case .star: g = 0.6
            case .dust: g = 1.2
            case .heart: g = -0.15
            case .zzz: g = -0.05
            case .sparkle: g = 0
            case .wisp: g = -0.5
            case .spark, .glint: g = 0
            case .drip: g = 2.5
            case .bubble: g = -0.08
            case .crumb: g = 4.5
            case .steam: g = -0.6
            }
            p.velocity.y += g * h
            p.position += p.velocity * h
            p.age += h
            particles[i] = p
        }
        particles.removeAll { $0.age >= $0.life }
    }

    private func addAccessory(_ kind: AccessoryKind, owner: AccessoryInstance.Owner) {
        if let i = accessories.firstIndex(where: { $0.kind == kind }) {
            if accessories[i].removeAt != nil {
                accessories[i].removeAt = nil
                accessories[i].startedAt = time
            }
            accessories[i].owner = owner
            return
        }
        accessories.append(AccessoryInstance(kind: kind, startedAt: time, removeAt: nil, owner: owner))
    }

    // MARK: - Sounds

    public func cue(_ sound: SlimeSound, rate: Double = 1, gain: Double = 1) {
        if let last = lastCueAt[sound], time - last < sound.minInterval { return }
        lastCueAt[sound] = time
        cues.append(SoundCue(sound, rate: rate, gain: gain * sound.baseGain))
    }

    public func drainCues() -> [SoundCue] {
        let out = cues
        cues.removeAll()
        return out
    }

    // MARK: - Frame

    private func resolvedEye(_ side: Double) -> EyeShape {
        let shape: EyeShape
        if isAway { shape = .closedLine } else if let o = eyeOverride { shape = side < 0 ? o.left : o.right } else { shape = baseEye }
        return faceStyle == .anime ? shape.strokeEquivalent : shape
    }

    private func frameNow() -> SlimeFrame {
        frame(alpha: 1)
    }

    public func frame() -> SlimeFrame {
        frame(alpha: alpha)
    }

    private func frame(alpha: Double) -> SlimeFrame {
        let ring = body.interpolated(alpha: alpha)
        let bf = BodyFrame.fit(reference: body.referenceRing, referenceCentroid: body.referenceCentroid, current: ring)
        let limbs = armFrames(ring: ring, bf: bf)
        let holdsMic = limbs.props.contains { $0.prop == .mic }
        let s = profile.kind == .mini ? 0.85 : 1.0
        var acc: [AccessoryFrame] = []
        var extraBlobs: [Blob] = []
        var ringCentroid = SIMD2<Double>.zero
        for p in ring { ringCentroid += p }
        ringCentroid /= Double(max(1, ring.count))
        accessories.removeAll { r in r.removeAt.map { time - $0 > 0.18 } ?? false }
        let grownStyle = appearance.glyphStyle == .grown && detail >= .medium
        for a in accessories where !(a.kind == .micBars && holdsMic) {
            let age = time - a.startedAt
            var pop = Ease.outBack.apply(min(1, age / 0.28))
            if let r = a.removeAt { pop = max(0, 1 - (time - r) / 0.18) * min(pop, 1) }
            let grown = grownStyle && a.kind.canGrow
            var anchor: SIMD2<Double>
            var dir = SIMD2<Double>(0, -1)
            var bead: SIMD2<Double>? = nil
            var beadR = 0.0
            if grown {
                // The anime's "!" moment: the mark floats clear of the head, a little right of the
                // crown and nearly upright, with one small bead sitting on the head under it. No
                // stalk and no trail; it pops out of the head and settles with a clear gap.
                let n = ring.count
                var c = SIMD2<Double>.zero
                for p in ring { c += p }
                c /= Double(n)
                let base = ring[TraitRig.index(angle: -.pi / 2 + 0.45, count: n)]
                let normal = TraitRig.unit(base - c)
                // Mostly up with a slight outward lean; only the tip lag moves it, so the contour
                // cache holds while the slime is still.
                dir = TraitRig.rotate(TraitRig.unit(normal * 0.45 + SIMD2(0, -1)), by: traitAnim.tipLag * 0.35)
                let grow = max(0, pop)
                anchor = base + dir * (0.2 * s + 0.52 * s * grow)
                bead = base + dir * (0.1 * s)
                beadR = 0.085 * s * min(1, grow)
            } else if a.kind == .sweat {
                // The drop sits on the upper cheek and slides down the surface over its life.
                let slide = Ease.outQuad.apply(min(1, age / 0.8))
                let theta = -Double.pi / 2 + a.side * (0.75 + 0.30 * slide)
                anchor = TraitRig.point(angle: theta, ring: ring)
                dir = TraitRig.unit(anchor - ringCentroid)
            } else {
                let local: SIMD2<Double>
                switch a.kind {
                // In the compact notch (tiny detail) there is no room above the head: bubbles sit beside it.
                case .question, .exclamation, .dots, .note: local = detail == .tiny ? SIMD2(1.45, -1.55) : SIMD2(1.15, -2.05)
                case .badge: local = SIMD2(0.95, -1.9)
                case .micBars: local = SIMD2(1.75, -1.0)
                case .recDot: local = SIMD2(1.25, -1.8)
                case .anger: local = SIMD2(0.72, -1.46)
                case .sweat: local = SIMD2(0.72, -1.38)
                }
                anchor = bf.transform(local)
            }
            acc.append(AccessoryFrame(kind: a.kind, anchor: anchor, pop: pop, phase: age, levels: a.kind == .micBars ? micLevels : [],
                                      grown: grown, direction: dir, bead: bead, beadRadius: beadR))
        }
        if let m = morph {
            let k = morphAmount.value
            if k > 1e-3 {
                let bs = (bf.scaleX * bf.scaleY).squareRoot()
                func bulge(_ local: SIMD2<Double>, _ r: Double, _ stretch: Double) {
                    extraBlobs.append(Blob(position: bf.transform(local), radius: r * bs * s, stretch: stretch, heading: 0, shaded: false))
                }
                switch m {
                case .melt: for side in [-1.0, 1.0] { bulge(SIMD2(side * (0.6 + 0.22 * k), -0.2), 0.32 * k, 1.8) }
                case .puff: for side in [-1.0, 1.0] { bulge(SIMD2(side * 0.8, -0.98), 0.4 * k, 1.1) }
                case .heartBody: for side in [-1.0, 1.0] { bulge(SIMD2(side * 0.52, -1.72), 0.4 * k, 1.0) }
                }
            }
        }
        // Strain creases: short inward ticks just inside the outline where the body is squeezed.
        var creases: [CreaseFrame] = []
        func addCreases(angle: Double, amount: Double, ticks: [Double]) {
            guard amount > 0.02 else { return }
            for k in ticks {
                let p = TraitRig.point(angle: angle + 0.28 * k, ring: ring)
                let inward = TraitRig.unit(ringCentroid - p)
                creases.append(CreaseFrame(anchor: p + inward * (0.05 * s), direction: inward, length: 0.18 * s * amount, alpha: amount))
            }
        }
        if strainAmount.value > 0.02 { addCreases(angle: strainAngle, amount: strainAmount.value, ticks: [-1, 0, 1]) }
        if let m = morph {
            let k = morphAmount.value
            switch m {
            case .puff:
                addCreases(angle: 0, amount: k, ticks: [-0.6, 0.6])
                addCreases(angle: .pi, amount: k, ticks: [-0.6, 0.6])
            case .melt:
                addCreases(angle: .pi / 2 - 0.7, amount: k, ticks: [-0.6, 0.6])
                addCreases(angle: .pi / 2 + 0.7, amount: k, ticks: [-0.6, 0.6])
            case .heartBody: break
            }
        }
        let look = appearance.look
        var rig = TraitRig.build(look: look, ring: ring, anim: traitAnim, time: time, detail: detail, mini: profile.kind == .mini)
        let worn = resolvedOutfit
        rig.traits += OutfitRig.build(outfit: worn, ring: ring, anim: traitAnim, detail: detail, mini: profile.kind == .mini)
        let yaw = gaze.yaw
        let pitch = gaze.pitch
        let open = blink.openness
        let es = eyeScale.value * (state == .listening ? 1 + 0.06 * audioLevel : 1)
        // Melting slides the whole face down the sphere (and foreshortens it).
        let slide = faceSlide.value / max(eyeRig.sphereRadius, 1e-6)
        var eyes: [EyeFrame] = []
        for side in [-1.0, 1.0] {
            let proj = eyeRig.project(yawOffset: side * eyeRig.separation, pitchOffset: eyeRig.basePitch - slide, yaw: yaw, pitch: pitch)
            let world = bf.transform(eyeRig.local(proj))
            eyes.append(EyeFrame(side: side, shape: resolvedEye(side), center: world, radius: eyeRig.eyeRadius,
                                 aspect: eyeRig.eyeAspect, foreshorten: proj.foreshorten,
                                 openness: side < 0 ? open.x : open.y, visible: proj.visible, scale: es))
        }
        let mp = eyeRig.project(yawOffset: 0, pitchOffset: eyeRig.mouthPitch - slide, yaw: yaw, pitch: pitch)
        let mouth = MouthFrame(shape: mouthOverride?.shape ?? baseMouth, open: mouthOpen.value,
                               center: bf.transform(eyeRig.local(mp)), foreshorten: mp.foreshorten, visible: mp.visible)
        var blushCenters: [SIMD2<Double>] = []
        var blushFore: [SIMD2<Double>] = []
        if profile.blushEnabled || faceStyle == .anime {
            for side in [-1.0, 1.0] {
                let bp = eyeRig.project(yawOffset: side * eyeRig.blushYaw, pitchOffset: eyeRig.blushPitch - slide, yaw: yaw, pitch: pitch)
                if bp.visible {
                    blushCenters.append(bf.transform(eyeRig.local(bp)))
                    blushFore.append(bp.foreshorten)
                }
            }
        }
        let moving = body.airborne || flatten.isAnimating || sizeScale.isAnimating || shakeX.isAnimating || !particles.isEmpty || morph != nil
            || strainAmount.isAnimating || faceSlide.isAnimating || accessories.contains(where: { $0.kind == .sweat })
            || blobs.contains(where: { $0.radius > 1e-3 }) || isPressed || state == .split || state == .chewing || state == .dizzy || state == .greeting
            || armRig.isAnimating(at: time) || armRig.hasMotion || (propLive && simd_length(propSpring.velocity) > 1e-3) || !limbs.inner.isEmpty
        // A resting pointer is not activity: the gaze counts only while it is still turning.
        let gazeMoving = abs(gaze.yaw - gaze.target.x) > 0.003 || abs(gaze.pitch - gaze.target.y) > 0.003
        let lively = blink.isBlinking || lean.isAnimating || opacityAnim.isAnimating || faceOpacityAnim.isAnimating || eyeScale.isAnimating || blush.isAnimating || mouthOpen.isAnimating
            || glance != nil || eyeOverride != nil || emote != nil || !acc.isEmpty || !state.isQuiet || gazeMoving || !limbs.arms.isEmpty
        activity = moving ? 2 : (lively ? 1 : 0)
        var out = SlimeFrame(
            profile: profile.kind, state: state, emote: emote, ring: ring, root: body.root, body: bf,
            contactWidth: body.contactWidth, airborne: body.airborne, eyes: eyes, mouth: mouth,
            blush: blush.value, blushCenters: blushCenters, blushForeshorten: blushFore,
            core: coreSpring.value, coreBoost: coreBoost, gaze: SIMD2(yaw, pitch),
            highlightShift: SIMD2(-0.08 * yaw, 0.06 * pitch), tint: tint, accessories: acc, particles: particles,
            blobs: blobs + rig.blobs + limbs.blobs + extraBlobs, opacity: opacity, faceOpacity: faceOpacity, glowBoost: glowBoost, sizeScale: sizeScale.value,
            ghostStretch: ghostStretch, ghostHeading: ghostHeading, traits: rig.traits, outfit: worn, time: time,
            arms: limbs.arms, props: limbs.props, innerItems: limbs.inner, chewPhase: chewPhase)
        out.creases = creases
        out.coreScale = coreScaleSpring.value
        return out
    }

    // MARK: - Looks

    /// Reshapes the body for the look's silhouette and feel and refits the face to it.
    private func applyLook() {
        let mini = profile.kind == .mini
        let want = profile.body.applying(look: appearance.look, mini: mini)
        if want.silhouette != body.params.silhouette || want.pointCount != body.params.pointCount {
            var b = SoftBody(params: want)
            b.floorEnabled = profile.floorEnabled
            b.teleport(root: body.root)
            b.lean = body.lean
            b.squash = body.squash
            b.sizeScale = body.sizeScale
            b.gravityScale = body.gravityScale
            body = b
            coreSpring = Spring2D(value: b.centroid, omega: 10, zeta: 0.35)
        } else if want != body.params {
            body.setParams(want)
        }
        eyeRig = baseEyeRig.fitted(to: RestProfile.forSilhouette(appearance.look.silhouette, mini: mini))
    }

    // MARK: - Face style

    var faceStyle: FaceStyle { appearance.faceStyle }

    /// The eye rig of the face style before fitting to the silhouette.
    private var baseEyeRig: EyeRig { FaceTable.rig(kind: profile.kind, face: faceStyle, fallback: profile.eyeRig) }

    /// The style of a state in the current face.
    private func currentStyle(_ s: SlimeState? = nil) -> StateStyle { StateStyle.style(for: s ?? state, face: faceStyle) }

    /// Swaps the rig, the gaze range, the blink timing and the resting blush for the face
    /// style, and re-resolves the state's eyes and mouth. The anime face is painted on the
    /// surface: its eyes slide only a little with the pointer and blink as a quick flatten.
    private func applyFaceStyle() {
        let mini = profile.kind == .mini
        eyeRig = baseEyeRig.fitted(to: RestProfile.forSilhouette(appearance.look.silhouette, mini: mini))
        switch faceStyle {
        case .anime:
            gaze.yawGain = 0.10
            gaze.pitchGain = 0.08
            blink.closeDuration = 0.05
            blink.holdDuration = 0.015
            blink.openDuration = 0.07
        case .round:
            gaze.yawGain = 0.62
            gaze.pitchGain = 0.50
            blink.closeDuration = 0.07
            blink.holdDuration = 0.02
            blink.openDuration = 0.13
        }
        baseBlush = FaceTable.baseBlush(kind: profile.kind, face: faceStyle, blushEnabled: profile.blushEnabled)
        if blush.isAnimating { blush.animate(to: baseBlush, duration: 0.3, at: time) } else { blush = AnimatedValue(baseBlush) }
        let style = currentStyle()
        baseEye = style.eye
        baseMouth = style.mouth
    }

    /// Ear twitches, tail wag, wing flap, antenna lag and surface particles.
    private func tickTraits() {
        let look = appearance.look
        let rich = detail >= .medium
        let vx = haveCentroid ? (body.centroid.x - prevCentroidX) / h : 0
        let vy = haveCentroid ? (body.centroid.y - prevCentroidY) / h : 0
        let landed = wasAirborne && !body.airborne
        wasAirborne = body.airborne
        prevCentroidX = body.centroid.x
        prevCentroidY = body.centroid.y
        haveCentroid = true
        if !resolvedOutfit.isEmpty {
            // Breathing moves the centroid a hair; only real motion drags the hat, so idle settles to zero.
            let dx = abs(vx) < 0.25 ? 0 : vx
            let dy = abs(vy) < 0.25 ? 0 : vy
            hatSpring.target = SIMD2(clamp(-dx * 0.05, -0.08, 0.08), clamp(-dy * 0.04, -0.08, 0.08))
            if landed { hatSpring.velocity.y -= 1.6 }
            hatSpring.advance(h)
            // The hat never leaves the crown by more than 0.08 R, whichever way it swings.
            let hatLen = simd_length(hatSpring.value)
            if hatLen > 0.08 { hatSpring.value *= 0.08 / hatLen }
            if simd_length(hatSpring.value - hatSpring.target) < 1e-3, simd_length(hatSpring.velocity) < 1e-3 { hatSpring.value = hatSpring.target; hatSpring.velocity = .zero }
            traitAnim.hat = hatSpring.value
        } else {
            traitAnim.hat = .zero
        }
        guard !look.isPlain else { return }
        if look.ears == .cat || look.ears == .fox {
            earSpring.target = clamp(-vy * 0.05, -0.5, 0.5)
            if landed { earSpring.velocity += 5 }
            earSpring.advance(h)
            Self.settle(&earSpring)
            traitAnim.earFlop = earSpring.value
            if let t = earTwitch {
                let u = (time - t.at) / 0.28
                let a = u < 1 ? 0.45 * sin(.pi * u) : 0
                traitAnim.earTwitch = t.side < 0 ? SIMD2(a, 0) : SIMD2(0, a)
                if u >= 1 { earTwitch = nil; traitAnim.earTwitch = .zero }
            } else if rich, time >= nextEarTwitch, state != .sleeping {
                earTwitch = (rng.unit() < 0.5 ? -1 : 1, time)
                nextEarTwitch = time + rng.range(4...11)
            }
        }
        if look.tail != .none {
            let lively = emote != nil || state == .greeting || state == .finished || isHolding
            let rate = lively ? 3.2 : (rich ? 0.9 : 0)
            tailAmp = approach(tailAmp, toward: lively ? 0.5 : 0.18, tau: 0.3, dt: h)
            tailPhase += 2 * .pi * rate * h
            tailSpring.target = clamp(-vx * 0.22, -0.9, 0.9)
            if landed { tailSpring.velocity += 6 }
            tailSpring.advance(h)
            Self.settle(&tailSpring)
            traitAnim.tailWag = tailAmp * sin(tailPhase) + tailSpring.value
        }
        if look.tip {
            tipSpring.target = clamp(-vx * 0.18, -0.8, 0.8)
            if landed { tipSpring.velocity += 7 }
            tipSpring.advance(h)
            Self.settle(&tipSpring)
            traitAnim.tipLag = tipSpring.value
        }
        if look.wings != .none {
            let flap = body.airborne ? 0.55 * sin(2 * .pi * 5 * time) : 0
            let idle = rich ? (look.feel == .airy ? 0.22 * sin(2 * .pi * 2.2 * time) : 0.1 * sin(2 * .pi * 0.7 * time)) : 0
            wingSpring.target = flap + idle
            wingSpring.advance(h)
            traitAnim.wingFlap = wingSpring.value
        }
        if look.antenna {
            antennaSpring.target = clamp(-vx * 0.12, -0.7, 0.7) + (rich ? 0.06 * sin(2 * .pi * 0.6 * time) : 0)
            antennaSpring.advance(h)
            traitAnim.antenna = antennaSpring.value
        }
        if rich, look.surface != .plain, time >= nextSurfaceEmit, state != .sleeping, !reduceMotion {
            emitSurfaceParticle(look.surface)
            nextSurfaceEmit = time + rng.range(0.5...0.9)
        }
    }

    /// Snaps a spring to rest once it is still, so an idle frame compares equal and is not redrawn.
    private static func settle(_ s: inout Spring1D) {
        if abs(s.value - s.target) < 1e-3, abs(s.velocity) < 1e-3 { s.value = s.target; s.velocity = 0 }
    }

    private func emitSurfaceParticle(_ surface: SlimeLook.Surface) {
        let n = body.count
        let c = body.centroid
        func ringPoint(_ angle: Double) -> (SIMD2<Double>, SIMD2<Double>) {
            let p = body.points[TraitRig.index(angle: angle, count: n)]
            return (p, TraitRig.unit(p - c))
        }
        switch surface {
        case .plain:
            break
        case .fire:
            let (p, _) = ringPoint(-.pi / 2 + rng.range(-0.5...0.5))
            spawn(.wisp, at: p + SIMD2(0, -0.1), velocity: SIMD2(rng.range(-0.15...0.15), -0.55), life: rng.range(0.6...0.9), size: rng.range(0.14...0.22))
        case .electric:
            let (p, nrm) = ringPoint(rng.range(-2.6...0.4))
            spawn(.spark, at: p + nrm * 0.04, velocity: nrm * 0.3, life: 0.22, size: rng.range(0.14...0.22))
        case .crystal, .galaxy:
            let off = SIMD2(rng.range(-0.55...0.55), rng.range(-0.55...0.35))
            spawn(.glint, at: c + off, velocity: .zero, life: rng.range(0.7...1.0), size: rng.range(0.08...0.14))
        case .honey:
            let side = rng.unit() < 0.5 ? -1.0 : 1.0
            let (p, _) = ringPoint(.pi / 2 - side * 0.75)
            spawn(.drip, at: p + SIMD2(0, 0.02), velocity: SIMD2(0, 0.05), life: rng.range(1.4...2.0), size: rng.range(0.1...0.15))
        case .bubble:
            let off = SIMD2(rng.range(-0.45...0.45), rng.range(-0.3...0.4))
            spawn(.bubble, at: c + off, velocity: SIMD2(rng.range(-0.05...0.05), -0.2), life: rng.range(1.2...1.8), size: rng.range(0.05...0.11))
        case .ghost:
            let side = rng.unit() < 0.5 ? -1.0 : 1.0
            let (p, _) = ringPoint(.pi / 2 - side * 0.9)
            spawn(.dust, at: p + SIMD2(0, -0.05), velocity: SIMD2(side * 0.08, -0.14), life: 1.2, size: 0.12)
        }
    }
}
