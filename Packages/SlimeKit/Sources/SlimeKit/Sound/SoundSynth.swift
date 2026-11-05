import Foundation

/// Deterministic offline renderer for `SoundRecipe`: 48 kHz mono float samples, tanh-limited and
/// normalised to the recipe's peak. The noise seed derives from the sound name (FNV-1a).
public enum SoundSynth {
    public static let sampleRate: Double = 48_000

    public static func seed(for name: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in name.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return h == 0 ? 1 : h
    }

    public static func render(_ sound: SlimeSound) -> [Float] {
        render(SoundRecipe.recipe(for: sound), seed: seed(for: sound.rawValue))
    }

    public static func render(_ recipe: SoundRecipe, seed: UInt64) -> [Float] {
        let fs = sampleRate
        let total = Int((recipe.duration + 0.01) * fs)
        guard total > 0 else { return [] }
        var mix = [Double](repeating: 0, count: total)
        var rng = SeededRandom(seed: seed)
        for layer in recipe.layers {
            renderLayer(layer, into: &mix, rng: &rng)
        }
        // Soft limiter then peak normalisation.
        let drive = 1.2
        let norm = tanh(drive)
        var out = mix.map { tanh($0 * drive) / norm }
        let peak = out.map(abs).max() ?? 0
        let target = pow(10, recipe.peakDB / 20)
        if peak > 1e-9 {
            let g = target / peak
            for i in out.indices { out[i] *= g }
        }
        // 4 ms boundary fades so nothing clicks.
        let fade = max(1, Int(0.004 * fs))
        for i in 0..<min(fade, out.count) {
            let w = Double(i) / Double(fade)
            out[i] *= w
            out[out.count - 1 - i] *= w
        }
        return out.map { Float($0) }
    }

    private static func renderLayer(_ l: SoundLayer, into mix: inout [Double], rng: inout SeededRandom) {
        let fs = sampleRate
        let n = Int(l.duration * fs)
        guard n > 0 else { return }
        let start = Int(l.delay * fs)
        let f1 = l.f1 ?? l.f0
        let ratio = (l.f0 > 0 && f1 > 0) ? f1 / l.f0 : 1
        var phase = 0.0
        var lp1 = 0.0
        var lp2 = 0.0
        let hasLP = l.lowpassStart != nil
        let lpA = l.lowpassStart ?? 1000
        let lpB = l.lowpassEnd ?? lpA
        let lpRatio = (lpA > 0 && lpB > 0) ? lpB / lpA : 1
        for i in 0..<n {
            let t = Double(i) / fs
            let u = t / l.duration
            var sample: Double
            if l.wave == .noise {
                sample = rng.unit() * 2 - 1
            } else {
                let f = l.f0 * pow(ratio, u) + l.vibratoDepth * sin(2 * .pi * l.vibratoRate * t)
                phase += f / fs
                phase -= floor(phase)
                sample = osc(l.wave, phase)
                if l.harmonic > 0 {
                    var p2 = phase * 2
                    p2 -= floor(p2)
                    sample += l.harmonic * osc(l.wave, p2)
                }
            }
            if hasLP {
                let fc = lpA * pow(lpRatio, u)
                let a = 1 - exp(-2 * .pi * fc / fs)
                lp1 += a * (sample - lp1)
                lp2 += a * (lp1 - lp2)
                sample = lp2
            }
            var env = exp(-l.decay * t)
            if l.attack > 0, t < l.attack { env *= t / l.attack }
            let remaining = l.duration - t
            if l.release > 0, remaining < l.release { env *= max(0, remaining / l.release) }
            let idx = start + i
            if idx < mix.count { mix[idx] += sample * env * l.gain }
        }
    }

    private static func osc(_ w: Waveform, _ p: Double) -> Double {
        switch w {
        case .sine: return sin(2 * .pi * p)
        case .triangle: return 1 - 4 * abs(p - 0.5)
        case .square: return p < 0.5 ? 0.8 : -0.8
        case .saw: return 2 * p - 1
        case .noise: return 0
        }
    }
}
