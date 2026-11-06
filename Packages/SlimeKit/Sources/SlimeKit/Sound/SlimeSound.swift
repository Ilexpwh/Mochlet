import Foundation

/// The 44 sounds. Recipes live in SoundRecipe.swift (one set per `SoundPack`); `SoundEngine`
/// (SlimeKitAudio) plays them.
public enum SlimeSound: String, Sendable, CaseIterable, Codable {
    case greet, blip, question, hover, slap, annoyed, splat, plip, merge, dizzy
    case jump, land, finish, error, waiting, approve, work, think, chew, gulp
    case pinch, absorb, listenOn, listenOff, sleep, love, pop, proud
    /// Character 2: squishy foley and tiny voice squeaks in the spirit of the anime's "puni" sounds.
    /// squish/wobble (jelly), hamu (bite), gokun (big gulp), kyu/pyu/mu (squeaks: bright, surprised,
    /// sleepy), pyon (hop), puni (poke), fuwa (wings, floating), pika (sparkle), note (humming),
    /// rustle (paper), ring (phone), sip, stretch.
    case squish, wobble, hamu, gokun, kyu, pyu, mu, pyon, puni, fuwa, pika, note, rustle, ring, sip, stretch

    /// Minimum time between two plays of the same sound, in seconds.
    public var minInterval: Double {
        switch self {
        case .plip: return 0.06
        case .chew, .hamu: return 0.18
        case .hover: return 0.4
        case .blip, .puni: return 0.08
        case .land, .squish: return 0.12
        case .pyon: return 0.1
        case .rustle, .wobble: return 0.3
        case .ring: return 0.5
        default: return 0.05
        }
    }

    public var baseGain: Double {
        switch self {
        case .plip, .chew, .blip, .hover, .puni, .hamu: return 0.6
        case .slap, .splat, .squish: return 0.9
        case .greet, .finish, .proud, .pika: return 1.0
        case .rustle, .fuwa, .sip: return 0.7
        default: return 0.8
        }
    }
}

/// A set of recipes for every sound: the squishy `puni` pack (default) or the 2.0 `classic` chimes.
public enum SoundPack: String, Sendable, Codable, CaseIterable {
    case puni, classic

    public var label: String {
        switch self {
        case .puni: return "Puni (squish + squeaks)"
        case .classic: return "Classic chimes"
        }
    }

    /// Sounds that are the slime's voice in this pack (muted or swapped for foley when voice is off).
    public var voiceSounds: Set<SlimeSound> {
        switch self {
        case .puni:
            return [.greet, .question, .annoyed, .finish, .error, .waiting, .approve, .think, .listenOn, .listenOff,
                    .sleep, .love, .proud, .kyu, .pyu, .mu, .stretch, .note]
        case .classic:
            return [.kyu, .pyu, .mu]
        }
    }

    /// What plays instead of a voice sound when voice is off; nil keeps quiet.
    public func foleyFallback(for s: SlimeSound) -> SlimeSound? {
        switch s {
        case .greet, .love: return .pyon
        case .finish, .proud: return .pika
        case .approve, .stretch: return .pop
        case .question: return .puni
        case .error, .annoyed: return .squish
        case .waiting, .listenOn, .listenOff: return .blip
        default: return nil
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
