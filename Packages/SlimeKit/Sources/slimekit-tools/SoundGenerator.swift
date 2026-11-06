import Foundation
import SlimeKit

/// Renders every recipe of a pack to deterministic 48 kHz mono 16-bit WAVs in `<outDir>/<pack>/`.
enum SoundGenerator {
    static func run(outDir: URL, packs: [SoundPack]) throws {
        for pack in packs {
            let dir = outDir.appendingPathComponent(pack.rawValue, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var report: [String] = []
            var bytes = 0
            for s in SlimeSound.allCases {
                let samples = SoundSynth.render(s, pack: pack)
                let data = WAVFile.encode(samples, sampleRate: Int(SoundSynth.sampleRate))
                try data.write(to: dir.appendingPathComponent("\(s.rawValue).wav"))
                bytes += data.count
                let peak = samples.map { abs($0) }.max() ?? 0
                let db = peak > 0 ? 20 * log10(Double(peak)) : -120
                let name = s.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)
                report.append(name + String(format: " %5.3f s  peak %6.2f dBFS  %6d bytes", Double(samples.count) / SoundSynth.sampleRate, db, data.count))
            }
            print(report.joined(separator: "\n"))
            print("wrote \(SlimeSound.allCases.count) \(pack.rawValue) sounds (\(bytes / 1024) KB) to \(dir.path)")
        }
    }
}
