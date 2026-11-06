import Foundation
import simd

public struct EyeFrame: Sendable, Equatable {
    /// -1 left, +1 right (screen space).
    public var side: Double
    public var shape: EyeShape
    /// World position in R units (y down, floor at 0).
    public var center: SIMD2<Double>
    /// Half-width in R before foreshortening.
    public var radius: Double
    public var aspect: Double
    public var foreshorten: SIMD2<Double>
    /// 1 open, 0 closed (from blinks).
    public var openness: Double
    public var visible: Bool
    public var scale: Double
}

public struct MouthFrame: Sendable, Equatable {
    public var shape: MouthShape
    public var open: Double
    public var center: SIMD2<Double>
    public var foreshorten: SIMD2<Double>
    public var visible: Bool
}

public enum AccessoryKind: String, Sendable, Codable, Equatable {
    case question, exclamation, dots, badge, micBars, recDot
    /// A music note (humming) and the anime's anger mark on the body.
    case note, anger

    /// Marks that can grow out of the body as slime (`GlyphStyle.grown`).
    public var canGrow: Bool {
        switch self {
        case .question, .exclamation, .note: return true
        default: return false
        }
    }
}

public struct AccessoryFrame: Sendable, Equatable {
    public var kind: AccessoryKind
    /// World anchor in R units.
    public var anchor: SIMD2<Double>
    /// 0…1 pop-in (eased), then 1; falls back to 0 while disappearing.
    public var pop: Double
    /// Seconds since the accessory appeared.
    public var phase: Double
    /// Mic levels for `micBars` (5 values 0…1).
    public var levels: [Double]
    /// The glyph pops up above the head as a piece of jelly (`GlyphStyle.grown`); false draws the
    /// speech-bubble style.
    public var grown: Bool = false
    /// Direction the glyph rose in (unit, world space); it leans with it.
    public var direction: SIMD2<Double> = SIMD2(0, -1)
    /// For a grown glyph: the one small bead sitting on the head under the mark (world, R units),
    /// as in the anime's "!" moment. Nil for bubble-style accessories.
    public var bead: SIMD2<Double>? = nil
    /// Radius of the bead in R units (already scaled by the pop).
    public var beadRadius: Double = 0
}

public struct Particle: Sendable, Equatable {
    public enum Kind: String, Sendable, Codable {
        case sparkle, heart, star, zzz, drop, dust
        /// Surface effects: a flame tongue, an electric arc, a glint of light, a honey drip, a soap bubble.
        case wisp, spark, glint, drip, bubble
        /// A fleck of file falling from the mouth while eating.
        case crumb
        /// A puff of steam rising off a puffed-up (angry) slime.
        case steam
    }

    public var kind: Kind
    public var position: SIMD2<Double>
    public var velocity: SIMD2<Double>
    public var age: Double
    public var life: Double
    public var size: Double
    public var spin: Double
    public var seed: Double

    public var progress: Double { clamp(age / max(life, 1e-6), 0, 1) }
}

public struct Blob: Sendable, Equatable {
    public var position: SIMD2<Double>
    public var radius: Double
    /// Elongation along `heading` (1 = circle); the cross axis shrinks by the inverse.
    public var stretch: Double
    public var heading: Double
    /// Droplets get their own gradient and highlight; body features (ears, tails) share the body shading.
    public var shaded: Bool

    public init(position: SIMD2<Double>, radius: Double, stretch: Double = 1, heading: Double = 0, shaded: Bool = true) {
        self.position = position
        self.radius = radius
        self.stretch = stretch
        self.heading = heading
        self.shaded = shaded
    }
}

/// Everything the renderer needs for one slime, in R units (floor at y = 0, y down).
public struct SlimeFrame: Sendable, Equatable {
    public var profile: SlimeProfileKind
    public var state: SlimeState
    public var emote: SlimeEmote?
    public var ring: [SIMD2<Double>]
    public var root: SIMD2<Double>
    public var body: BodyFrame
    public var contactWidth: Double
    public var airborne: Bool
    public var eyes: [EyeFrame]
    public var mouth: MouthFrame
    public var blush: Double
    public var blushCenters: [SIMD2<Double>]
    public var blushForeshorten: [SIMD2<Double>]
    public var core: SIMD2<Double>
    public var coreBoost: Double
    public var gaze: SIMD2<Double>
    public var highlightShift: SIMD2<Double>
    public var tint: StateTint
    public var accessories: [AccessoryFrame]
    public var particles: [Particle]
    public var blobs: [Blob]
    public var opacity: Double
    public var faceOpacity: Double
    public var glowBoost: Double
    public var sizeScale: Double
    public var ghostStretch: SIMD2<Double>
    public var ghostHeading: Double
    /// Solid species features (horns, wings, inner ears…) placed on the body.
    public var traits: [TraitFrame] = []
    /// The clothes actually worn this frame: the chosen outfit plus any situational piece.
    public var outfit = SlimeOutfit()
    /// Engine time of the frame (surface shimmer, twinkle).
    public var time: Double = 0
    /// Pseudopod arms, when a pose is active (empty on the idle path).
    public var arms: [ArmFrame] = []
    /// Props in the hands.
    public var props: [PropFrame] = []
    /// Pages seen inside the jelly while digesting.
    public var innerItems: [InnerItem] = []
    /// Where the eating timeline is, while chewing with arms.
    public var chewPhase: ChewPhase? = nil

    /// Topmost y of the ring (most negative).
    public var topY: Double { ring.map(\.y).min() ?? 0 }
    public var maxX: Double { ring.map(\.x).max() ?? 0 }
    public var minX: Double { ring.map(\.x).min() ?? 0 }
}
