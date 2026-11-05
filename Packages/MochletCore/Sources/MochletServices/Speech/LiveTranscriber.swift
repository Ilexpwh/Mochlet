import AVFoundation
import Foundation
import Speech

public struct LiveSegment: Sendable, Equatable {
    public var text: String
    public var isFinal: Bool
}

/// On-device live transcription for push-to-talk: feed converted microphone buffers, get volatile text
/// as it forms and final text per phrase; `finish()` flushes the tail after the key is released.
public final class LiveTranscriber: @unchecked Sendable {
    public let locale: Locale
    public let format: AVAudioFormat
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Error>?

    public init(locale: Locale) async throws {
        self.locale = locale
        transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let f = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { throw VoiceError.noFormat }
        format = f
    }

    /// The assets the transcriber needs are installed for this locale.
    public static func isReady(_ locale: Locale) async -> Bool {
        await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    }

    public func start(onSegment: @escaping @Sendable (LiveSegment) -> Void) async throws {
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        continuation = cont
        let t = transcriber
        results = Task {
            for try await r in t.results {
                onSegment(LiveSegment(text: String(r.text.characters), isFinal: r.isFinal))
            }
        }
        try await analyzer.start(inputSequence: stream)
    }

    public func feed(_ buffer: AVAudioPCMBuffer) {
        continuation?.yield(AnalyzerInput(buffer: buffer))
    }

    /// Ends the input and waits for the last final result.
    public func finish() async {
        continuation?.finish()
        continuation = nil
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        _ = try? await results?.value
    }

    public func cancel() async {
        continuation?.finish()
        continuation = nil
        await analyzer.cancelAndFinishNow()
        results?.cancel()
    }
}

/// Speech model assets per locale: what is installed, what can be downloaded, and the download itself.
public enum SpeechAssets {
    public enum State: Sendable, Equatable {
        case installed
        case downloadable
        case downloading
        case unsupported
    }

    /// "auto" → the best match for the system language; "zh-CN", "zh-TW", "en" → that language when supported.
    public static func locale(for setting: String) async -> Locale? {
        let wanted: Locale? = setting == "auto" || setting.isEmpty ? nil : Locale(identifier: setting.replacingOccurrences(of: "-", with: "_"))
        return try? await FileTranscriber.pickLocale(wanted)
    }

    public static func state(_ locale: Locale) async -> State {
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else { return .unsupported }
        let t = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        switch await AssetInventory.status(forModules: [t]) {
        case .installed: return .installed
        case .downloading: return .downloading
        case .supported: return .downloadable
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    /// Downloads and installs the assets, reporting 0…1, and reserves the locale so the system keeps them.
    public static func install(_ locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws {
        let t = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
            let p = request.progress
            let poll = Task {
                while !Task.isCancelled {
                    progress(p.fractionCompleted)
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
            defer { poll.cancel() }
            try await request.downloadAndInstall()
        }
        _ = try? await AssetInventory.reserve(locale: locale)
        progress(1)
    }

    public static var installedLocales: [Locale] {
        get async { await SpeechTranscriber.installedLocales }
    }
}
