import Foundation
import simd

/// One slime: physics, face, states, emotes and the click grammar, all on engine time.
/// The host feeds pointer/press/audio input and reads `frame()` once per drawn frame.
@MainActor
public final class SlimeEngine {
    public let profile: SlimeProfile
    /// Species, colour and clothes. Set by the stage; the renderer reads it next to the frame.
    public var appearance: SlimeAppearance = .rimuru
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
    private var shakeX = AnimatedValue(0)
    private var shakeY = AnimatedValue(0)
    private var pulse: Double = 0
    private var coreSpring: Spring2D
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
    }

    private static let stateTag = "state"
    private static let emoteTag = "emote"

    public init(profile: SlimeProfile = .main, seed: UInt64 = 1) {
        self.profile = profile
        var b = SoftBody(params: profile.body)
        b.floorEnabled = profile.floorEnabled
        body = b
        eyeRig = profile.eyeRig
        rng = SeededRandom(seed: seed)
        clock = SlimeClock(step: SoftBodyParams.substep)
        breath = BreathOscillator(seed: seed, phase: Double(seed % 7) * 0.9)
        coreSpring = Spring2D(value: b.centroid, omega: 18, zeta: 0.5)
        baseBlush = profile.blushEnabled ? 0.35 : 0
        blush = AnimatedValue(baseBlush)
        blink.prime(at: 0, rng: &rng)
        enterState(.idle)
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
        body.squash = flatten.value * breath.value * (1 + pulse)
        body.lean = lean.value
        body.offset = SIMD2(shakeX.value, shakeY.value)
        body.sizeScale = sizeScale.value
        let events = body.step(h: h)
        for e in events {
            if case .landed(let speed) = e { landed(speed: speed) }
        }
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
        }
        if speed > 3, !reduceMotion {
            pendingDust = (speed, time + 0.3)
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
                eyeScale.animate(to: StateStyle.style(for: state).eyeScale * 1.06, duration: 0.25, ease: .outBack, at: time)
                if !reduceMotion {
                    body.apply(.wobble(angle: rng.range(-2.4...(-0.7)), strength: 0.25))
                }
                cue(.hover, gain: 0.7)
            }
        } else {
            eyeScale.animate(to: StateStyle.style(for: state).eyeScale, duration: 0.3, at: time)
        }
    }

    public func pressBegan(at local: SIMD2<Double>) {
        isPressed = true
        lastInteractionAt = time
        let side: Double = local.x >= body.centroid.x ? 1 : -1
        if !reduceMotion { body.apply(.slap(side: side, strength: 0.35)) }
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
            onEvent?(.clickClassified(count: n))
            switch n {
            case 1:
                if state.priority <= SlimeState.question.priority { startQuestion() }
            case 2:
                if !reduceMotion { body.apply(.wobble(angle: -.pi / 2, strength: 0.35)) }
            default:
                break
            }
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
        let style = StateStyle.style(for: state)
        lean.animate(to: style.lean, duration: 0.3, ease: .outBack, at: time)
        mouthOpen.animate(to: style.mouthOpen, duration: 0.25, at: time)
    }

    /// The host accepted a drop: the slime starts chewing.
    public func drop() {
        dragExited()
        onEvent?(.dropAccepted)
        startChewing()
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
        let at = max(time, chewStartedAt + 0.9)
        scheduler.cancel(tag: Self.stateTag)
        scheduler.schedule(at: at, tag: Self.stateTag) { [weak self] in
            self?.gulp()
        }
    }

    private func gulp() {
        guard state == .chewing else { return }
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
        }
    }

    public func startQuestion() {
        lastInteractionAt = time
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
        if rng.chance(0.4) {
            scheduler.schedule(at: time + 0.15, tag: Self.emoteTag) { [weak self] in
                self?.trigger(.yawn)
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
        let style = StateStyle.style(for: state)
        switch e {
        case .happy:
            eyeOverride = (.happyArc, .happyArc, until)
            mouthOverride = (.omega, until)
            hop(1.4)
            blush.animate(to: max(baseBlush, 0.55), duration: 0.2, at: time)
        case .love:
            eyeOverride = (.heart, .heart, until)
            mouthOverride = (.omega, until)
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
            eyeOverride = (.half, .half, until)
            mouthOverride = (.smileTiny, until)
            flatten.animate(keys: [.init(to: 0.92, duration: 0.12, ease: .outQuad), .init(to: 1.0, duration: 0.4, ease: .outBack)], at: time)
            lean.animate(keys: [.init(to: 0.1, duration: 0.2, ease: .outBack), .init(to: style.lean, duration: 0.7, ease: .outBack)], at: time)
            let c = body.centroid
            for k in 0..<5 {
                let a = -2.6 + Double(k) * 0.55
                spawn(.star, at: c + SIMD2(cos(a), sin(a)) * 1.35, velocity: SIMD2(cos(a), sin(a)) * 0.5, life: 0.8, size: 0.16)
            }
            cue(.proud)
        case .surprised:
            eyeOverride = (.dot, .dot, until)
            mouthOverride = (.o, until)
            mouthOpen.animate(to: 0.7, duration: 0.1, at: time)
            eyeScale.animate(keys: [.init(to: style.eyeScale * 1.25, duration: 0.1, ease: .outBack), .init(to: style.eyeScale, duration: 0.5, ease: .outCubic)], at: time)
            hop(1.8)
            addAccessory(.exclamation, owner: .emote)
            cue(.pop)
        case .wink:
            eyeOverride = (.happyArc, .open, until)
            mouthOverride = (.smileTiny, until)
            cue(.pop)
        case .yawn:
            eyeOverride = (.tired, .tired, until)
            mouthOverride = (.openRound, until)
            mouthOpen.animate(keys: [.init(to: 1, duration: 0.45, ease: .inOutSine), .init(to: 1, duration: 0.4, ease: .linear),
                                     .init(to: style.mouthOpen, duration: 0.5, ease: .inOutSine)], at: time)
            lean.animate(keys: [.init(to: -0.06, duration: 0.5, ease: .inOutSine), .init(to: style.lean, duration: 0.9, ease: .inOutSine)], at: time)
            cue(.sleep, rate: 0.9)
        case .annoyed:
            eyeOverride = (.flat, .flat, until)
            mouthOverride = (.flat, until)
            let side: Double = (pointer?.x ?? 1) >= 0 ? 1 : -1
            lean.animate(to: -0.14 * side, duration: 0.2, ease: .outBack, at: time)
            cue(.annoyed)
        case .shy:
            eyeOverride = (.half, .half, until)
            blush.animate(to: 0.85, duration: 0.35, at: time)
            sizeScale.animate(to: 0.96, duration: 0.4, ease: .outCubic, at: time)
            let side: Double = (pointer?.x ?? 1) >= 0 ? -1 : 1
            glance = (SIMD2(0.45 * side, -0.05), until)
            cue(.hover, gain: 0.6)
        case .confused:
            eyeOverride = (.dot, .open, until)
            mouthOverride = (.wavy, until)
            glance = (SIMD2(0.3, 0.2), until)
            spawnSweat()
        case .excited:
            eyeOverride = (.star, .star, until)
            mouthOverride = (.omega, until)
            hop(1.6)
            scheduler.schedule(at: time + 0.5, tag: Self.emoteTag) { [weak self] in self?.hop(1.6) }
            scheduler.schedule(at: time + 0.2, tag: Self.emoteTag) { [weak self] in self?.spawnSparkles(count: 6) }
            cue(.finish, gain: 0.8)
        }
    }

    private func endEmote() {
        guard emote != nil else { return }
        emote = nil
        scheduler.cancel(tag: Self.emoteTag)
        if let o = eyeOverride, o.until == emoteUntil { eyeOverride = nil }
        if let m = mouthOverride, m.until == emoteUntil { mouthOverride = nil }
        if let g = glance, g.until == emoteUntil { glance = nil }
        let style = StateStyle.style(for: state)
        blush.animate(to: baseBlush, duration: 0.5, at: time)
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

    private func hop(_ v0: Double) {
        guard !reduceMotion, !body.airborne else { return }
        body.apply(.jump(v0: v0))
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
        }
        if s == .sleeping {
            flatten.animate(to: 1, duration: 0.5, ease: .outBack, at: time)
        }
    }

    private func enterState(_ s: SlimeState) {
        let style = StateStyle.style(for: s)
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
            scheduleBite()
        case .finished:
            hop(2.6)
            blush.animate(to: max(baseBlush, 0.6), duration: 0.2, at: time)
            scheduler.schedule(at: time + 0.26, tag: Self.stateTag) { [weak self] in self?.spawnSparkles(count: 5) }
            scheduler.schedule(at: time + 1.9, tag: Self.stateTag) { [weak self] in
                guard let self else { return }
                self.blush.animate(to: self.baseBlush, duration: 0.4, at: self.time)
            }
        case .error:
            if !reduceMotion { shakeKicks([(0, 2.6), (0.06, -4.4), (0.13, 3.2), (0.2, -1.6)]) }
            scheduleSweat()
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
        let dt = rng.range(6...14)
        scheduler.schedule(at: time + dt, tag: Self.stateTag) { [weak self] in
            guard let self else { return }
            self.microIdle()
            self.scheduleMicroIdle()
        }
    }

    private func microIdle() {
        guard state == .idle, !isPressed else { return }
        switch rng.int(0..<3) {
        case 0:
            glance = (SIMD2(rng.sign() * rng.range(0.3...0.5), rng.range(-0.1...0.25)), time + rng.range(0.6...1.0))
        case 1:
            if !reduceMotion { body.apply(.wobble(angle: rng.range(-2.6...(-0.5)), strength: 0.25)) }
        default:
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
            self.cue(.chew, rate: self.chewSide > 0 ? 1 : 1.06)
            self.chewSide = -self.chewSide
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

    private func spawnSweat() {
        let world = frameNow().body.transform(SIMD2(0.72, -1.38))
        spawn(.drop, at: world, velocity: SIMD2(0.05, 0.25), life: 0.95, size: 0.15)
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
        if isAway { return .closedLine }
        if let o = eyeOverride { return side < 0 ? o.left : o.right }
        return baseEye
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
        let yaw = gaze.yaw
        let pitch = gaze.pitch
        let open = blink.openness
        let es = eyeScale.value * (state == .listening ? 1 + 0.06 * audioLevel : 1)
        var eyes: [EyeFrame] = []
        for side in [-1.0, 1.0] {
            let proj = eyeRig.eye(side: side, yaw: yaw, pitch: pitch)
            let world = bf.transform(eyeRig.local(proj))
            eyes.append(EyeFrame(side: side, shape: resolvedEye(side), center: world, radius: eyeRig.eyeRadius,
                                 aspect: eyeRig.eyeAspect, foreshorten: proj.foreshorten,
                                 openness: side < 0 ? open.x : open.y, visible: proj.visible, scale: es))
        }
        let mp = eyeRig.project(yawOffset: 0, pitchOffset: eyeRig.mouthPitch, yaw: yaw, pitch: pitch)
        let mouth = MouthFrame(shape: mouthOverride?.shape ?? baseMouth, open: mouthOpen.value,
                               center: bf.transform(eyeRig.local(mp)), foreshorten: mp.foreshorten, visible: mp.visible)
        var blushCenters: [SIMD2<Double>] = []
        var blushFore: [SIMD2<Double>] = []
        if profile.blushEnabled {
            for side in [-1.0, 1.0] {
                let bp = eyeRig.project(yawOffset: side * eyeRig.blushYaw, pitchOffset: eyeRig.blushPitch, yaw: yaw, pitch: pitch)
                if bp.visible {
                    blushCenters.append(bf.transform(eyeRig.local(bp)))
                    blushFore.append(bp.foreshorten)
                }
            }
        }
        var acc: [AccessoryFrame] = []
        accessories.removeAll { r in r.removeAt.map { time - $0 > 0.18 } ?? false }
        for a in accessories {
            let age = time - a.startedAt
            var pop = Ease.outBack.apply(min(1, age / 0.28))
            if let r = a.removeAt { pop = max(0, 1 - (time - r) / 0.18) * min(pop, 1) }
            let local: SIMD2<Double>
            switch a.kind {
            case .question, .exclamation, .dots: local = SIMD2(1.15, -2.05)
            case .badge: local = SIMD2(0.95, -1.9)
            case .micBars: local = SIMD2(1.75, -1.0)
            case .recDot: local = SIMD2(1.25, -1.8)
            }
            acc.append(AccessoryFrame(kind: a.kind, anchor: bf.transform(local), pop: pop, phase: age, levels: a.kind == .micBars ? micLevels : []))
        }
        let moving = body.airborne || flatten.isAnimating || sizeScale.isAnimating || shakeX.isAnimating || !particles.isEmpty
            || blobs.contains(where: { $0.radius > 1e-3 }) || isPressed || state == .split || state == .chewing || state == .dizzy || state == .greeting
        // A resting pointer is not activity: the gaze counts only while it is still turning.
        let gazeMoving = abs(gaze.yaw - gaze.target.x) > 0.003 || abs(gaze.pitch - gaze.target.y) > 0.003
        let lively = blink.isBlinking || lean.isAnimating || opacityAnim.isAnimating || faceOpacityAnim.isAnimating || eyeScale.isAnimating || blush.isAnimating || mouthOpen.isAnimating
            || glance != nil || eyeOverride != nil || emote != nil || !acc.isEmpty || !state.isQuiet || gazeMoving
        activity = moving ? 2 : (lively ? 1 : 0)
        return SlimeFrame(
            profile: profile.kind, state: state, emote: emote, ring: ring, root: body.root, body: bf,
            contactWidth: body.contactWidth, airborne: body.airborne, eyes: eyes, mouth: mouth,
            blush: blush.value, blushCenters: blushCenters, blushForeshorten: blushFore,
            core: coreSpring.value, coreBoost: coreBoost, gaze: SIMD2(yaw, pitch),
            highlightShift: SIMD2(-0.08 * yaw, 0.06 * pitch), tint: tint, accessories: acc, particles: particles,
            blobs: blobs, opacity: opacity, faceOpacity: faceOpacity, glowBoost: glowBoost, sizeScale: sizeScale.value,
            ghostStretch: ghostStretch, ghostHeading: ghostHeading)
    }
}
