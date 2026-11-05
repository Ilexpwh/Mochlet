import Accelerate
import Foundation
import MochletCore

/// A small voice fingerprint per stretch of speech, from 16 kHz samples: the mean and spread of 32
/// log-energy bands (mel-spaced) over voiced 32 ms frames, plus a pitch estimate. Not a neural speaker
/// embedding; enough to tell two or three voices apart on a call when combined with the two-channel
/// split (you on the microphone, the others on the Mac's sound). `Diarizer` is the seam for a model.
public enum SpeakerFeatures {
    public static let sampleRate = 16_000.0
    static let frame = 512
    static let hop = 256
    static let bands = 32
    public static let dimension = bands * 2 + 2

    public static func fingerprint(_ samples: [Float]) -> [Float] {
        guard samples.count >= frame else { return [] }
        let n = frame
        let log2n = vDSP_Length(log2(Double(n)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        let edges = melEdges(bands: bands, n: n)
        var sums = [Float](repeating: 0, count: bands)
        var sq = [Float](repeating: 0, count: bands)
        var pitches: [Float] = []
        var voiced = 0
        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var mags = [Float](repeating: 0, count: n / 2)
        var frameBuf = [Float](repeating: 0, count: n)
        var index = 0
        while index + n <= samples.count {
            for i in 0..<n { frameBuf[i] = samples[index + i] * window[i] }
            var energy: Float = 0
            vDSP_measqv(frameBuf, 1, &energy, vDSP_Length(n))
            index += hop
            guard energy > 1e-5 else { continue }
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frameBuf.withUnsafeBufferPointer { fp in
                        fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2)) }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(n / 2))
                }
            }
            var bandValues = [Float](repeating: 0, count: bands)
            for b in 0..<bands {
                let lo = edges[b], hi = max(edges[b + 1], edges[b] + 1)
                var s: Float = 0
                for k in lo..<min(hi, n / 2) { s += mags[k] }
                bandValues[b] = log(s / Float(hi - lo) + 1e-8)
            }
            // Per-frame normalisation removes loudness; the shape stays.
            let mean = bandValues.reduce(0, +) / Float(bands)
            for b in 0..<bands { bandValues[b] -= mean; sums[b] += bandValues[b]; sq[b] += bandValues[b] * bandValues[b] }
            voiced += 1
            if let p = pitch(frameBuf) { pitches.append(p) }
        }
        guard voiced >= 4 else { return [] }
        var out = [Float](repeating: 0, count: dimension)
        for b in 0..<bands {
            let m = sums[b] / Float(voiced)
            out[b] = m
            out[bands + b] = max(0, sq[b] / Float(voiced) - m * m).squareRoot() * 0.5
        }
        let p = pitches.isEmpty ? 0 : pitches.sorted()[pitches.count / 2]
        out[bands * 2] = p > 0 ? Float(log(Double(p) / 100)) * 3 : 0
        out[bands * 2 + 1] = Float(min(1, Double(pitches.count) / Double(voiced))) * 2
        return out
    }

    /// Autocorrelation pitch on one frame: 70–400 Hz, with a clear peak.
    static func pitch(_ x: [Float]) -> Float? {
        let n = x.count
        let minLag = Int(sampleRate / 400), maxLag = Int(sampleRate / 70)
        guard maxLag < n else { return nil }
        var energy: Float = 0
        vDSP_dotpr(x, 1, x, 1, &energy, vDSP_Length(n))
        guard energy > 0 else { return nil }
        var best = (lag: 0, r: Float(0))
        for lag in minLag...maxLag {
            var r: Float = 0
            x.withUnsafeBufferPointer { p in vDSP_dotpr(p.baseAddress!, 1, p.baseAddress! + lag, 1, &r, vDSP_Length(n - lag)) }
            if r > best.r { best = (lag, r) }
        }
        guard best.lag > 0, best.r / energy > 0.45 else { return nil }
        return Float(sampleRate) / Float(best.lag)
    }

    static func melEdges(bands: Int, n: Int) -> [Int] {
        func mel(_ f: Double) -> Double { 2595 * log10(1 + f / 700) }
        func hz(_ m: Double) -> Double { 700 * (pow(10, m / 2595) - 1) }
        let lo = mel(80), hi = mel(sampleRate / 2 - 200)
        return (0...bands).map { i in
            let f = hz(lo + (hi - lo) * Double(i) / Double(bands))
            return max(1, min(n / 2 - 1, Int(f / sampleRate * Double(n))))
        }
    }
}

/// Who speaks when, on one recording. The lite diarizer fingerprints each stretch of speech (phrases cut
/// at pauses, joined to ≥ 1.5 s) and divides them into voices; a neural diarizer (FluidAudio and the
/// like) can replace it behind this protocol.
public protocol Diarizer: Sendable {
    var name: String { get }
    func diarize(samples: [Float], phrases: [TimedPhrase], maxSpeakers: Int) async throws -> [SpeakerTurn]
}

public struct LiteDiarizer: Diarizer {
    public var name: String { "mochlet-lite" }
    /// How much less alike two groups of stretches must be than each is within itself to count as two voices.
    public var margin: Float
    public init(margin: Float = SpeakerClustering.defaultMargin) { self.margin = margin }

    public func diarize(samples: [Float], phrases: [TimedPhrase], maxSpeakers: Int = 6) async throws -> [SpeakerTurn] {
        let rate = SpeakerFeatures.sampleRate
        // Pieces: each phrase cut at the pauses inside it (a change of voice sits on a pause), then a piece
        // too short to fingerprint joins the next one, so every stretch has at least 1.5 s of voice.
        var stretches: [(start: Double, end: Double)] = []
        for p in phrases {
            for piece in Self.splitAtPauses(samples: samples, start: p.start, end: p.end) {
                if var last = stretches.last, last.end - last.start < Self.minVoice, piece.start - last.end < 0.8 {
                    last.end = max(last.end, piece.end)
                    stretches[stretches.count - 1] = last
                } else {
                    stretches.append(piece)
                }
            }
        }
        var segments: [(start: Double, end: Double, feature: [Float])] = []
        for s in stretches {
            let a = max(0, Int(s.start * rate)), b = min(samples.count, Int(s.end * rate))
            guard b > a else { continue }
            let f = SpeakerFeatures.fingerprint(Array(samples[a..<b]))
            if !f.isEmpty { segments.append((s.start, s.end, f)) }
        }
        guard !segments.isEmpty else { return stretches.map { SpeakerTurn(speaker: "s1", start: $0.start, end: $0.end) } }
        return SpeakerClustering.turns(segments: segments, margin: margin, maxSpeakers: maxSpeakers)
    }

    public static let minVoice = 1.5

    /// [start, end) cut at pauses of 0.35 s or more (20 ms RMS under a tenth of the loud level); a piece
    /// under one second stays with its neighbour. Short phrases are returned whole.
    public static func splitAtPauses(samples: [Float], start: Double, end: Double) -> [(start: Double, end: Double)] {
        guard end - start > 2.5 else { return [(start, end)] }
        let rate = SpeakerFeatures.sampleRate
        let a = max(0, Int(start * rate)), b = min(samples.count, Int(end * rate))
        guard b > a + Int(rate) else { return [(start, end)] }
        let frame = EchoRemoval.frameSeconds
        let levels = EchoRemoval.levels(Array(samples[a..<b]), sampleRate: rate)
        guard levels.count > 20 else { return [(start, end)] }
        let floor = max(EchoRemoval.percentile(levels, 0.9) * 0.1, 1e-4)
        var cuts: [Double] = []
        var quietFrom: Int?
        for (i, l) in levels.enumerated() {
            if l < floor {
                if quietFrom == nil { quietFrom = i }
            } else if let q = quietFrom {
                if Double(i - q) * frame >= 0.35 { cuts.append(start + Double(q + i) / 2 * frame) }
                quietFrom = nil
            }
        }
        var out: [(start: Double, end: Double)] = []
        var s = start
        for c in cuts where c - s >= 1.0 {
            out.append((s, c))
            s = c
        }
        if out.isEmpty || end - s >= 1.0 { out.append((s, end)) } else { out[out.count - 1].end = end }
        return out
    }
}
