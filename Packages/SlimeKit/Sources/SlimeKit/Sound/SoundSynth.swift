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

    public static func render(_ sound: SlimeSound, pack: SoundPack = .puni) -> [Float] {
        render(SoundRecipe.recipe(for: sound, in: pack), seed: seed(for: sound.rawValue))
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
        // Formant and band-pass layers lose an unpredictable amount of level in their resonators, so
        // they are rendered on their own and normalised to `gain` before mixing; plain layers mix
        // straight in, which keeps the classic pack byte-identical.
        if l.formants.isEmpty, l.bandpassStart == nil {
            renderLayerRaw(l, into: &mix, rng: &rng)
            return
        }
        var own = [Double](repeating: 0, count: mix.count)
        renderLayerRaw(l, into: &own, rng: &rng)
        let peak = own.map(abs).max() ?? 0
        guard peak > 1e-9 else { return }
        let g = l.gain / peak
        for i in mix.indices { mix[i] += own[i] * g }
    }

    private static func renderLayerRaw(_ l: SoundLayer, into mix: inout [Double], rng: inout SeededRandom) {
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
        let hasWobble = l.wobbleRate > 0 && l.wobbleDepth > 0
        // Formants: fixed two-pole resonators in parallel (a source-filter squeak), unity at resonance.
        var res: [(r: Double, c: Double, norm: Double, y1: Double, y2: Double)] = l.formants.map { f in
            let bw = max(60, f * 0.12)
            let r = exp(-.pi * bw / fs)
            let th = 2 * .pi * f / fs
            let norm = (1 - r) * (1 - 2 * r * cos(2 * th) + r * r).squareRoot()
            return (r, cos(th), norm, 0, 0)
        }
        // Band-pass: one gliding resonator (paper rustle, breathy air).
        let hasBP = l.bandpassStart != nil
        let bpA = l.bandpassStart ?? 1000
        let bpB = l.bandpassEnd ?? bpA
        let bpRatio = (bpA > 0 && bpB > 0) ? bpB / bpA : 1
        var bp1 = 0.0
        var bp2 = 0.0
        for i in 0..<n {
            let t = Double(i) / fs
            let u = t / l.duration
            var sample: Double
            if l.wave == .noise {
                sample = rng.unit() * 2 - 1
            } else {
                var f = l.f0 * pow(ratio, u) + l.vibratoDepth * sin(2 * .pi * l.vibratoRate * t)
                if hasWobble { f *= 1 + l.wobbleDepth * exp(-l.wobbleDecay * t) * sin(2 * .pi * l.wobbleRate * t) }
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
            if hasBP {
                let fc = bpA * pow(bpRatio, u)
                let r = exp(-.pi * max(60, fc * 0.3) / fs)
                let th = 2 * .pi * fc / fs
                let y = sample + 2 * r * cos(th) * bp1 - r * r * bp2
                bp2 = bp1
                bp1 = y
                sample = y * (1 - r) * (1 - 2 * r * cos(2 * th) + r * r).squareRoot()
            }
            if !res.isEmpty {
                var sum = 0.0
                for k in res.indices {
                    let y = sample + 2 * res[k].r * res[k].c * res[k].y1 - res[k].r * res[k].r * res[k].y2
                    res[k].y2 = res[k].y1
                    res[k].y1 = y
                    sum += y * res[k].norm
                }
                sample = sum / Double(res.count).squareRoot()
            }
            var env = exp(-l.decay * t)
            if l.attack > 0, t < l.attack { env *= t / l.attack }
            let remaining = l.duration - t
            if l.release > 0, remaining < l.release { env *= max(0, remaining / l.release) }
            let idx = start + i
            if idx < mix.count { mix[idx] += sample * env * l.gain }
        }
        // Bubbles: tiny random pops scattered over the layer (wet gulps, slurps, boiling jelly).
        if l.bubbles > 0 {
            let len = Int(0.02 * fs)
            for _ in 0..<l.bubbles {
                let at = start + Int(rng.unit() * max(0, l.duration * l.bubbleSpread - 0.02) * fs)
                let fb = 900 + rng.unit() * 700
                for j in 0..<len {
                    let tau = Double(j) / fs
                    let v = sin(2 * .pi * fb * (1 - 0.45 * Double(j) / Double(len)) * tau) * exp(-tau * 70) * 0.35 * l.gain
                    let idx = at + j
                    if idx < mix.count { mix[idx] += v }
                }
            }
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
