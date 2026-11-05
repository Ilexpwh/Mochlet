import Foundation

public enum Waveform: String, Sendable, Codable, CaseIterable {
    case sine, triangle, square, saw, noise
}

/// One voice of a sound: a gliding oscillator (or noise) with an envelope and an optional
/// gliding low-pass filter. All times in seconds, frequencies in Hz.
public struct SoundLayer: Sendable, Codable, Equatable {
    public var wave: Waveform = .sine
    /// Start frequency.
    public var f0: Double = 440
    /// End frequency (exponential glide over `duration`); nil keeps `f0`.
    public var f1: Double? = nil
    public var duration: Double = 0.1
    public var gain: Double = 1
    /// Linear fade-in.
    public var attack: Double = 0.004
    /// Exponential decay rate (1/s) applied over the whole layer: amp *= exp(-decay·t).
    public var decay: Double = 8
    /// Linear fade-out length at the end of the layer.
    public var release: Double = 0.02
    /// Start offset inside the sound.
    public var delay: Double = 0
    public var vibratoRate: Double = 0
    /// Vibrato depth in Hz.
    public var vibratoDepth: Double = 0
    /// Gain of an added second harmonic (relative to the fundamental).
    public var harmonic: Double = 0
    /// Two-pole low-pass cutoff glide; nil = no filter.
    public var lowpassStart: Double? = nil
    public var lowpassEnd: Double? = nil

    public init(_ wave: Waveform = .sine, f0: Double, f1: Double? = nil, duration: Double, gain: Double = 1,
                attack: Double = 0.004, decay: Double = 8, release: Double = 0.02, delay: Double = 0,
                vibratoRate: Double = 0, vibratoDepth: Double = 0, harmonic: Double = 0,
                lowpass: (Double, Double)? = nil) {
        self.wave = wave
        self.f0 = f0
        self.f1 = f1
        self.duration = duration
        self.gain = gain
        self.attack = attack
        self.decay = decay
        self.release = release
        self.delay = delay
        self.vibratoRate = vibratoRate
        self.vibratoDepth = vibratoDepth
        self.harmonic = harmonic
        self.lowpassStart = lowpass?.0
        self.lowpassEnd = lowpass?.1
    }

    public var end: Double { delay + duration }
}

/// A complete sound as data: layers mixed, soft-limited and normalised by `SoundSynth`.
public struct SoundRecipe: Sendable, Codable, Equatable {
    public var layers: [SoundLayer]
    /// Peak level after normalisation, in dBFS.
    public var peakDB: Double = -6

    public init(_ layers: [SoundLayer], peakDB: Double = -6) {
        self.layers = layers
        self.peakDB = peakDB
    }

    public var duration: Double { layers.map(\.end).max() ?? 0 }

    // MARK: - The 28 recipes

    public static func recipe(for sound: SlimeSound) -> SoundRecipe {
        typealias L = SoundLayer
        switch sound {
        case .greet:
            return SoundRecipe([L(f0: 660, f1: 880, duration: 0.12, decay: 6),
                                L(f0: 990, duration: 0.16, gain: 0.8, decay: 8, delay: 0.11, vibratoRate: 5, vibratoDepth: 12)])
        case .blip:
            return SoundRecipe([L(f0: 900, f1: 1300, duration: 0.05, decay: 30)])
        case .question:
            return SoundRecipe([L(.triangle, f0: 520, f1: 820, duration: 0.16, decay: 7, harmonic: 0.3)])
        case .hover:
            return SoundRecipe([L(f0: 1100, f1: 1250, duration: 0.045, gain: 0.5, decay: 35)])
        case .slap:
            return SoundRecipe([L(.noise, f0: 0, duration: 0.07, gain: 0.8, decay: 25, lowpass: (2200, 400)),
                                L(f0: 170, f1: 80, duration: 0.09, gain: 0.7, decay: 20)])
        case .annoyed:
            return SoundRecipe([L(.square, f0: 290, f1: 230, duration: 0.11, gain: 0.5, decay: 10, lowpass: (1800, 900)),
                                L(.square, f0: 250, f1: 190, duration: 0.13, gain: 0.5, decay: 10, delay: 0.12, lowpass: (1600, 800))])
        case .splat:
            return SoundRecipe([L(.noise, f0: 0, duration: 0.12, gain: 0.9, decay: 18, lowpass: (1400, 300)),
                                L(f0: 200, f1: 60, duration: 0.14, gain: 0.8, decay: 14)])
        case .plip:
            return SoundRecipe([L(f0: 1500, f1: 650, duration: 0.045, decay: 32)])
        case .merge:
            return SoundRecipe([L(f0: 300, f1: 620, duration: 0.14, decay: 9),
                                L(f0: 450, f1: 920, duration: 0.14, gain: 0.7, decay: 9, delay: 0.05)])
        case .dizzy:
            return SoundRecipe([L(f0: 600, f1: 380, duration: 0.9, gain: 0.7, decay: 2.5, vibratoRate: 8, vibratoDepth: 40),
                                L(f0: 606, f1: 384, duration: 0.9, gain: 0.5, decay: 2.5, vibratoRate: 8, vibratoDepth: 40)])
        case .jump:
            return SoundRecipe([L(f0: 300, f1: 720, duration: 0.1, decay: 12)])
        case .land:
            return SoundRecipe([L(f0: 160, f1: 75, duration: 0.09, decay: 22),
                                L(.noise, f0: 0, duration: 0.05, gain: 0.4, decay: 30, lowpass: (900, 200))])
        case .finish:
            return SoundRecipe([L(f0: 587, duration: 0.42, decay: 5, harmonic: 0.25),
                                L(f0: 740, duration: 0.42, decay: 5, delay: 0.09, harmonic: 0.25),
                                L(f0: 880, duration: 0.42, decay: 5, delay: 0.18, harmonic: 0.25)])
        case .error:
            return SoundRecipe([L(.square, f0: 220, f1: 180, duration: 0.18, gain: 0.55, decay: 7, lowpass: (1500, 700)),
                                L(.square, f0: 165, f1: 140, duration: 0.22, gain: 0.55, decay: 7, delay: 0.2, lowpass: (1200, 600))])
        case .waiting:
            return SoundRecipe([L(f0: 880, duration: 0.08, decay: 18),
                                L(f0: 880, duration: 0.08, decay: 18, delay: 0.13)])
        case .approve:
            return SoundRecipe([L(f0: 660, f1: 990, duration: 0.12, decay: 7),
                                L(f0: 1320, duration: 0.12, gain: 0.7, decay: 9, delay: 0.1)])
        case .work:
            return SoundRecipe([L(f0: 440, duration: 0.07, gain: 0.6, decay: 15),
                                L(f0: 554, duration: 0.07, gain: 0.6, decay: 15, delay: 0.08),
                                L(f0: 659, duration: 0.1, gain: 0.6, decay: 15, delay: 0.16)])
        case .think:
            return SoundRecipe([L(f0: 392, f1: 440, duration: 0.32, gain: 0.6, decay: 5, vibratoRate: 4, vibratoDepth: 6, harmonic: 0.2)])
        case .chew:
            return SoundRecipe([L(.noise, f0: 0, duration: 0.07, gain: 0.7, decay: 25, lowpass: (900, 300)),
                                L(f0: 140, f1: 95, duration: 0.06, gain: 0.6, decay: 25)])
        case .gulp:
            return SoundRecipe([L(f0: 380, f1: 130, duration: 0.17, decay: 8),
                                L(f0: 220, f1: 90, duration: 0.2, gain: 0.8, decay: 8, delay: 0.09)])
        case .pinch:
            return SoundRecipe([L(f0: 900, f1: 400, duration: 0.08, decay: 16),
                                L(f0: 1300, f1: 500, duration: 0.07, gain: 0.6, decay: 18, delay: 0.04)])
        case .absorb:
            return SoundRecipe([L(f0: 700, f1: 250, duration: 0.25, decay: 7),
                                L(.noise, f0: 0, duration: 0.12, gain: 0.4, decay: 15, lowpass: (600, 150))])
        case .listenOn:
            return SoundRecipe([L(f0: 520, f1: 780, duration: 0.1, decay: 10),
                                L(f0: 1040, duration: 0.08, gain: 0.7, decay: 14, delay: 0.1)])
        case .listenOff:
            return SoundRecipe([L(f0: 780, f1: 520, duration: 0.1, decay: 10),
                                L(f0: 390, duration: 0.1, gain: 0.7, decay: 12, delay: 0.1)])
        case .sleep:
            return SoundRecipe([L(f0: 440, f1: 330, duration: 0.5, gain: 0.6, decay: 4, vibratoRate: 2, vibratoDepth: 4),
                                L(f0: 330, f1: 262, duration: 0.5, gain: 0.5, decay: 4, delay: 0.4)])
        case .love:
            return SoundRecipe([L(f0: 784, duration: 0.12, decay: 8),
                                L(f0: 988, duration: 0.12, decay: 8, delay: 0.1),
                                L(f0: 1175, duration: 0.28, decay: 5, delay: 0.2, vibratoRate: 5, vibratoDepth: 8)])
        case .pop:
            return SoundRecipe([L(f0: 500, f1: 1050, duration: 0.04, decay: 30),
                                L(.noise, f0: 0, duration: 0.025, gain: 0.5, decay: 40, lowpass: (3000, 800))])
        case .proud:
            return SoundRecipe([L(f0: 784, duration: 0.3, decay: 6, harmonic: 0.2),
                                L(f0: 988, duration: 0.3, decay: 6, delay: 0.08, harmonic: 0.2),
                                L(f0: 1175, duration: 0.3, decay: 6, delay: 0.16, harmonic: 0.2),
                                L(f0: 1568, duration: 0.4, decay: 5, delay: 0.24, harmonic: 0.2)])
        }
    }

    public static var table: [SlimeSound: SoundRecipe] {
        Dictionary(uniqueKeysWithValues: SlimeSound.allCases.map { ($0, recipe(for: $0)) })
    }
}
