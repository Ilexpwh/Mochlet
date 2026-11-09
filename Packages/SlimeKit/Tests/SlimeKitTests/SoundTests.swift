import Testing
import Foundation
@testable import SlimeKit
import SlimeKitAudio

@Suite struct SoundTableTests {
    @Test(arguments: SoundPack.allCases) func everySoundHasARecipeAndRenders(pack: SoundPack) {
        #expect(SlimeSound.allCases.count == 44)
        for s in SlimeSound.allCases {
            let r = SoundRecipe.recipe(for: s, in: pack)
            #expect(!r.layers.isEmpty, "\(s)")
            #expect(r.duration <= 1.0, "\(pack) \(s) too long: \(r.duration)")
            let samples = SoundSynth.render(s, pack: pack)
            #expect(samples.count > 1000, "\(s)")
            #expect(samples.allSatisfy { $0.isFinite }, "\(pack) \(s) not finite")
            let peak = samples.map { abs($0) }.max() ?? 0
            #expect(peak > 0.47 && peak < 0.52, "\(pack) \(s) peak \(peak)")
            #expect(abs(samples.first ?? 1) < 0.01 && abs(samples.last ?? 1) < 0.01, "\(pack) \(s) boundary click")
        }
    }

    @Test func packsDiffer() {
        // The puni pack re-voices the 2.0 chimes; the classic pack keeps them and borrows only the new foley.
        #expect(SoundSynth.render(.greet, pack: .puni) != SoundSynth.render(.greet, pack: .classic))
        #expect(SoundSynth.render(.squish, pack: .puni) == SoundSynth.render(.squish, pack: .classic))
        #expect(SoundRecipe.table(for: .puni).count == 44)
        #expect(SoundRecipe.table(for: .classic).count == 44)
    }

    @Test func synthFeaturesStayBounded() {
        // Wobble, formants, band-pass and bubbles each render without blowing up or going silent.
        let fx: [SoundLayer] = [
            SoundLayer(f0: 240, duration: 0.3, wobble: (8, 0.18, 4)),
            SoundLayer(f0: 520, f1: 760, duration: 0.2, formants: [800, 1250, 2600]),
            SoundLayer(.noise, f0: 0, duration: 0.15, bandpass: (2500, 1600)),
            SoundLayer(f0: 300, f1: 110, duration: 0.2, bubbles: 3),
        ]
        for l in fx {
            let out = SoundSynth.render(SoundRecipe([l]), seed: 7)
            #expect(out.allSatisfy { $0.isFinite && abs($0) <= 1 })
            let rms = (out.map { Double($0 * $0) }.reduce(0, +) / Double(max(1, out.count))).squareRoot()
            #expect(rms > 0.01 && rms < 0.5, "rms \(rms)")
        }
    }

    @Test func renderingIsDeterministic() {
        #expect(SoundSynth.render(.splat) == SoundSynth.render(.splat))
        #expect(SoundSynth.render(.kyu, pack: .puni) == SoundSynth.render(.kyu, pack: .puni))
        #expect(SoundSynth.seed(for: "greet") != SoundSynth.seed(for: "blip"))
    }

    @Test func wavRoundTrip() throws {
        let samples = SoundSynth.render(.greet)
        let data = WAVFile.encode(samples, sampleRate: 48_000)
        #expect(data.count == 44 + samples.count * 2)
        let decoded = try #require(WAVFile.decode(data))
        #expect(decoded.info.sampleRate == 48_000)
        #expect(decoded.info.channels == 1)
        #expect(decoded.info.bitsPerSample == 16)
        #expect(decoded.info.frameCount == samples.count)
        var maxErr: Float = 0
        for (a, b) in zip(samples, decoded.samples) { maxErr = max(maxErr, abs(a - b)) }
        #expect(maxErr < 2.0 / 32767)
    }

    @Test func minIntervalsAndGains() {
        for s in SlimeSound.allCases {
            #expect(s.minInterval >= 0.05 && s.minInterval <= 0.5)
            #expect(s.baseGain > 0 && s.baseGain <= 1)
        }
        #expect(SlimeSound.plip.minInterval == 0.06)
        #expect(SlimeSound.chew.minInterval == 0.18)
        #expect(SlimeSound.hamu.minInterval == 0.18)
    }

    @Test func voiceFallbacksAreFoley() {
        for pack in SoundPack.allCases {
            for v in pack.voiceSounds {
                if let f = pack.foleyFallback(for: v) { #expect(!pack.voiceSounds.contains(f), "\(pack) \(v) -> \(f)") }
            }
        }
        #expect(SoundPack.puni.voiceSounds.contains(.kyu))
        #expect(!SoundPack.puni.voiceSounds.contains(.squish))
    }

    @MainActor @Test func engineRateLimitsCues() {
        let e = SlimeEngine(seed: 1)
        e.cue(.plip)
        e.cue(.plip)
        e.simulate(0.1)
        e.cue(.plip)
        let cues = e.drainCues().filter { $0.sound == .plip }
        #expect(cues.count == 2)
    }

    @MainActor @Test func pokeAndCheerUsePuniSounds() {
        let e = SlimeEngine(seed: 2)
        e.simulate(0.5)
        _ = e.drainCues()
        e.trigger(.poked)
        e.simulate(0.05)
        #expect(e.drainCues().contains { $0.sound == .puni })
        e.simulate(1)
        e.trigger(.cheer)
        e.simulate(0.2)   // the hop's "pyon" comes after its anticipation crouch
        let sounds = Set(e.drainCues().map(\.sound))
        #expect(sounds.contains(.pika) && sounds.contains(.pyon))
    }

    @MainActor @Test(arguments: SoundPack.allCases) func bundledWavsExist(pack: SoundPack) {
        let engine = SoundEngine(overrideFolder: nil, pack: pack)
        for s in SlimeSound.allCases {
            #expect(engine.source(of: s) == .bundled, "\(pack) \(s)")
        }
    }

    @MainActor @Test func overridesAcceptPackSubfolders() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mochlet-sounds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("classic"), withIntermediateDirectories: true)
        let wav = WAVFile.encode(SoundSynth.render(.blip), sampleRate: 48_000)
        try wav.write(to: dir.appendingPathComponent("classic/blip.wav"))
        try wav.write(to: dir.appendingPathComponent("greet.wav"))
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = SoundEngine(overrideFolder: dir, pack: .puni)
        #expect(engine.source(of: .greet) != .bundled)
        #expect(engine.source(of: .blip) == .bundled)
        engine.pack = .classic
        #expect(engine.source(of: .blip) != .bundled)
        #expect(engine.source(of: .greet) != .bundled)
    }

    @MainActor @Test func voiceToggleResolvesToFoleyOrSilence() {
        let engine = SoundEngine(overrideFolder: nil, pack: .puni)
        #expect(engine.resolved(.greet) == .greet)
        engine.voiceEnabled = false
        #expect(engine.resolved(.greet) == .pyon)
        #expect(engine.resolved(.kyu) == nil)
        #expect(engine.resolved(.squish) == .squish)
        engine.masterVolume = 0.5
        engine.play(SoundCue(.kyu))
        #expect(engine.playCount == 0)
    }

    @MainActor @Test func soundEngineCapsPlays() {
        let engine = SoundEngine(overrideFolder: nil)
        engine.masterVolume = 0
        for _ in 0..<20 { engine.play(SoundCue(.blip)) }
        #expect(engine.playCount == 0)
        engine.masterVolume = 0.5
        engine.isEnabled = false
        engine.play(SoundCue(.blip))
        #expect(engine.playCount == 0)
    }
}
