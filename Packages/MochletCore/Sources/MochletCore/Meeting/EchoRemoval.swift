import Foundation

/// Without headphones, the others' voices come out of the speakers and back into the microphone, and
/// the recogniser writes them as yours. The Mac's own sound is the reference: where the microphone
/// holds no more energy than the echo of that sound explains, what it heard is the others, not you.
/// Pure functions on 16 kHz samples and on 20 ms level frames (port of Coucou's NoteEcho, MIT).
public enum EchoRemoval {
    public static let frameSeconds = 0.02
    /// How much louder than the echo the microphone must be for a phrase to be yours (≈ 10 dB).
    public static let margin: Float = 3
    /// The microphone lags behind what the Mac plays: searched from −100 ms to +500 ms.
    public static let lags = -5...25

    public struct Analysis: Sendable {
        public var lag: Int
        public var gain: Float
        public var sysActive: Float
        public var micFloor: Float
        public var mic: [Float]
        public var sys: [Float]
    }

    /// RMS level of each 20 ms frame.
    public static func levels(_ samples: [Float], sampleRate: Double = 16_000) -> [Float] {
        let size = Int(sampleRate * frameSeconds)
        guard size > 0, !samples.isEmpty else { return [] }
        var out: [Float] = []
        out.reserveCapacity(samples.count / size + 1)
        var index = 0
        while index < samples.count {
            let end = min(samples.count, index + size)
            var sum: Float = 0
            for k in index..<end { sum += samples[k] * samples[k] }
            out.append((sum / Float(end - index)).squareRoot())
            index = end
        }
        return out
    }

    public static func percentile(_ values: [Float], _ p: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * p)))
        return sorted[index]
    }

    /// How the Mac's sound reaches the microphone: the delay and the strength of the echo.
    /// nil when the Mac played too little sound to tell.
    public static func analyze(mic: [Float], sys: [Float]) -> Analysis? {
        guard !mic.isEmpty, !sys.isEmpty else { return nil }
        let sysActive = max(0.004, percentile(sys, 0.1) * 4)
        let active = sys.indices.filter { sys[$0] > sysActive }
        guard active.count >= 50 else { return nil }
        let micFloor = percentile(mic, 0.1)
        var best = (lag: 0, corr: -Float.infinity)
        for lag in lags {
            var xs: [Float] = [], ys: [Float] = []
            for t in active where t + lag >= 0 && t + lag < mic.count {
                xs.append(sys[t])
                ys.append(mic[t + lag])
            }
            guard xs.count >= 50 else { continue }
            let corr = pearson(xs, ys)
            if corr > best.corr { best = (lag, corr) }
        }
        var ratios: [Float] = []
        for t in active where t + best.lag >= 0 && t + best.lag < mic.count {
            ratios.append(mic[t + best.lag] / sys[t])
        }
        guard ratios.count >= 50 else { return nil }
        return Analysis(lag: best.lag, gain: percentile(ratios, 0.35), sysActive: sysActive, micFloor: micFloor, mic: mic, sys: sys)
    }

    /// For one frame of the microphone: nil when the Mac plays nothing then, true when the microphone holds nothing more than the echo.
    public static func isEcho(frame f: Int, in a: Analysis) -> Bool? {
        let t = f - a.lag
        guard f >= 0, f < a.mic.count, t >= 0, t < a.sys.count, a.sys[t] > a.sysActive else { return nil }
        return a.mic[f] <= margin * a.gain * a.sys[t] + 2 * a.micFloor
    }

    /// Which of the microphone's phrases are the echo of the others.
    public static func echoFlags(_ phrases: [TimedPhrase], analysis a: Analysis) -> [Bool] {
        var flags = phrases.map { p -> Bool in
            let first = max(0, Int(((p.start - 0.04) / frameSeconds).rounded(.down)))
            let last = max(first, Int(((p.end + 0.04) / frameSeconds).rounded(.up)))
            var active = 0, echo = 0
            for f in first...last {
                guard let e = isEcho(frame: f, in: a) else { continue }
                active += 1
                if e { echo += 1 }
            }
            let frames = last - first + 1
            return active * 2 >= frames && Double(echo) >= Double(active) * 0.6
        }
        let original = flags
        if phrases.count >= 3 {
            for i in 1..<(phrases.count - 1) where original[i - 1] == original[i + 1] && original[i] != original[i - 1] {
                if phrases[i].start - phrases[i - 1].end < 0.6, phrases[i + 1].start - phrases[i].end < 0.6 { flags[i] = original[i - 1] }
            }
        }
        return flags
    }

    /// The microphone's phrases without the echo, from both recordings' levels.
    public static func removing(_ phrases: [TimedPhrase], micLevels: [Float], sysLevels: [Float]) -> (kept: [TimedPhrase], removed: Int) {
        guard let analysis = analyze(mic: micLevels, sys: sysLevels) else { return (phrases, 0) }
        let flags = echoFlags(phrases, analysis: analysis)
        let kept = zip(phrases, flags).filter { !$0.1 }.map(\.0)
        return (kept, phrases.count - kept.count)
    }

    /// Second pass on the words: a phrase of yours whose tokens the others' recording also has at the same
    /// moment is that echo (catches what the level check lets through when the speakers are loud).
    public static func removingShared(mine: [TimedPhrase], others: [TimedPhrase], margin: Double = 1.5, share: Double = 0.6) -> [TimedPhrase] {
        mine.filter { p in
            let mine = tokens(p.text)
            guard !mine.isEmpty else { return true }
            let near = others.filter { $0.start < p.end + margin && p.start < $0.end + margin }.flatMap { tokens($0.text) }
            guard !near.isEmpty else { return true }
            let pool = Set(near)
            let shared = mine.filter { pool.contains($0) }.count
            if mine.count == 1 { return !pool.contains(mine[0]) }
            return Double(shared) / Double(mine.count) < share
        }
    }

    /// Latin words lowercased, CJK as character bigrams (so "我们明天" and "明天开会" share "明天").
    public static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        var latin = ""
        var prevCJK: Character?
        func flushLatin() { if !latin.isEmpty { out.append(latin); latin = "" } }
        for c in s.lowercased() {
            if isCJK(c) {
                flushLatin()
                if let p = prevCJK { out.append(String(p) + String(c)) }
                prevCJK = c
            } else if c.isLetter || c.isNumber {
                prevCJK = nil
                latin.append(c)
            } else {
                flushLatin()
                prevCJK = nil
            }
        }
        flushLatin()
        return out
    }

    static func isCJK(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x3040...0x30FF).contains(v) || (0x3400...0x4DBF).contains(v) || (0x4E00...0x9FFF).contains(v) || (0xF900...0xFAFF).contains(v) || (0xAC00...0xD7AF).contains(v)
    }

    private static func pearson(_ xs: [Float], _ ys: [Float]) -> Float {
        let n = Float(xs.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var sxy: Float = 0, sxx: Float = 0, syy: Float = 0
        for i in xs.indices {
            let dx = xs[i] - mx, dy = ys[i] - my
            sxy += dx * dy
            sxx += dx * dx
            syy += dy * dy
        }
        guard sxx > 0, syy > 0 else { return 0 }
        return sxy / (sxx * syy).squareRoot()
    }
}
