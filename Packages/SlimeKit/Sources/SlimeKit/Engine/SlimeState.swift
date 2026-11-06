import Foundation
import simd

/// What the host's agents are doing (set by the app).
public enum AgentState: String, Sendable, Codable, CaseIterable {
    case idle, thinking, working, waiting, finished, error
}

/// What the user is doing with the slime (set by the engine itself or the host).
public enum UserState: String, Sendable, Codable, CaseIterable {
    case none, greeting, listening, recording, chewing, question, dizzy, split, sleeping
}

/// The resolved state: the highest priority of the agent state and the user state.
public enum SlimeState: String, Sendable, Codable, CaseIterable {
    case idle, sleeping, thinking, working, finished, waiting, question, error
    case recording, listening, greeting, chewing, split, dizzy

    public var priority: Int {
        switch self {
        case .idle: return 0
        case .sleeping: return 10
        case .thinking, .working: return 50
        case .finished: return 55
        case .waiting: return 60
        case .question: return 65
        case .error: return 70
        case .recording: return 75
        case .listening: return 80
        case .greeting: return 85
        case .chewing: return 90
        case .split: return 95
        case .dizzy: return 100
        }
    }

    /// Timed states expire on their own.
    public var duration: Double? {
        switch self {
        case .greeting: return 2.0
        case .question: return 2.2
        case .finished: return 2.4
        case .dizzy: return 1.6
        case .split: return 1.8
        default: return nil
        }
    }

    public var isQuiet: Bool { self == .idle || self == .sleeping }
}

public enum SlimeEmote: String, Sendable, Codable, CaseIterable {
    case happy, love, proud, surprised, wink, yawn, annoyed, shy, confused, excited
    /// Body-morph and gesture emotes (Character 2): melting into a puddle, puffed cheeks, a startled
    /// shock, crying, humming a note, cheering, a self-hug, a nod, a head shake, a thumbs up, a
    /// tall morning stretch and the side squish of being poked.
    case melt, puff, shock, cry, hum, cheer, hug, nod, shakeNo, thumbsUp, stretch, poked

    public var duration: Double {
        switch self {
        case .happy: return 1.2
        case .love: return 1.8
        case .proud: return 1.6
        case .surprised: return 0.7
        case .wink: return 0.6
        case .yawn: return 1.4
        case .annoyed: return 0.8
        case .shy: return 1.6
        case .confused: return 0.9
        case .excited: return 1.4
        case .melt: return 2.2
        case .puff: return 1.0
        case .shock: return 0.9
        case .cry: return 1.8
        case .hum: return 2.0
        case .cheer: return 1.2
        case .hug: return 1.6
        case .nod: return 0.8
        case .shakeNo: return 0.8
        case .thumbsUp: return 0.8
        case .stretch: return 1.2
        case .poked: return 0.6
        }
    }
}

public enum SlimeProfileKind: String, Sendable, Codable {
    case main, mini, ghost
}

public struct SlimeProfile: Sendable, Equatable {
    public var kind: SlimeProfileKind
    public var body: SoftBodyParams
    public var eyeRig: EyeRig
    public var blushEnabled: Bool
    public var bigHighlight: Bool
    /// Render scale relative to the main slime's R.
    public var scale: Double
    public var floorEnabled: Bool

    public init(kind: SlimeProfileKind, body: SoftBodyParams, eyeRig: EyeRig, blushEnabled: Bool, bigHighlight: Bool, scale: Double, floorEnabled: Bool = true) {
        self.kind = kind; self.body = body; self.eyeRig = eyeRig
        self.blushEnabled = blushEnabled; self.bigHighlight = bigHighlight
        self.scale = scale; self.floorEnabled = floorEnabled
    }

    public static let main = SlimeProfile(kind: .main, body: .main, eyeRig: .main, blushEnabled: true, bigHighlight: true, scale: 1)
    public static let mini = SlimeProfile(kind: .mini, body: .mini, eyeRig: .mini, blushEnabled: false, bigHighlight: false, scale: 0.45)
    public static let ghost = SlimeProfile(kind: .ghost, body: .main, eyeRig: .main, blushEnabled: false, bigHighlight: true, scale: 1, floorEnabled: false)
}

public enum SlimeEvent: Sendable, Equatable {
    case stateChanged(SlimeState)
    case holdBegan
    case holdEnded(duration: Double)
    case clickClassified(count: Int)
    case dragOutBegan
    case splitRequested(extra: Int)
    case dropAccepted
    case landed(speed: Double)
    case emoteTriggered(SlimeEmote)
    case wokeUp
}

/// Per-state styling applied on entry. Loops (hops, darts, sweat drops…) are scheduled separately.
struct StateStyle: Sendable {
    var breathAmplitude: Double = 0.02
    var breathRate: Double = 0.21
    var blinkInterval: ClosedRange<Double> = 2.2...5.4
    var blinkSuppressed = false
    var eye: EyeShape = .open
    var mouth: MouthShape = .smileTiny
    var mouthOpen: Double = 0
    var eyeScale: Double = 1
    var lean: Double = 0
    var gazeOverride: SIMD2<Double>? = nil
    var gazeBlend: Double = 0
    var tint: StateTint = .none
    var entrySound: SoundCue? = nil
    var clearsEmote = false
    var accessory: AccessoryKind? = nil

    static func style(for state: SlimeState) -> StateStyle {
        var s = StateStyle()
        switch state {
        case .idle:
            break
        case .greeting:
            s.clearsEmote = true
        case .listening:
            s.eyeScale = 1.12
            s.mouth = .o
            s.mouthOpen = 0.35
            s.breathRate = 0.30
            s.blinkInterval = 3.0...4.5
            s.accessory = .micBars
            s.entrySound = SoundCue(.listenOn)
            s.gazeOverride = SIMD2(0, 0.12)
            s.gazeBlend = 0.5
        case .thinking:
            s.eye = .focused
            s.gazeOverride = SIMD2(0.45, 0.35)
            s.gazeBlend = 0.6
            s.accessory = .dots
            s.tint = .thinking
            s.entrySound = SoundCue(.think)
            s.blinkInterval = 2.6...5.8
        case .working:
            s.eye = .focused
            s.accessory = .badge
            s.blinkInterval = 2.6...5.8
            s.entrySound = SoundCue(.work)
        case .waiting:
            s.eye = .wide
            s.eyeScale = 1.08
            s.accessory = .exclamation
            s.tint = .waiting
            s.entrySound = SoundCue(.waiting)
        case .question:
            s.accessory = .question
            s.lean = 0.17
            s.entrySound = SoundCue(.question)
            s.clearsEmote = true
        case .chewing:
            s.mouth = .openRound
            s.mouthOpen = 1
            s.clearsEmote = true
            s.blinkInterval = 3.0...6.0
        case .finished:
            s.eye = .happyArc
            s.mouth = .omega
            s.entrySound = SoundCue(.finish)
            s.clearsEmote = true
            s.blinkSuppressed = true
        case .error:
            s.eye = .flat
            s.mouth = .flat
            s.tint = .error
            s.entrySound = SoundCue(.error)
            s.blinkInterval = 3.0...6.0
        case .sleeping:
            s.eye = .tired
            s.mouth = .sleepy
            s.breathAmplitude = 0.035
            s.breathRate = 0.14
            s.blinkSuppressed = true
            s.tint = .sleeping
            s.entrySound = SoundCue(.sleep)
            s.clearsEmote = true
        case .dizzy:
            s.eye = .spiral
            s.mouth = .wavy
            s.tint = .dizzy
            s.entrySound = SoundCue(.dizzy)
            s.blinkSuppressed = true
            s.clearsEmote = true
        case .recording:
            s.eye = .focused
            s.accessory = .recDot
            s.breathAmplitude = 0.012
            s.entrySound = SoundCue(.blip, rate: 1.3)
        case .split:
            s.eye = .spiral
            s.blinkSuppressed = true
            s.clearsEmote = true
        }
        return s
    }
}
