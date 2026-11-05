import AVFoundation
import Foundation
import MochletCore
import MochletServices

/// From two recordings to the files of a meeting: transcription of both sides, echo removal, who
/// spoke when, the summary from the brain, then transcript.md / summary.md / meta.json /
/// diarization.json and the audio retention.
enum MeetingProcessor {
    struct Result: Sendable {
        var meta: MeetingMeta
        var summary: MeetingSummary?
        var lines: [MeetingLine]
    }

    struct WindowNotes: Decodable, Sendable { var notes: String }

    static func run(meta input: MeetingMeta, folder: URL, locale: Locale?, brain: LLMClient?, diarizer: any Diarizer,
                    progress: @escaping @Sendable (String, Double) -> Void) async throws -> Result {
        var meta = input
        let fm = FileManager.default
        let micURL = folder.appendingPathComponent("mic.wav")
        let sysURL = folder.appendingPathComponent("system.wav")
        guard fm.fileExists(atPath: micURL.path) else { throw MeetingError.noAudio }
        let hasSystem = fm.fileExists(atPath: sysURL.path) && ((try? sysURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 64_000

        progress("transcribing your microphone", 0.05)
        var mine = try await FileTranscriber.transcribe(micURL, locale: locale) { p in progress("transcribing your microphone", 0.05 + 0.3 * p) }
        var theirs: [TimedPhrase] = []
        if hasSystem {
            progress("transcribing the others", 0.35)
            theirs = (try? await FileTranscriber.transcribe(sysURL, locale: locale) { p in progress("transcribing the others", 0.35 + 0.3 * p) }) ?? []
        }
        if meta.durationS <= 0 { meta.durationS = max(mine.last?.end ?? 0, theirs.last?.end ?? 0) }

        progress("telling the voices apart", 0.66)
        let built: (speakers: [MeetingSpeaker], lines: [MeetingLine])
        var turns: [SpeakerTurn] = []
        if theirs.count >= 3 {
            // A call: you on the microphone, the others on the Mac's sound. Without headphones the others
            // also come back into the microphone: that echo is taken out of your phrases.
            let micSamples = (try? ChannelRecorder.readSamples(micURL)) ?? []
            let sysSamples = (try? ChannelRecorder.readSamples(sysURL)) ?? []
            let byEar = EchoRemoval.removing(mine, micLevels: EchoRemoval.levels(micSamples), sysLevels: EchoRemoval.levels(sysSamples))
            let kept = EchoRemoval.removingShared(mine: byEar.kept, others: theirs)
            meta.processing.echoRemoved = mine.count - kept.count
            mine = kept
            turns = TranscriptBuilder.mergingFragments((try? await diarizer.diarize(samples: sysSamples, phrases: theirs, maxSpeakers: 6)) ?? [])
            built = TranscriptBuilder.build(mine: mine, others: theirs, turns: turns)
        } else if mine.count >= 12 {
            // People around the Mac: one recording, the voices told apart.
            let micSamples = (try? ChannelRecorder.readSamples(micURL)) ?? []
            turns = TranscriptBuilder.mergingFragments((try? await diarizer.diarize(samples: micSamples, phrases: mine, maxSpeakers: 4)) ?? [])
            if Set(turns.map(\.speaker)).count > 1 {
                built = TranscriptBuilder.buildRoom(phrases: mine, turns: turns)
            } else {
                built = TranscriptBuilder.build(mine: mine, others: [], turns: [])
            }
        } else {
            built = TranscriptBuilder.build(mine: mine, others: theirs, turns: [])
        }
        meta.processing.diarizer = diarizer.name
        meta.speakers = built.speakers
        let lines = built.lines
        guard !lines.isEmpty else { throw MeetingError.nothingHeard }

        progress("writing the summary", 0.72)
        var summary: MeetingSummary?
        var summaryError: String?
        if let brain {
            meta.processing.summaryModel = brain.label
            do { summary = try await summarize(lines: lines, meta: meta, brain: brain, progress: progress) }
            catch { summaryError = ErrorText.describe(error) }
        }
        if let s = summary, !meta.titleEdited, !s.title.isEmpty { meta.title = s.title }

        progress("filing", 0.95)
        meta.processing.status = .ready
        // The transcript is the meeting; a summary that failed is noted and can be retried from the card.
        meta.processing.error = summaryError.map { "summary: \($0)" }
        try writeFiles(meta: meta, summary: summary, lines: lines, folder: folder)
        try (try? JSONEncoder().encode(turns.map { ["speaker": $0.speaker, "start": "\($0.start)", "end": "\($0.end)"] }))?.write(to: folder.appendingPathComponent("diarization.json"))
        meta = try applyRetention(meta, folder: folder)
        try MeetingMeta.encoder.encode(meta).write(to: folder.appendingPathComponent("meta.json"), options: .atomic)
        progress("done", 1)
        return Result(meta: meta, summary: summary, lines: lines)
    }

    static func summarize(lines: [MeetingLine], meta: MeetingMeta, brain: LLMClient, progress: @escaping @Sendable (String, Double) -> Void) async throws -> MeetingSummary {
        let transcript = MeetingPrompts.render(lines, speakers: meta.speakers)
        let title = meta.titleEdited ? meta.title : nil
        if transcript.count <= MeetingPrompts.directLimit {
            return try await brain.structured(MeetingSummary.self, system: MeetingPrompts.summarySystem,
                                              user: MeetingPrompts.user(transcript: transcript, title: title, app: meta.app.name, started: meta.startedAt, duration: meta.durationS, marks: meta.marks),
                                              schema: MeetingPrompts.summarySchema)
        }
        let windows = TranscriptBuilder.windows(lines, seconds: 900)
        var notes: [String] = []
        for (i, w) in windows.enumerated() {
            progress("notes on part \(i + 1) of \(windows.count)", 0.72 + 0.2 * Double(i) / Double(windows.count))
            let n = try await brain.structured(WindowNotes.self, system: MeetingPrompts.windowSystem,
                                               user: MeetingPrompts.windowUser(MeetingPrompts.render(w, speakers: meta.speakers), index: i, count: windows.count), schema: MeetingPrompts.windowSchema)
            notes.append(n.notes)
        }
        progress("writing the summary", 0.92)
        return try await brain.structured(MeetingSummary.self, system: MeetingPrompts.summarySystem,
                                          user: MeetingPrompts.reduceUser(notes: notes, title: title, app: meta.app.name, started: meta.startedAt, duration: meta.durationS, marks: meta.marks),
                                          schema: MeetingPrompts.summarySchema)
    }

    /// The summary again, for a meeting whose transcript exists: files rewritten, the error cleared or kept.
    static func resummarize(meta input: MeetingMeta, lines: [MeetingLine], folder: URL, brain: LLMClient,
                            progress: @escaping @Sendable (String, Double) -> Void) async -> (meta: MeetingMeta, summary: MeetingSummary?) {
        var meta = input
        meta.processing.summaryModel = brain.label
        do {
            let s = try await summarize(lines: lines, meta: meta, brain: brain, progress: progress)
            if !meta.titleEdited, !s.title.isEmpty { meta.title = s.title }
            meta.processing.error = nil
            try? writeFiles(meta: meta, summary: s, lines: lines, folder: folder)
            return (meta, s)
        } catch {
            meta.processing.error = "summary: " + ErrorText.describe(error)
            try? MeetingMeta.encoder.encode(meta).write(to: folder.appendingPathComponent("meta.json"), options: .atomic)
            return (meta, nil)
        }
    }

    /// transcript.md (Lark form), summary.md, summary.json, meta.json.
    static func writeFiles(meta: MeetingMeta, summary: MeetingSummary?, lines: [MeetingLine], folder: URL) throws {
        let transcript = LarkTranscript.format(startedAt: meta.startedAt, duration: meta.durationS, keywords: summary?.keywords ?? [], lines: lines, speakers: meta.speakers)
        try transcript.write(to: folder.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        if let summary {
            try MeetingWriter.summaryMarkdown(summary, meta: meta).write(to: folder.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
            let e = JSONEncoder()
            e.outputFormatting = [.prettyPrinted, .sortedKeys]
            try e.encode(summary).write(to: folder.appendingPathComponent("summary.json"), options: .atomic)
        }
        try MeetingMeta.encoder.encode(meta).write(to: folder.appendingPathComponent("meta.json"), options: .atomic)
    }

    /// delete → the WAVs go now; mixed_7d → one AAC mixdown, WAVs go, the mixdown in 7 days; keep → nothing.
    static func applyRetention(_ input: MeetingMeta, folder: URL) throws -> MeetingMeta {
        var meta = input
        let fm = FileManager.default
        let micURL = folder.appendingPathComponent("mic.wav"), sysURL = folder.appendingPathComponent("system.wav")
        switch meta.audio.retention {
        case .keepWAVs:
            meta.audio.files = ["mic.wav", "system.wav"].filter { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
            meta.audio.deleteAfter = nil
        case .delete:
            try? fm.removeItem(at: micURL)
            try? fm.removeItem(at: sysURL)
            meta.audio.files = []
            meta.audio.deleteAfter = nil
        case .mixed7d:
            let mix = folder.appendingPathComponent("audio.m4a")
            if (try? mixdown(mic: micURL, system: sysURL, to: mix)) != nil {
                try? fm.removeItem(at: micURL)
                try? fm.removeItem(at: sysURL)
                meta.audio.files = ["audio.m4a"]
                meta.audio.deleteAfter = Date().addingTimeInterval(7 * 86_400)
            } else {
                meta.audio.files = ["mic.wav", "system.wav"].filter { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
                meta.audio.deleteAfter = Date().addingTimeInterval(7 * 86_400)
            }
        }
        return meta
    }

    /// Both sides summed into one 16 kHz AAC file.
    static func mixdown(mic: URL, system: URL, to dest: URL) throws {
        let a = try ChannelRecorder.readSamples(mic)
        let b = (try? ChannelRecorder.readSamples(system)) ?? []
        let n = max(a.count, b.count)
        guard n > 0 else { throw MeetingError.noAudio }
        var mixed = [Float](repeating: 0, count: n)
        for i in 0..<n { mixed[i] = (i < a.count ? a[i] : 0) + (i < b.count ? b[i] : 0) }
        let peak = mixed.map(abs).max() ?? 1
        if peak > 0.98 { let g = 0.98 / peak; for i in 0..<n { mixed[i] *= g } }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48_000]
        try? FileManager.default.removeItem(at: dest)
        let file = try AVAudioFile(forWriting: dest, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let step = 16_000
        var i = 0
        while i < n {
            let count = min(step, n - i)
            guard let buf = AVAudioPCMBuffer(pcmFormat: Resampler16k.format, frameCapacity: AVAudioFrameCount(count)), let ch = buf.floatChannelData?[0] else { break }
            buf.frameLength = AVAudioFrameCount(count)
            mixed.withUnsafeBufferPointer { p in ch.update(from: p.baseAddress! + i, count: count) }
            try file.write(from: buf)
            i += count
        }
    }
}

enum MeetingError: LocalizedError {
    case noAudio, nothingHeard, microphoneDenied
    var errorDescription: String? {
        switch self {
        case .noAudio: return "No recording was found."
        case .nothingHeard: return "Nothing was heard in the recording."
        case .microphoneDenied: return "Microphone access is off for Mochlet. Allow it in System Settings → Privacy & Security → Microphone."
        }
    }
}
