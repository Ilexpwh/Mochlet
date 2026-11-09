import Foundation

/// How the face is drawn: the anime's ink strokes (no sclera, a mouth only when the moment
/// needs one) or the round ball eyes with pupils and a resting smile.
public enum FaceStyle: String, Sendable, Codable, CaseIterable {
    case anime, round
}

/// One face: left and right eye shapes and an optional mouth (nil leaves the state's mouth).
public struct FacePose: Sendable, Equatable {
    public var left: EyeShape
    public var right: EyeShape
    public var mouth: MouthShape?

    public init(_ eye: EyeShape, _ mouth: MouthShape? = nil) {
        left = eye; right = eye; self.mouth = mouth
    }

    public init(left: EyeShape, right: EyeShape, mouth: MouthShape? = nil) {
        self.left = left; self.right = right; self.mouth = mouth
    }
}

/// The face catalogue: what each state and emote wears in each style. The round column is the
/// character's earlier face; the anime column follows the sticker and figure sheets.
public enum FaceTable {
    public static func state(_ s: SlimeState, _ face: FaceStyle) -> FacePose {
        switch face {
        case .round:
            switch s {
            case .idle, .greeting, .question: return FacePose(.open, .smileTiny)
            case .listening: return FacePose(.open, .o)
            case .thinking, .working, .recording: return FacePose(.focused, .smileTiny)
            case .waiting: return FacePose(.wide, .smileTiny)
            case .chewing: return FacePose(.open, .openRound)
            case .finished: return FacePose(.happyArc, .omega)
            case .error: return FacePose(.flat, .flat)
            case .sleeping: return FacePose(.tired, .sleepy)
            case .dizzy: return FacePose(.spiral, .wavy)
            case .split: return FacePose(.spiral, .smileTiny)
            }
        case .anime:
            switch s {
            case .idle, .greeting, .question, .waiting: return FacePose(.content, MouthShape.none)
            case .listening: return FacePose(.content, .o)
            case .thinking, .working, .recording: return FacePose(.relaxed, MouthShape.none)
            case .chewing: return FacePose(.content, .openRound)
            case .finished: return FacePose(.happyArc, .omega)
            case .error: return FacePose(.squeeze, .wavy)
            case .sleeping: return FacePose(.flat, MouthShape.none)
            case .dizzy: return FacePose(.spiral, .wavy)
            case .split: return FacePose(.spiral, MouthShape.none)
            }
        }
    }

    public static func emote(_ e: SlimeEmote, _ face: FaceStyle) -> FacePose {
        switch face {
        case .round:
            switch e {
            case .happy: return FacePose(.happyArc, .omega)
            case .love: return FacePose(.heart, .omega)
            case .proud: return FacePose(.half, .smileTiny)
            case .surprised: return FacePose(.dot, .o)
            case .wink: return FacePose(left: .happyArc, right: .open, mouth: .smileTiny)
            case .yawn: return FacePose(.tired, .openRound)
            case .annoyed: return FacePose(.flat, .flat)
            case .shy: return FacePose(.half)
            case .confused: return FacePose(left: .dot, right: .open, mouth: .wavy)
            case .excited: return FacePose(.star, .omega)
            case .melt: return FacePose(.tired, .squiggle)
            case .puff: return FacePose(.glare, .pout)
            case .shock: return FacePose(.shock, .openWide)
            case .cry: return FacePose(.teary, .squiggle)
            case .hum: return FacePose(.relaxed, .smileTiny)
            case .cheer: return FacePose(.happyArc, .grin)
            case .hug, .nod: return FacePose(.pleased, .smileTiny)
            case .shakeNo: return FacePose(.flat, .pout)
            case .thumbsUp: return FacePose(left: .open, right: .happyArc, mouth: .grin)
            case .stretch: return FacePose(.relaxed, .o)
            case .poked: return FacePose(.squeeze, .o)
            }
        case .anime:
            switch e {
            case .happy: return FacePose(.happyArc, .omega)
            case .love: return FacePose(.heart, .omega)
            case .proud: return FacePose(left: .happyArc, right: .flat, mouth: .smileTiny)
            case .surprised: return FacePose(.shock, .o)
            case .wink: return FacePose(left: .happyArc, right: .content, mouth: MouthShape.none)
            case .yawn: return FacePose(.flat, .openRound)
            case .annoyed: return FacePose(.flat, .caret)
            case .shy: return FacePose(.content, MouthShape.none)
            case .confused: return FacePose(left: .content, right: .flat, mouth: .wavy)
            case .excited: return FacePose(.sparkle, .omega)
            case .melt: return FacePose(.sad, .wavy)
            case .puff: return FacePose(.squint, .caret)
            case .shock: return FacePose(.shock, .openWide)
            case .cry: return FacePose(.cryStream, .wavy)
            case .hum: return FacePose(.pleased, MouthShape.none)
            case .cheer: return FacePose(.happyArc, .openWide)
            case .hug: return FacePose(.pleased, MouthShape.none)
            case .nod: return FacePose(.content, MouthShape.none)
            case .shakeNo: return FacePose(.flat, .caret)
            case .thumbsUp: return FacePose(left: .content, right: .happyArc, mouth: .smileTiny)
            case .stretch: return FacePose(.flat, .o)
            case .poked: return FacePose(.squeeze, .o)
            }
        }
    }

    /// The eye rig a profile uses in a style (`fallback` is the profile's own round rig).
    public static func rig(kind: SlimeProfileKind, face: FaceStyle, fallback: EyeRig) -> EyeRig {
        switch face {
        case .round: return fallback
        case .anime: return kind == .mini ? .animeMini : .anime
        }
    }

    /// Resting blush: the anime face always wears its two pink ovals.
    public static func baseBlush(kind: SlimeProfileKind, face: FaceStyle, blushEnabled: Bool) -> Double {
        switch face {
        case .round: return blushEnabled ? 0.35 : 0
        case .anime: return kind == .mini ? 0.60 : 0.70
        }
    }
}
