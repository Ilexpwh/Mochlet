import Foundation

/// The 28 sounds. Recipes live in SoundRecipe.swift; `SoundEngine` (SlimeKitAudio) plays them.
public enum SlimeSound: String, Sendable, CaseIterable, Codable {
    case greet, blip, question, hover, slap, annoyed, splat, plip, merge, dizzy
    case jump, land, finish, error, waiting, approve, work, think, chew, gulp
    case pinch, absorb, listenOn, listenOff, sleep, love, pop, proud

    /// Minimum time between two plays of the same sound, in seconds.
    public var minInterval: Double {
        switch self {
        case .plip: return 0.06
        case .chew: return 0.18
        case .hover: return 0.4
        case .blip: return 0.08
        case .land: return 0.12
        default: return 0.05
        }
    }

    public var baseGain: Double {
        switch self {
        case .plip, .chew, .blip, .hover: return 0.6
        case .slap, .splat: return 0.9
        case .greet, .finish, .proud: return 1.0
        default: return 0.8
        }
    }
}

/// A sound request from the engine, drained by the host each frame.
public struct SoundCue: Sendable, Equatable {
    public var sound: SlimeSound
    public var rate: Double
    public var gain: Double

    public init(_ sound: SlimeSound, rate: Double = 1, gain: Double = 1) {
        self.sound = sound
        self.rate = rate
        self.gain = gain
    }
}
