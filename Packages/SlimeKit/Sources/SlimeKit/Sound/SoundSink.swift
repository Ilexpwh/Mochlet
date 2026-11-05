import Foundation

/// Anything that can play engine sound cues (SlimeKitAudio.SoundEngine, a test recorder…).
@MainActor
public protocol SoundSink: AnyObject {
    func play(_ cue: SoundCue)
}

extension SoundSink {
    public func play(_ cues: [SoundCue]) {
        for c in cues { play(c) }
    }
}
