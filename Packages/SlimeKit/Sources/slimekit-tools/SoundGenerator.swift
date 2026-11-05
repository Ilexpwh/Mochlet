import Foundation
import SlimeKit

/// Placeholder until SoundRecipe/SoundSynth land in M2: writes nothing yet.
enum SoundGenerator {
    static func run(outDir: URL) throws {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        print("gen-sounds: synthesis arrives with the SoundRecipe table (M2); nothing written to \(outDir.path)")
    }
}
