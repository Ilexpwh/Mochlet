import Foundation
import AVFoundation
import SlimeKit

/// Plays `SoundCue`s with a small pool of AVAudioPlayers per sound. Looks for a user override
/// (`<overrideFolder>/<name>.(wav|aiff|caf|m4a|mp3)`, then `<overrideFolder>/<pack>/<name>.…`) first,
/// then the bundled WAV of the current pack, and finally synthesises the recipe on the fly so a
/// missing resource never silences the slime.
@MainActor
public final class SoundEngine: SoundSink {
    public static let supportedExtensions = ["wav", "aiff", "aif", "caf", "m4a", "mp3"]

    /// Master volume 0…1 (default 0.5).
    public var masterVolume: Double = 0.5
    public var isEnabled = true
    /// Folder of user-supplied replacements, checked on `reload()`.
    public var overrideFolder: URL?
    /// Which set of sounds plays; switching reloads the players.
    public var pack: SoundPack = .puni {
        didSet { if pack != oldValue { reload() } }
    }
    /// Off mutes the pack's voice squeaks (or swaps them for foley, see `SoundPack.foleyFallback`).
    public var voiceEnabled = true
    /// Global cap on plays per second.
    public var maxPlaysPerSecond = 8
    public private(set) var playCount = 0

    private var data: [SlimeSound: Data] = [:]
    private var pools: [SlimeSound: [AVAudioPlayer]] = [:]
    private var lastPlayed: [SlimeSound: TimeInterval] = [:]
    private var recent: [TimeInterval] = []
    private let poolSize = 3

    public init(overrideFolder: URL? = SoundEngine.defaultOverrideFolder, pack: SoundPack = .puni) {
        self.overrideFolder = overrideFolder
        self.pack = pack
    }

    public static var defaultOverrideFolder: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Mochlet/Sounds", isDirectory: true)
    }

    /// Decodes every sound up front (≈ 2 ms per sound) so the first cue has no latency.
    public func preload() {
        for s in SlimeSound.allCases { _ = players(for: s) }
    }

    /// Drops cached players so overrides and bundled files are read again.
    public func reload() {
        data.removeAll()
        pools.removeAll()
    }

    /// The sound that actually plays for a cue under the voice setting (nil = stays quiet).
    public func resolved(_ sound: SlimeSound) -> SlimeSound? {
        if !voiceEnabled, pack.voiceSounds.contains(sound) { return pack.foleyFallback(for: sound) }
        return sound
    }

    public func play(_ cue: SoundCue) {
        guard isEnabled, masterVolume > 0.001 else { return }
        guard let sound = resolved(cue.sound) else { return }
        let now = Date.timeIntervalSinceReferenceDate
        if let last = lastPlayed[sound], now - last < sound.minInterval { return }
        recent.removeAll { now - $0 > 1 }
        guard recent.count < maxPlaysPerSecond else { return }
        guard let player = freePlayer(for: sound) else { return }
        lastPlayed[sound] = now
        recent.append(now)
        playCount += 1
        player.currentTime = 0
        player.rate = Float(max(0.5, min(2, cue.rate)))
        player.volume = Float(max(0, min(1, cue.gain * masterVolume)))
        player.play()
    }

    // MARK: - Sources

    /// Where a sound comes from right now (for the Settings status row).
    public enum Source: Equatable { case override(URL), bundled, synthesized }

    public func source(of sound: SlimeSound) -> Source {
        if let u = overrideURL(for: sound) { return .override(u) }
        if bundledURL(for: sound) != nil { return .bundled }
        return .synthesized
    }

    private func overrideURL(for sound: SlimeSound) -> URL? {
        guard let folder = overrideFolder else { return nil }
        for sub in ["", pack.rawValue + "/"] {
            for ext in Self.supportedExtensions {
                let u = folder.appendingPathComponent("\(sub)\(sound.rawValue).\(ext)")
                if FileManager.default.fileExists(atPath: u.path) { return u }
            }
        }
        return nil
    }

    private func bundledURL(for sound: SlimeSound) -> URL? {
        Bundle.module.url(forResource: sound.rawValue, withExtension: "wav", subdirectory: "sounds/\(pack.rawValue)")
    }

    private func audioData(for sound: SlimeSound) -> Data {
        if let d = data[sound] { return d }
        var d: Data?
        if let u = overrideURL(for: sound) { d = try? Data(contentsOf: u) }
        if d == nil, let u = bundledURL(for: sound) { d = try? Data(contentsOf: u) }
        let bytes = d ?? WAVFile.encode(SoundSynth.render(sound, pack: pack), sampleRate: Int(SoundSynth.sampleRate))
        data[sound] = bytes
        return bytes
    }

    private func players(for sound: SlimeSound) -> [AVAudioPlayer] {
        if let p = pools[sound] { return p }
        let bytes = audioData(for: sound)
        var made: [AVAudioPlayer] = []
        for _ in 0..<poolSize {
            if let p = try? AVAudioPlayer(data: bytes) {
                p.enableRate = true
                p.prepareToPlay()
                made.append(p)
            }
        }
        pools[sound] = made
        return made
    }

    private func freePlayer(for sound: SlimeSound) -> AVAudioPlayer? {
        let ps = players(for: sound)
        if let idle = ps.first(where: { !$0.isPlaying }) { return idle }
        // Steal the one furthest along.
        return ps.max { $0.currentTime < $1.currentTime }
    }
}
