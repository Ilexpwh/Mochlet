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
    /// Decaying pitch wobble (jelly resonance): rate in Hz, depth as a fraction of the pitch, decay 1/s.
    public var wobbleRate: Double = 0
    public var wobbleDepth: Double = 0
    public var wobbleDecay: Double = 0
    /// Resonant peaks in Hz for a "kyu / pyu / mu" squeak (parallel two-pole resonators).
    public var formants: [Double] = []
    /// Gliding band-pass centre; nil = none.
    public var bandpassStart: Double? = nil
    public var bandpassEnd: Double? = nil
    /// Random mini-pops scattered over the first `bubbleSpread` of the layer.
    public var bubbles: Int = 0
    public var bubbleSpread: Double = 1

    public init(_ wave: Waveform = .sine, f0: Double, f1: Double? = nil, duration: Double, gain: Double = 1,
                attack: Double = 0.004, decay: Double = 8, release: Double = 0.02, delay: Double = 0,
                vibratoRate: Double = 0, vibratoDepth: Double = 0, harmonic: Double = 0,
                lowpass: (Double, Double)? = nil, wobble: (rate: Double, depth: Double, decay: Double)? = nil,
                formants: [Double] = [], bandpass: (Double, Double)? = nil, bubbles: Int = 0, bubbleSpread: Double = 1) {
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
        self.wobbleRate = wobble?.rate ?? 0
        self.wobbleDepth = wobble?.depth ?? 0
        self.wobbleDecay = wobble?.decay ?? 0
        self.formants = formants
        self.bandpassStart = bandpass?.0
        self.bandpassEnd = bandpass?.1
        self.bubbles = bubbles
        self.bubbleSpread = bubbleSpread
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

    // MARK: - Packs

    public static func recipe(for sound: SlimeSound, in pack: SoundPack = .puni) -> SoundRecipe {
        switch pack {
        case .puni: return puni(sound)
        case .classic: return classic(sound)
        }
    }

    public static func table(for pack: SoundPack) -> [SlimeSound: SoundRecipe] {
        Dictionary(uniqueKeysWithValues: SlimeSound.allCases.map { ($0, recipe(for: $0, in: pack)) })
    }

    // MARK: - Classic: the 2.0 chimes, plus the Character 2 foley it never had

    static func classic(_ sound: SlimeSound) -> SoundRecipe {
        typealias L = SoundLayer
        switch sound {
        // Chimes stand in for the three squeaks; everything else new is foley shared with puni.
        case .kyu: return SoundRecipe([L(f0: 660, f1: 990, duration: 0.12, decay: 8)])
        case .pyu: return SoundRecipe([L(f0: 880, f1: 1320, duration: 0.1, decay: 10)])
        case .mu: return SoundRecipe([L(f0: 330, f1: 262, duration: 0.3, gain: 0.7, decay: 5)])
        case .squish, .wobble, .hamu, .gokun, .pyon, .puni, .fuwa, .pika, .note, .rustle, .ring, .sip, .stretch:
            return puni(sound)
        default:
            return classicChime(sound)
        }
    }

    private static func classicChime(_ sound: SlimeSound) -> SoundRecipe {
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
        default:
            return puni(sound)
        }
    }

    // MARK: - Puni: squishy foley and tiny squeaks (own synthesis; nothing sampled)

    /// Resonant peaks for the three squeak vowels.
    static let kyu: [Double] = [800, 1250, 2600]
    static let pyu: [Double] = [700, 1800, 2800]
    static let mu: [Double] = [350, 800, 1400]
    static let jelly: (rate: Double, depth: Double, decay: Double) = (22, 0.3, 25)

    static func puni(_ sound: SlimeSound) -> SoundRecipe {
        typealias L = SoundLayer
        /// A wet squish: low-passed noise over a dropping, wobbling sine.
        func squish(_ dur: Double, f0: Double = 180, f1: Double = 70, gain: Double = 0.8, delay: Double = 0) -> [L] {
            [L(.noise, f0: 0, duration: dur, gain: gain, decay: 20, delay: delay, lowpass: (1800, 250)),
             L(f0: f0, f1: f1, duration: dur * 1.1, gain: gain, decay: 18, delay: delay, wobble: jelly)]
        }
        /// A squeak: a gliding sine through fixed formants, a touch of second harmonic.
        func voice(_ f0: Double, _ f1: Double, _ dur: Double, _ formants: [Double], gain: Double = 1, delay: Double = 0,
                   vib: (Double, Double) = (0, 0), decay: Double = 6, bubbles: Int = 0) -> L {
            L(f0: f0, f1: f1, duration: dur, gain: gain, decay: decay, delay: delay, vibratoRate: vib.0, vibratoDepth: vib.1,
              harmonic: 0.35, wobble: (18, 0.06, 20), formants: formants, bubbles: bubbles, bubbleSpread: 0.6)
        }
        switch sound {
        case .greet:
            return SoundRecipe([L(.noise, f0: 0, duration: 0.04, gain: 0.3, decay: 40, lowpass: (2200, 500)),
                                voice(520, 780, 0.2, kyu, delay: 0.03, vib: (6, 10))])
        case .blip:
            return SoundRecipe([L(f0: 700, f1: 1100, duration: 0.045, decay: 30, wobble: (40, 0.15, 40)),
                                L(.noise, f0: 0, duration: 0.02, gain: 0.3, decay: 50, lowpass: (2500, 600))])
        case .question:
            return SoundRecipe([voice(460, 820, 0.22, kyu, bubbles: 1)])
        case .hover:
            return SoundRecipe([L(f0: 900, f1: 1000, duration: 0.04, gain: 0.45, decay: 35, wobble: (30, 0.1, 40))])
        case .slap:
            return SoundRecipe(squish(0.09))
        case .annoyed:
            return SoundRecipe([voice(240, 200, 0.12, mu, gain: 0.7), voice(220, 180, 0.14, mu, gain: 0.7, delay: 0.13)])
        case .splat:
            return SoundRecipe([L(.noise, f0: 0, duration: 0.13, gain: 0.9, decay: 16, lowpass: (1800, 250)),
                                L(f0: 180, f1: 60, duration: 0.16, gain: 0.8, decay: 13, wobble: jelly, bubbles: 2, bubbleSpread: 0.8)])
        case .plip:
            return SoundRecipe([L(f0: 1400, f1: 650, duration: 0.05, decay: 30, bubbles: 1, bubbleSpread: 0.5)])
        case .merge:
            return SoundRecipe(squish(0.12, f0: 240, f1: 520) + squish(0.12, f0: 360, f1: 800, gain: 0.6, delay: 0.06))
        case .dizzy:
            return SoundRecipe([L(f0: 240, duration: 0.5, gain: 0.75, decay: 2.5, vibratoRate: 6, vibratoDepth: 14, wobble: (8, 0.18, 4)),
                                L(f0: 362, duration: 0.5, gain: 0.4, decay: 2.5, delay: 0.05, wobble: (8, 0.18, 4))])
        case .jump, .pyon:
            return SoundRecipe([L(f0: 420, f1: 980, duration: 0.09, decay: 12, wobble: (26, 0.12, 30), bubbles: 1, bubbleSpread: 0.5)])
        case .land:
            return SoundRecipe([L(f0: 160, f1: 70, duration: 0.1, decay: 20, wobble: jelly),
                                L(.noise, f0: 0, duration: 0.06, gain: 0.5, decay: 28, lowpass: (1200, 200))])
        case .finish:
            return SoundRecipe([L(f0: 1320, duration: 0.12, decay: 10, harmonic: 0.3),
                                L(f0: 1760, duration: 0.16, decay: 9, delay: 0.08, harmonic: 0.3),
                                voice(620, 880, 0.3, kyu, delay: 0.18, vib: (5, 10))])
        case .error:
            return SoundRecipe([voice(230, 170, 0.3, mu, gain: 0.8), voice(180, 140, 0.3, mu, gain: 0.7, delay: 0.28)])
        case .waiting:
            return SoundRecipe([voice(760, 1050, 0.09, pyu), voice(760, 1050, 0.09, pyu, delay: 0.16)])
        case .approve:
            return SoundRecipe([voice(700, 1150, 0.14, pyu), L(f0: 1400, f1: 1900, duration: 0.05, gain: 0.5, decay: 20, delay: 0.1)])
        case .work:
            return SoundRecipe([L(f0: 300, f1: 260, duration: 0.05, gain: 0.6, decay: 25, wobble: (30, 0.15, 40)),
                                L(f0: 340, f1: 300, duration: 0.05, gain: 0.6, decay: 25, delay: 0.09, wobble: (30, 0.15, 40)),
                                L(f0: 380, f1: 330, duration: 0.07, gain: 0.6, decay: 25, delay: 0.18, wobble: (30, 0.15, 40))])
        case .think:
            return SoundRecipe([voice(300, 330, 0.38, mu, gain: 0.7, vib: (4, 5), decay: 4)])
        case .chew, .hamu:
            return SoundRecipe([L(.noise, f0: 0, duration: 0.08, gain: 0.7, decay: 22, lowpass: (900, 250)),
                                L(f0: 150, f1: 90, duration: 0.08, gain: 0.8, decay: 20, wobble: (24, 0.3, 25), bubbles: 1, bubbleSpread: 0.6)])
        case .gulp, .gokun:
            return SoundRecipe([L(f0: 300, f1: 110, duration: 0.22, decay: 8, wobble: (14, 0.15, 12), bubbles: 2, bubbleSpread: 0.9),
                                L(.noise, f0: 0, duration: 0.08, gain: 0.3, decay: 20, delay: 0.1, lowpass: (700, 150))])
        case .pinch:
            return SoundRecipe([L(f0: 500, f1: 950, duration: 0.09, decay: 14, wobble: (28, 0.2, 30)),
                                L(.noise, f0: 0, duration: 0.05, gain: 0.35, decay: 30, lowpass: (2000, 500))])
        case .absorb:
            return SoundRecipe([L(.noise, f0: 0, duration: 0.22, gain: 0.5, decay: 6, lowpass: (300, 1400)),
                                L(f0: 230, f1: 620, duration: 0.26, decay: 7, wobble: (16, 0.12, 10), bubbles: 3)])
        case .listenOn:
            return SoundRecipe([voice(540, 820, 0.11, pyu), L(.noise, f0: 0, duration: 0.04, gain: 0.3, decay: 40, lowpass: (1800, 400))])
        case .listenOff:
            return SoundRecipe([voice(820, 540, 0.11, pyu, gain: 0.9)])
        case .sleep:
            return SoundRecipe([voice(400, 300, 0.5, mu, gain: 0.65, vib: (2, 5), decay: 4),
                                voice(310, 250, 0.45, mu, gain: 0.5, delay: 0.4, decay: 4)])
        case .love:
            return SoundRecipe([voice(620, 920, 0.16, kyu), voice(920, 700, 0.3, kyu, gain: 0.9, delay: 0.15, vib: (5, 9))])
        case .pop:
            return SoundRecipe([L(f0: 600, f1: 1250, duration: 0.035, decay: 32),
                                L(.noise, f0: 0, duration: 0.02, gain: 0.5, decay: 45, lowpass: (3000, 800))])
        case .proud:
            return SoundRecipe([L(f0: 1320, duration: 0.1, decay: 10, harmonic: 0.3),
                                L(f0: 1760, duration: 0.1, decay: 10, delay: 0.09, harmonic: 0.3),
                                L(f0: 2093, duration: 0.12, decay: 9, delay: 0.18, harmonic: 0.3),
                                voice(660, 990, 0.34, kyu, delay: 0.26, vib: (5, 10))])
        case .squish:
            return SoundRecipe(squish(0.09))
        case .wobble:
            return SoundRecipe([L(f0: 240, duration: 0.5, gain: 0.8, decay: 3, wobble: (8, 0.18, 4)),
                                L(f0: 480, duration: 0.5, gain: 0.3, decay: 3, wobble: (8, 0.18, 4))])
        case .kyu:
            return SoundRecipe([voice(520, 760, 0.18, kyu, vib: (6, 10))])
        case .pyu:
            return SoundRecipe([voice(760, 1150, 0.12, pyu)])
        case .mu:
            return SoundRecipe([voice(320, 260, 0.35, mu, gain: 0.7, vib: (3, 5), decay: 4)])
        case .puni:
            return SoundRecipe([L(f0: 520, f1: 380, duration: 0.06, decay: 22, wobble: (32, 0.25, 40)),
                                L(.noise, f0: 0, duration: 0.035, gain: 0.35, decay: 40, lowpass: (1600, 400))])
        case .fuwa:
            return SoundRecipe([L(.noise, f0: 0, duration: 0.18, gain: 0.6, decay: 10, lowpass: (600, 1400)),
                                L(.noise, f0: 0, duration: 0.18, gain: 0.5, decay: 10, delay: 0.12, lowpass: (1400, 500))])
        case .pika:
            return SoundRecipe([L(f0: 1760, duration: 0.08, decay: 14, harmonic: 0.4),
                                L(f0: 2349, duration: 0.1, decay: 12, delay: 0.06, harmonic: 0.4),
                                L(f0: 2637, duration: 0.14, decay: 10, delay: 0.12, harmonic: 0.3)])
        case .note:
            return SoundRecipe([L(f0: 784, duration: 0.22, decay: 6, vibratoRate: 5, vibratoDepth: 6, harmonic: 0.3),
                                L(f0: 988, duration: 0.24, decay: 6, delay: 0.12, vibratoRate: 5, vibratoDepth: 6, harmonic: 0.3)])
        case .rustle:
            return SoundRecipe([L(.noise, f0: 0, duration: 0.12, gain: 0.7, decay: 14, bandpass: (2500, 1600)),
                                L(.noise, f0: 0, duration: 0.08, gain: 0.5, decay: 18, delay: 0.07, bandpass: (3200, 1800))])
        case .ring:
            return SoundRecipe([L(f0: 1000, duration: 0.08, decay: 10, harmonic: 0.5),
                                L(f0: 1300, duration: 0.08, decay: 10, delay: 0.08, harmonic: 0.5),
                                L(f0: 1000, duration: 0.08, decay: 10, delay: 0.18, harmonic: 0.5),
                                L(f0: 1300, duration: 0.08, decay: 10, delay: 0.26, harmonic: 0.5)])
        case .sip:
            return SoundRecipe([L(.noise, f0: 0, duration: 0.16, gain: 0.5, decay: 8, lowpass: (400, 1600)),
                                L(f0: 280, f1: 520, duration: 0.18, decay: 8, wobble: (12, 0.1, 10), bubbles: 2)])
        case .stretch:
            return SoundRecipe([voice(260, 420, 0.45, mu, gain: 0.7, vib: (3, 4), decay: 3),
                                L(f0: 600, f1: 1100, duration: 0.04, gain: 0.45, decay: 30, delay: 0.46)])
        }
    }

    public static var table: [SlimeSound: SoundRecipe] { table(for: .puni) }
}
