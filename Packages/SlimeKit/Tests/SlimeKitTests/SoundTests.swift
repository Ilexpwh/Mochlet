import Testing
import Foundation
@testable import SlimeKit
import SlimeKitAudio

@Suite struct SoundTableTests {
    @Test func everySoundHasARecipeAndRenders() {
        #expect(SlimeSound.allCases.count == 28)
        for s in SlimeSound.allCases {
            let r = SoundRecipe.recipe(for: s)
            #expect(!r.layers.isEmpty, "\(s)")
            #expect(r.duration <= 1.0, "\(s) too long: \(r.duration)")
            let samples = SoundSynth.render(s)
            #expect(samples.count > 1000, "\(s)")
            let peak = samples.map { abs($0) }.max() ?? 0
            #expect(peak > 0.47 && peak < 0.52, "\(s) peak \(peak)")
            #expect(abs(samples.first ?? 1) < 0.01 && abs(samples.last ?? 1) < 0.01, "\(s) boundary click")
        }
    }

    @Test func renderingIsDeterministic() {
        #expect(SoundSynth.render(.splat) == SoundSynth.render(.splat))
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

    @MainActor @Test func bundledWavsExist() {
        let engine = SoundEngine(overrideFolder: nil)
        for s in SlimeSound.allCases {
            #expect(engine.source(of: s) == .bundled, "\(s)")
        }
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
