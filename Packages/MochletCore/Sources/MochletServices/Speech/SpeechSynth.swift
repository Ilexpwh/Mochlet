import AVFoundation
import Foundation

/// Spoken replies (optional): a system voice for the reply's language.
@MainActor
public final class SpeechSynth {
    public static let shared = SpeechSynth()
    private let synth = AVSpeechSynthesizer()

    public func speak(_ text: String, language: String?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        synth.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: String(t.prefix(600)))
        let lang = Self.bcp47(language ?? "en")
        u.voice = AVSpeechSynthesisVoice(language: lang) ?? AVSpeechSynthesisVoice(language: "en-US")
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(u)
    }

    public func stop() { synth.stopSpeaking(at: .immediate) }
    public var isSpeaking: Bool { synth.isSpeaking }

    static func bcp47(_ code: String) -> String {
        switch code.lowercased() {
        case "zh", "zh-cn", "zh_cn", "zh-hans": return "zh-CN"
        case "zh-tw", "zh_tw", "zh-hant": return "zh-TW"
        case "zh-hk", "yue": return "zh-HK"
        case "ja": return "ja-JP"
        case "ko": return "ko-KR"
        case "fr": return "fr-FR"
        case "de": return "de-DE"
        case "es": return "es-ES"
        default: return code.contains("-") ? code : "en-US"
        }
    }
}
