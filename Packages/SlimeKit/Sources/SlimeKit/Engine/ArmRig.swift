import Foundation
import simd

/// Something a hand can hold.
public enum Prop: Sendable, Equatable, Hashable, Codable {
    public enum FileKind: String, Sendable, Codable, CaseIterable {
        case doc, pdf, image, audio, video, folder, link, text
    }
    /// A dropped file; `bites` is the fraction already eaten (0…1).
    case file(kind: FileKind, bites: Double)
    case page, book, phone, mug, pen, magnifier, mic, bell, mask, heart, gift

    public var isFile: Bool { if case .file = self { return true } else { return false } }

    /// Held in both hands (true) or one hand (false).
    public var twoHanded: Bool {
        switch self {
        case .file, .book, .gift, .mask, .heart: return true
        case .page, .phone, .mug, .pen, .magnifier, .mic, .bell: return false
        }
    }

    public var name: String {
        switch self {
        case .file(let kind, _): return kind.rawValue
        case .page: return "page"
        case .book: return "book"
        case .phone: return "phone"
        case .mug: return "mug"
        case .pen: return "pen"
        case .magnifier: return "magnifier"
        case .mic: return "mic"
        case .bell: return "bell"
        case .mask: return "mask"
        case .heart: return "heart"
        case .gift: return "gift"
        }
    }

    /// "phone", "file", "file:pdf", "pdf".
    public static func named(_ s: String) -> Prop? {
        switch s {
        case "page": return .page
        case "book": return .book
        case "phone": return .phone
        case "mug": return .mug
        case "pen": return .pen
        case "magnifier": return .magnifier
        case "mic": return .mic
        case "bell": return .bell
        case "mask": return .mask
        case "heart": return .heart
        case "gift": return .gift
        case "file": return .file(kind: .doc, bites: 0)
        default:
            if s.hasPrefix("file:"), let k = FileKind(rawValue: String(s.dropFirst(5))) { return .file(kind: k, bites: 0) }
            if let k = FileKind(rawValue: s) { return .file(kind: k, bites: 0) }
            return nil
        }
    }
}

/// Where the pseudopod arms are. `hidden` means no arms at all (the idle path draws nothing).
public enum ArmPose: Sendable, Equatable, Hashable {
    case hidden
    /// Both hands in front, below the mouth.
    case holdFront(Prop)
    /// Both hands up above the head (catching, showing off).
    case holdHigh(Prop)
    /// One hand beside the face (phone, mic, mug).
    case holdSide(Prop, side: Double)
    /// Both arms wrapped around a prop in front, or around the body itself (nil).
    case hug(Prop?)
    case wave(side: Double)
    case thumbsUp(side: Double)
    case cheer
    case rubEyes
    case scratchHead
    case facepalm
    case cover
    case point(SIMD2<Double>)
    case sip

    public var isHidden: Bool { if case .hidden = self { return true } else { return false } }

    public var prop: Prop? {
        switch self {
        case .holdFront(let p), .holdHigh(let p): return p
        case .hug(let p): return p
        case .holdSide(let p, _): return p
        case .sip: return .mug
        default: return nil
        }
    }

    /// The same pose holding a different prop (eating: the file loses a bite).
    public func replacingProp(_ p: Prop) -> ArmPose {
        switch self {
        case .holdFront: return .holdFront(p)
        case .holdHigh: return .holdHigh(p)
        case .hug: return .hug(p)
        case .holdSide(_, let s): return .holdSide(p, side: s)
        default: return self
        }
    }

    public var name: String {
        switch self {
        case .hidden: return "hidden"
        case .holdFront(let p): return "holdFront:" + p.name
        case .holdHigh(let p): return "holdHigh:" + p.name
        case .holdSide(let p, let s): return "holdSide:" + p.name + (s < 0 ? ":-1" : ":1")
        case .hug(let p): return "hug:" + (p?.name ?? "self")
        case .wave(let s): return s < 0 ? "wave:-1" : "wave"
        case .thumbsUp(let s): return s < 0 ? "thumbsUp:-1" : "thumbsUp"
        case .cheer: return "cheer"
        case .rubEyes: return "rubEyes"
        case .scratchHead: return "scratchHead"
        case .facepalm: return "facepalm"
        case .cover: return "cover"
        case .point(let d): return "point:\(d.x),\(d.y)"
        case .sip: return "sip"
        }
    }

    /// "wave", "wave:-1", "holdFront:phone", "holdSide:mic:1", "point:1,-0.5", "hug:heart", "hug:self".
    public static func parse(_ s: String) -> ArmPose? {
        let parts = s.split(separator: ":").map(String.init)
        guard let head = parts.first else { return nil }
        func side(_ i: Int) -> Double { parts.count > i ? (Double(parts[i]) ?? 1) : 1 }
        func prop(_ i: Int, _ d: Prop) -> Prop { parts.count > i ? (Prop.named(parts[i]) ?? d) : d }
        switch head {
        case "hidden", "none": return .hidden
        case "holdFront": return .holdFront(prop(1, .file(kind: .doc, bites: 0)))
        case "holdHigh": return .holdHigh(prop(1, .bell))
        case "holdSide": return .holdSide(prop(1, .phone), side: side(2))
        case "hug": return parts.count > 1 && (parts[1] == "self" || parts[1] == "none") ? .hug(nil) : .hug(prop(1, .heart))
        case "wave": return .wave(side: side(1))
        case "thumbsUp": return .thumbsUp(side: side(1))
        case "cheer": return .cheer
        case "rubEyes": return .rubEyes
        case "scratchHead": return .scratchHead
        case "facepalm": return .facepalm
        case "cover": return .cover
        case "sip": return .sip
        case "point":
            let xy = parts.count > 1 ? parts[1].split(separator: ",").compactMap { Double($0) } : []
            return .point(xy.count == 2 ? SIMD2(xy[0], xy[1]) : SIMD2(1, -0.4))
        default: return nil
        }
    }
}

/// How the hand at the end of an arm is drawn.
public enum HandShape: String, Sendable, Equatable, Codable {
    case open, grip, fist, thumbsUp, point
}

/// One arm for the renderer, in world R units (floor at y = 0, y down).
public struct ArmFrame: Sendable, Equatable {
    public var side: Double
    public var shoulder: SIMD2<Double>
    public var elbow: SIMD2<Double>
    public var hand: SIMD2<Double>
    /// 0 retracted (not drawn) … 1 fully out; thickness scales with it.
    public var reach: Double
    public var handRadius: Double
    public var shape: HandShape

    public init(side: Double, shoulder: SIMD2<Double>, elbow: SIMD2<Double>, hand: SIMD2<Double>, reach: Double, handRadius: Double, shape: HandShape) {
        self.side = side
        self.shoulder = shoulder
        self.elbow = elbow
        self.hand = hand
        self.reach = reach
        self.handRadius = handRadius
        self.shape = shape
    }
}

/// A prop in a hand (or between two), in world R units.
public struct PropFrame: Sendable, Equatable {
    public var prop: Prop
    public var position: SIMD2<Double>
    public var angle: Double
    /// 0…1 pop-in; also scales the drawing.
    public var scale: Double
    /// Two-handed props sit behind the hands; one-handed props sit in front of the hand.
    public var behindHands: Bool

    public init(prop: Prop, position: SIMD2<Double>, angle: Double, scale: Double, behindHands: Bool) {
        self.prop = prop
        self.position = position
        self.angle = angle
        self.scale = scale
        self.behindHands = behindHands
    }
}

/// Something seen through the jelly while it digests (pages swirling inside), world R units.
public struct InnerItem: Sendable, Equatable {
    public enum Kind: String, Sendable, Codable { case page }
    public var kind: Kind
    public var position: SIMD2<Double>
    public var angle: Double
    public var size: Double
    public var opacity: Double

    public init(kind: Kind, position: SIMD2<Double>, angle: Double, size: Double, opacity: Double) {
        self.kind = kind
        self.position = position
        self.angle = angle
        self.size = size
        self.opacity = opacity
    }
}

/// Where the eating timeline is: catch the file, bite it, digest it (pages inside), file it.
public enum ChewPhase: Sendable, Equatable {
    case catching
    case biting(Double)
    case digesting
    case filing

    public var name: String {
        switch self {
        case .catching: return "catching"
        case .biting(let b): return "biting:\(Double(Int(b * 100)) / 100)"
        case .digesting: return "digesting"
        case .filing: return "filing"
        }
    }

    public static func parse(_ s: String) -> ChewPhase? {
        let parts = s.split(separator: ":").map(String.init)
        switch parts.first ?? "" {
        case "catching": return .catching
        case "biting": return .biting(parts.count > 1 ? (Double(parts[1]) ?? 0) : 0)
        case "digesting": return .digesting
        case "filing": return .filing
        default: return nil
        }
    }
}

/// Keyframed pseudopod arms. Targets are in body units relative to the rest centroid (x right,
/// y down, the body about 1 R across); the engine maps them through the body's affine fit so
/// the arms squash and lean with the jelly. Every pose change tweens from the current joints
/// (0.28 s outBack), so switching mid-move never snaps.
public struct ArmRig: Sendable, Equatable {
    public struct Target: Sendable, Equatable {
        public var shoulderAngle: Double
        public var elbow: SIMD2<Double>
        public var hand: SIMD2<Double>
        public var reach: Double
        public var shape: HandShape

        static func hidden(side: Double) -> Target {
            let a = side > 0 ? -0.35 : .pi + 0.35
            let s = SIMD2(cos(a), sin(a)) * 0.98
            return Target(shoulderAngle: a, elbow: s, hand: s, reach: 0, shape: .open)
        }

        static func lerp(_ a: Target, _ b: Target, _ t: Double) -> Target {
            Target(shoulderAngle: a.shoulderAngle + (b.shoulderAngle - a.shoulderAngle) * t,
                   elbow: a.elbow + (b.elbow - a.elbow) * t,
                   hand: a.hand + (b.hand - a.hand) * t,
                   reach: a.reach + (b.reach - a.reach) * t,
                   shape: t < 0.5 ? a.shape : b.shape)
        }
    }

    public static let transition = 0.28
    /// The arm is a small triangle of jelly, as in the anime stills: a nub that pokes about
    /// 0.3 R out of the silhouette, broad at the base and sharp at the tip, with no hand at all.
    /// Only a held prop needs a longer reach, and then the pseudopod thins into a tentacle that
    /// ends in a small rounded grip. Half-widths in R units at full reach.
    public static let nubBaseHalfWidth = 0.15
    public static let tentacleBaseHalfWidth = 0.11
    public static let nubTipHalfWidth = 0.03
    public static let gripRadius = 0.05
    /// How far a nub pokes out of the body (authoring units, see `keyframe`).
    public static let nubLength = 0.32

    /// Radius of the tip for a hand shape: a point unless the hand holds something.
    public static func handRadius(for shape: HandShape) -> Double {
        shape == .grip ? gripRadius : nubTipHalfWidth
    }

    /// Centre-line length of the arm in R (shoulder to elbow to hand).
    public static func length(_ a: ArmFrame) -> Double {
        simd_distance(a.shoulder, a.elbow) + simd_distance(a.elbow, a.hand)
    }

    /// Half-width at the shoulder for this arm's length: the nub's up to 0.45 R, the tentacle's
    /// from 0.9 R, a straight ramp between.
    public static func baseHalfWidth(_ a: ArmFrame) -> Double {
        let k = max(0, min(1, (length(a) - 0.45) / 0.45))
        return nubBaseHalfWidth + (tentacleBaseHalfWidth - nubBaseHalfWidth) * k
    }

    // MARK: Lobe geometry (shared by the goo and the renderer)

    /// Point on the arm's centre line: a quadratic curve from the shoulder through the elbow
    /// (the control point) to the hand; t < 0 extrapolates a little way inside the body.
    public static func centre(_ a: ArmFrame, _ t: Double) -> SIMD2<Double> {
        let u = 1 - t
        return a.shoulder * (u * u) + a.elbow * (2 * u * t) + a.hand * (t * t)
    }

    /// Unit tangent of the centre line at t.
    public static func tangent(_ a: ArmFrame, _ t: Double) -> SIMD2<Double> {
        let d = (a.elbow - a.shoulder) * (2 * (1 - t)) + (a.hand - a.elbow) * (2 * t)
        let l = simd_length(d)
        return l > 1e-6 ? d / l : SIMD2(0, -1)
    }

    /// Half-width of the lobe at t: a straight taper from the base to the tip (the hand's
    /// radius), with a concave flare over the first fifth so the nub spreads into the body
    /// surface instead of meeting it at a corner.
    public static func halfWidth(_ a: ArmFrame, _ t: Double, bodyScale: Double) -> Double {
        let u = max(0, min(1, t))
        let base = baseHalfWidth(a)
        let taper = base + (a.handRadius - base) * u
        let f = max(0, 1 - u / 0.2)
        let flare = base * 0.9 * f * f
        return (taper + flare) * a.reach * bodyScale
    }

    /// Thumb direction (world, y down) for a thumbs-up and the pointing direction for a point.
    public static func digit(_ a: ArmFrame) -> SIMD2<Double> {
        switch a.shape {
        case .thumbsUp: return simd_normalize(SIMD2(0.12 * a.side, -1))
        default: return tangent(a, 1)
        }
    }

    /// The arm adds nothing to the goo. The metaball field (sigma 0.18 R) rounds anything it
    /// touches to about 0.15 R and even a tiny blob at the shoulder raises a bump a third of a
    /// radius out, so the renderer draws the whole lobe as a sharp polygon on top of the
    /// silhouette and the flare at the base is part of its outline (`halfWidth`).
    public static func blobs(for a: ArmFrame, bodyScale: Double) -> [Blob] {
        []
    }

    public private(set) var pose: ArmPose = .hidden
    private var from: [Target] = [.hidden(side: -1), .hidden(side: 1)]
    private var to: [Target] = [.hidden(side: -1), .hidden(side: 1)]
    private var startedAt: Double = 0
    private var duration: Double = 0.28
    private var poseSince: Double = 0

    public init() {}

    public func isAnimating(at time: Double) -> Bool { time - startedAt < duration }

    /// Poses with their own motion (waving, pumping) need the display rate while they last.
    public var hasMotion: Bool {
        switch pose {
        case .wave, .cheer, .rubEyes, .scratchHead, .sip: return true
        default: return false
        }
    }

    public mutating func retarget(to pose: ArmPose, at time: Double) {
        let cur = currentTargets(at: time)
        from = cur
        to = [Self.keyframe(pose, side: -1), Self.keyframe(pose, side: 1)]
        startedAt = time
        // Long reaches take a little longer so no joint ever moves more than ~0.25 R per frame.
        var far = 0.0
        for i in 0..<2 { far = max(far, simd_distance(from[i].hand, to[i].hand), simd_distance(from[i].elbow, to[i].elbow)) }
        duration = max(Self.transition, 0.2 + 0.13 * far)
        if pose != self.pose { poseSince = time }
        self.pose = pose
    }

    /// Current joints for both arms (index 0 = left, 1 = right), before pose motion.
    public func currentTargets(at time: Double) -> [Target] {
        let t = Ease.outCubic.apply(min(1, (time - startedAt) / duration))
        return [Target.lerp(from[0], to[0], t), Target.lerp(from[1], to[1], t)]
    }

    /// Joints with the pose's own motion (a wave sways, a cheer pumps) applied.
    public func joints(at time: Double) -> [Target] {
        var cur = currentTargets(at: time)
        let age = time - poseSince
        let settled = min(1, max(0, (time - startedAt) / duration))
        switch pose {
        case .wave(let side):
            let i = side < 0 ? 0 : 1
            let sway = sin(age * 2 * .pi * 2.6) * settled
            cur[i].hand.x += 0.07 * sway
            cur[i].hand.y += 0.03 * abs(sway)
            cur[i].elbow.x += 0.02 * sway
        case .cheer:
            let pump = 0.08 * max(0, sin(age * 2 * .pi * 2.4)) * settled
            cur[0].hand.y -= pump
            cur[1].hand.y -= pump
        case .rubEyes:
            for i in 0..<2 {
                let ph = age * 2 * .pi * 1.8 + (i == 0 ? 0 : .pi)
                cur[i].hand += SIMD2(cos(ph), sin(ph)) * 0.03 * settled
            }
        case .scratchHead:
            cur[1].hand.x += 0.03 * sin(age * 2 * .pi * 4) * settled
            cur[1].hand.y += 0.015 * sin(age * 2 * .pi * 8) * settled
        case .sip:
            // Lift the mug to the mouth and tip it, then lower it.
            let cycle = age.truncatingRemainder(dividingBy: 3.0)
            let lift = cycle < 0.6 ? Ease.inOutSine.apply(cycle / 0.6) : cycle < 1.6 ? 1 : cycle < 2.2 ? 1 - Ease.inOutSine.apply((cycle - 1.6) / 0.6) : 0
            cur[1].hand += SIMD2(-0.22, -0.3) * lift * settled
        default:
            break
        }
        return cur
    }

    /// Tilt of the sipped mug, radians, for the current cycle.
    public func sipTilt(at time: Double) -> Double {
        guard case .sip = pose else { return 0 }
        let cycle = (time - poseSince).truncatingRemainder(dividingBy: 3.0)
        return cycle > 0.7 && cycle < 1.6 ? -0.45 * sin(((cycle - 0.7) / 0.9) * .pi) : 0
    }

    /// Where the prop sits relative to the hands (body units) and how it is tilted.
    public static func propPlacement(_ pose: ArmPose, joints: [Target]) -> (offset: SIMD2<Double>, angle: Double, behindHands: Bool)? {
        switch pose {
        case .holdFront(let p):
            let mid = (joints[0].hand + joints[1].hand) * 0.5
            return (mid + SIMD2(0, p.isFile ? -0.04 : -0.08), 0, true)
        case .holdHigh:
            let mid = (joints[0].hand + joints[1].hand) * 0.5
            return (mid + SIMD2(0, -0.12), 0, true)
        case .hug(.some):
            let mid = (joints[0].hand + joints[1].hand) * 0.5
            return (mid + SIMD2(0, -0.2), 0, true)
        case .hug(.none):
            return nil
        case .holdSide(let p, let side):
            let h = joints[side < 0 ? 0 : 1].hand
            switch p {
            case .phone: return (h + SIMD2(-0.06 * side, -0.26), 0.22 * side, false)
            case .mic: return (h + SIMD2(0.02 * side, -0.28), 0.35 * side, false)
            case .mug: return (h + SIMD2(0, -0.16), 0, false)
            case .pen: return (h + SIMD2(0.04 * side, -0.22), 0.5 * side, false)
            case .bell: return (h + SIMD2(0, -0.26), 0, false)
            case .magnifier: return (h + SIMD2(0.1 * side, -0.28), 0.4 * side, false)
            default: return (h + SIMD2(0, -0.24), 0, false)
            }
        case .sip:
            return (joints[1].hand + SIMD2(-0.06, -0.14), 0, false)
        default:
            return nil
        }
    }

    /// Authoring frame: a body about 1 R across and 1.8 R tall, centroid at the origin, y down;
    /// the engine scales targets to the real silhouette. Shoulder angles are elevation above the
    /// side (0 = the side at centroid height, 1.57 = the top), and the shoulder itself sits on
    /// the outline at about (cos θ, −sin θ). Gestures are nubs: the hand is `nubLength` beyond
    /// the shoulder, straight out or along a given direction, so the arm reads as a small
    /// triangle on the body. Only props pull a hand further, into a thin tentacle; no hand
    /// ends more than 1.6 R from the centroid.
    public static func keyframe(_ pose: ArmPose, side: Double) -> Target {
        let hidden = Target.hidden(side: side)
        let m = side  // mirror x for the left arm
        func sym(_ hand: SIMD2<Double>, _ elbow: SIMD2<Double>, angle: Double = 0.35, shape: HandShape = .open) -> Target {
            Target(shoulderAngle: side > 0 ? -angle : .pi + angle, elbow: SIMD2(elbow.x * m, elbow.y), hand: SIMD2(hand.x * m, hand.y), reach: 1, shape: shape)
        }
        /// A nub at elevation `angle`, pointing along `dir` (unit, right-side frame; default
        /// straight out of the body), `length` long.
        func nub(angle: Double, dir: SIMD2<Double>? = nil, length: Double = nubLength, shape: HandShape = .open) -> Target {
            let shoulder = SIMD2(cos(angle), -sin(angle))
            let d = dir.map { simd_normalize($0) } ?? shoulder
            return sym(shoulder + d * length, shoulder + d * (length * 0.5), angle: angle, shape: shape)
        }
        switch pose {
        case .hidden:
            return hidden
        case .holdFront(let p):
            // Both arms come in from the lower sides to hold the prop in front of the mouth.
            let lift = p.isFile ? -0.4 * bites(p) : 0
            return sym(SIMD2(0.34, 0.56 + lift), SIMD2(0.84, 0.36 + lift * 0.5), angle: 0.15, shape: .grip)
        case .holdHigh:
            return sym(SIMD2(0.44, -1.0), SIMD2(0.74, -0.88), angle: 0.75, shape: .grip)
        case .hug(.some):
            // Arms cross in front: the right hand reaches to the left side and vice versa.
            return side > 0
                ? Target(shoulderAngle: -0.25, elbow: SIMD2(0.7, 0.42), hand: SIMD2(-0.18, 0.34), reach: 1, shape: .grip)
                : Target(shoulderAngle: .pi + 0.25, elbow: SIMD2(-0.7, 0.48), hand: SIMD2(0.2, 0.46), reach: 1, shape: .grip)
        case .hug(.none):
            // A self-hug: both arms wrap round the belly, hands overlapping in front.
            return side > 0
                ? Target(shoulderAngle: -0.2, elbow: SIMD2(0.75, 0.2), hand: SIMD2(-0.4, 0.14), reach: 1, shape: .grip)
                : Target(shoulderAngle: .pi + 0.2, elbow: SIMD2(-0.75, 0.28), hand: SIMD2(0.36, 0.26), reach: 1, shape: .grip)
        case .holdSide(_, let s):
            guard s == side else { return hidden }
            return sym(SIMD2(0.6, -0.12), SIMD2(0.9, -0.08), angle: 0.3, shape: .grip)
        case .wave(let s):
            // A nub on the upper side, swaying from the tip.
            guard s == side else { return hidden }
            return nub(angle: 0.75)
        case .thumbsUp(let s):
            // A nub out to the side at eye height; the thumb is a smaller nub on top of it.
            guard s == side else { return hidden }
            return nub(angle: 0.6, shape: .thumbsUp)
        case .cheer:
            // Two nubs on the top sides, pointing up and out, pumping.
            return nub(angle: 0.7, dir: SIMD2(0.75, -1), shape: .fist)
        case .rubEyes:
            // Flat pseudopods from the sides lying over the eyes.
            return nub(angle: 0.3, dir: SIMD2(-1, 0), length: 0.8, shape: .fist)
        case .scratchHead:
            // One nub near the crown, wiggling.
            guard side > 0 else { return hidden }
            return nub(angle: 1.15, length: 0.28)
        case .facepalm:
            // One flat pseudopod from the side, long enough to lie over the eye.
            guard side > 0 else { return hidden }
            return nub(angle: 0.3, dir: SIMD2(-1, 0), length: 0.8)
        case .cover:
            return nub(angle: 0.3, dir: SIMD2(-1, 0), length: 0.8)
        case .point(let d):
            // A nub along the pointing direction, from the outline point facing that way.
            let dir = TraitRig.unit(d)
            guard (dir.x >= 0) == (side > 0) else { return hidden }
            let angle = max(0.1, min(1.3, atan2(-dir.y, abs(dir.x))))
            return nub(angle: angle, dir: SIMD2(abs(dir.x), dir.y), shape: .point)
        case .sip:
            guard side > 0 else { return hidden }
            return sym(SIMD2(0.34, 0.32), SIMD2(0.82, 0.22), angle: 0.2, shape: .grip)
        }
    }

    private static func bites(_ p: Prop) -> Double {
        if case .file(_, let b) = p { return b }
        return 0
    }
}
