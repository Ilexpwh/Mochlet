import AVFoundation
import Foundation
import Speech
import MochletCore

/// Audio and video: the audio track is decoded to 16 kHz mono PCM, then transcribed on device with
/// SpeechAnalyzer; the result is a time-indexed transcript (one `turn` per ~sentence group).
public enum MediaExtractor {
    public static let ffmpegPaths = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
    static let avExtensions: Set<String> = ["mp3", "m4a", "wav", "aac", "aiff", "aif", "caf", "mp4", "mov", "m4v", "flac"]

    public static func extract(_ url: URL, locale: Locale? = nil, progress: (@Sendable (Double) -> Void)? = nil) async throws -> ExtractedContent {
        let name = (url.lastPathComponent as NSString).deletingPathExtension
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("mochlet-media-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: temp) }
        let duration: Double
        if avExtensions.contains(url.pathExtension.lowercased()) {
            duration = try await AudioDecoder.decodeToWAV(url, to: temp)
        } else if let ffmpeg = ffmpegPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            try AudioDecoder.ffmpegToWAV(ffmpeg, url, to: temp)
            duration = try await AudioDecoder.decodeToWAV(temp, to: temp.appendingPathExtension("2"))
            try? FileManager.default.removeItem(at: temp.appendingPathExtension("2"))
        } else {
            throw ExtractError.unsupported(url.lastPathComponent + " (install ffmpeg for this container)")
        }
        progress?(0.1)
        let phrases = try await FileTranscriber.transcribe(temp, locale: locale, progress: { p in progress?(0.1 + 0.85 * p) })
        guard !phrases.isEmpty else { throw ExtractError.empty(url.lastPathComponent) }
        var blocks: [ContentBlock] = [.heading(level: 1, text: name)]
        for t in TranscriptGrouper.group(phrases) { blocks.append(.turn(speaker: nil, start: t.start, end: t.end, text: t.text)) }
        let md = ExtractedContent.render(blocks)
        let lang = phrases.first.map { LanguageGuess.code($0.text) } ?? "en"
        return ExtractedContent(title: name, markdown: md, blocks: blocks, metadata: ["duration": TranscriptTime.format(duration)], language: lang,
                                extractors: ["media", "speech"], mirrorText: md, mirrorExtension: "md")
    }
}

public struct TimedPhrase: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String
    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// Decodes any AVFoundation-readable file's first audio track to 16 kHz mono float WAV.
public enum AudioDecoder {
    public static let sampleRate = 16_000.0

    /// Returns the duration in seconds.
    public static func decodeToWAV(_ source: URL, to dest: URL) async throws -> Double {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw ExtractError.unsupported(source.lastPathComponent + " (no audio track)") }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        guard reader.startReading() else { throw ExtractError.failed(reader.error?.localizedDescription ?? "cannot read audio") }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else { throw ExtractError.failed("audio format") }
        let file = try AVAudioFile(forWriting: dest, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        var frames: Int64 = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let count = CMSampleBufferGetNumSamples(sample)
            guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { continue }
            buffer.frameLength = AVAudioFrameCount(count)
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
            if let pointer, let dst = buffer.floatChannelData?[0] {
                memcpy(dst, pointer, min(length, count * 4))
            }
            try file.write(from: buffer)
            frames += Int64(count)
        }
        if reader.status == .failed { throw ExtractError.failed(reader.error?.localizedDescription ?? "audio decode failed") }
        return Double(frames) / sampleRate
    }

    static func ffmpegToWAV(_ ffmpeg: String, _ source: URL, to dest: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-y", "-loglevel", "error", "-i", source.path, "-vn", "-ac", "1", "-ar", "16000", "-f", "wav", dest.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw ExtractError.failed("ffmpeg could not decode \(source.lastPathComponent)") }
    }
}

/// On-device file transcription with time ranges (macOS 26 SpeechAnalyzer).
public enum FileTranscriber {
    public static func transcribe(_ wav: URL, locale: Locale? = nil, progress: (@Sendable (Double) -> Void)? = nil) async throws -> [TimedPhrase] {
        let chosen = try await pickLocale(locale)
        let transcriber = SpeechTranscriber(locale: chosen, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: wav)
        let total = Double(file.length) / file.fileFormat.sampleRate
        var phrases: [TimedPhrase] = []
        let collector = Task {
            var out: [TimedPhrase] = []
            for try await result in transcriber.results where result.isFinal {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let start = result.range.start.seconds
                let end = result.range.end.seconds
                out.append(TimedPhrase(start: start, end: end, text: text))
                if total > 0 { progress?(min(1, end / total)) }
            }
            return out
        }
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        phrases = try await collector.value
        return phrases
    }

    /// The current locale when the transcriber supports it, else English; a Chinese system gets zh_CN.
    static func pickLocale(_ wanted: Locale?) async throws -> Locale {
        let supported = await SpeechTranscriber.supportedLocales
        func match(_ l: Locale) -> Locale? { supported.first { $0.identifier(.bcp47) == l.identifier(.bcp47) } ?? supported.first { $0.language.languageCode == l.language.languageCode } }
        if let wanted, let m = match(wanted) { return m }
        if let m = match(Locale.current) { return m }
        if let m = match(Locale(identifier: "en_US")) { return m }
        guard let any = supported.first else { throw ExtractError.failed("Speech transcription is not available on this Mac.") }
        return any
    }
}

/// Groups phrases into readable turns: a new turn after a pause ≥ 1.2 s, ≥ 25 s of audio or ≈ 60 words.
public enum TranscriptGrouper {
    public static func group(_ phrases: [TimedPhrase], pause: Double = 1.2, maxSeconds: Double = 25, maxWords: Int = 60) -> [TimedPhrase] {
        var out: [TimedPhrase] = []
        var current: TimedPhrase?
        var words = 0
        for p in phrases {
            let w = max(1, p.text.split(separator: " ").count, CJK.contains(p.text) ? p.text.count / 2 : 0)
            if var c = current, p.start - c.end < pause, p.end - c.start <= maxSeconds, words + w <= maxWords {
                let cjk = c.text.last.map { CJK.isCJK($0.unicodeScalars.first!) } == true
                c.text += (cjk ? "" : " ") + p.text
                c.end = p.end
                current = c
                words += w
            } else {
                if let c = current { out.append(c) }
                current = p
                words = w
            }
        }
        if let c = current { out.append(c) }
        return out
    }
}
