import Foundation
import SlimeKit

/// Renders the 28 recipes to deterministic 48 kHz mono 16-bit WAVs.
enum SoundGenerator {
    static func run(outDir: URL) throws {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        var report: [String] = []
        for s in SlimeSound.allCases {
            let samples = SoundSynth.render(s)
            let data = WAVFile.encode(samples, sampleRate: Int(SoundSynth.sampleRate))
            let url = outDir.appendingPathComponent("\(s.rawValue).wav")
            try data.write(to: url)
            let peak = samples.map { abs($0) }.max() ?? 0
            let db = peak > 0 ? 20 * log10(Double(peak)) : -120
            report.append(String(format: "%-10@ %5.3f s  peak %6.2f dBFS  %6d bytes", s.rawValue as NSString, Double(samples.count) / SoundSynth.sampleRate, db, data.count))
        }
        print(report.joined(separator: "\n"))
        print("wrote \(SlimeSound.allCases.count) sounds to \(outDir.path)")
    }
}
