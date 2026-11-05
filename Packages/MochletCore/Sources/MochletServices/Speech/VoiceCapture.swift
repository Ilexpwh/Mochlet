import AVFoundation
import Foundation

public enum VoiceError: Error, CustomStringConvertible {
    case permissionDenied
    case noMicrophone
    case noFormat
    case assetsMissing(String)
    case failed(String)
    public var description: String {
        switch self {
        case .permissionDenied: return "Microphone access is off (System Settings → Privacy & Security → Microphone)."
        case .noMicrophone: return "No microphone is available."
        case .noFormat: return "The speech recogniser offered no audio format."
        case .assetsMissing(let l): return "Speech for \(l) is not downloaded yet."
        case .failed(let s): return s
        }
    }
}

/// The microphone as converted PCM buffers plus a 0…1 level, for push-to-talk. One capture at a time.
public final class VoiceCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    public private(set) var isRunning = false

    public init() {}

    public static func requestPermission() async -> Bool { await AVAudioApplication.requestRecordPermission() }
    public static var permissionGranted: Bool { AVAudioApplication.shared.recordPermission == .granted }
    public static var permissionDenied: Bool { AVAudioApplication.shared.recordPermission == .denied }

    /// Starts the microphone; converted buffers go to `sink`, levels to `level`, both on the audio thread.
    public func start(format: AVAudioFormat, sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void, level: @escaping @Sendable (Double) -> Void) throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw VoiceError.noMicrophone }
        // Always convert (also from an identical format): the tap's buffer is reused by the engine, the
        // converted copy is ours to hand on.
        guard let conv = AVAudioConverter(from: inFormat, to: format) else { throw VoiceError.noFormat }
        converter = conv
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { buffer, _ in
            level(Self.level(of: buffer))
            if let out = Self.convert(buffer, with: conv, to: format) { sink(out) }
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw VoiceError.failed(error.localizedDescription)
        }
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    /// One buffer through a converter (sample rate and channel layout), as a fresh buffer.
    public static func convert(_ buffer: AVAudioPCMBuffer, with conv: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        conv.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }

    /// RMS of the first channel, mapped so normal speech sits around 0.4–0.8.
    public static func level(of buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        let ch = data[0]
        for i in 0..<n { sum += ch[i] * ch[i] }
        let rms = Double(sum / Float(n)).squareRoot()
        return min(1, rms * 9)
    }
}
