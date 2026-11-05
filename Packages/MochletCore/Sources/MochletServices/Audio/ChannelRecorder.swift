import AVFoundation
import Foundation
import os

/// 16 kHz mono float samples from any format.
public final class Resampler16k: @unchecked Sendable {
    public static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private let converter: AVAudioConverter?
    private let ratio: Double

    public init?(from source: AVAudioFormat) {
        ratio = Self.format.sampleRate / source.sampleRate
        if source.sampleRate == Self.format.sampleRate, source.channelCount == 1, source.commonFormat == .pcmFormatFloat32 {
            converter = nil
        } else {
            guard let c = AVAudioConverter(from: source, to: Self.format) else { return nil }
            converter = c
        }
    }

    public func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard buffer.frameLength > 0 else { return [] }
        guard let converter else {
            guard let p = buffer.floatChannelData?[0] else { return [] }
            return Array(UnsafeBufferPointer(start: p, count: Int(buffer.frameLength)))
        }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return [] }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let p = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: p, count: Int(out.frameLength)))
    }
}

/// One side of a call (your microphone, or what the Mac plays): written to a 16 kHz WAV file as it
/// comes, with the stretch not transcribed yet kept in memory for the live transcript.
/// Port of Coucou's ChannelRecorder (MIT).
public final class ChannelRecorder: @unchecked Sendable {
    public static let sampleRate = 16_000.0

    public let url: URL
    private let queue: DispatchQueue
    private var file: AVAudioFile?

    private struct Live {
        var pending: [Float] = []
        var pendingStart = 0.0
        var total = 0
        var level: Float = 0
        var voiced = 0.0
        var started = false
    }
    private let live = OSAllocatedUnfairLock(initialState: Live())
    private let origin: UInt64

    public init(url: URL, label: String, origin: UInt64 = DispatchTime.now().uptimeNanoseconds) throws {
        self.url = url
        self.origin = origin
        queue = DispatchQueue(label: label, qos: .userInitiated)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.sampleRate, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// From the audio thread.
    public func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let incoming = Double(samples.count) / Self.sampleRate
        let origin = self.origin
        // The Mac's sound starts a moment after the microphone: the silence before its first sound is
        // written, so both recordings share one clock.
        let lead = live.withLock { state -> Int in
            guard !state.started else { return 0 }
            state.started = true
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- origin) / 1_000_000_000
            let seconds = min(10, elapsed - incoming)
            return seconds > 0.01 ? Int(seconds * Self.sampleRate) : 0
        }
        let samples = lead > 0 ? [Float](repeating: 0, count: lead) + samples : samples
        let rms = Self.rms(samples[...])
        live.withLock { state in
            state.pending.append(contentsOf: samples)
            state.total += samples.count
            state.level = rms
            if rms > 0.01 { state.voiced += Double(samples.count) / Self.sampleRate }
        }
        queue.async { [self] in
            guard let file, let buffer = AVAudioPCMBuffer(pcmFormat: Resampler16k.format, frameCapacity: AVAudioFrameCount(samples.count)),
                  let channel = buffer.floatChannelData?[0] else { return }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { src in if let base = src.baseAddress { channel.update(from: base, count: samples.count) } }
            try? file.write(from: buffer)
        }
    }

    public var level: Float { live.withLock { $0.level } }
    public var voicedSeconds: Double { live.withLock { $0.voiced } }
    public var totalSeconds: Double { live.withLock { Double($0.total) / Self.sampleRate } }

    /// The stretch not transcribed yet, once it is long enough and ends on a pause (or has become too
    /// long to wait). Silent stretches are dropped without a word.
    public func takeChunk(minSeconds: Double = 4, maxSeconds: Double = 18, force: Bool = false) -> (start: Double, samples: [Float])? {
        live.withLock { state -> (start: Double, samples: [Float])? in
            let seconds = Double(state.pending.count) / Self.sampleRate
            guard seconds >= (force ? 0.5 : minSeconds) else { return nil }
            let tail = state.pending.suffix(Int(Self.sampleRate / 2))
            guard force || Self.rms(tail) < 0.012 || seconds >= maxSeconds else { return nil }
            let chunk = (start: state.pendingStart, samples: state.pending)
            state.pendingStart = Double(state.total) / Self.sampleRate
            state.pending.removeAll(keepingCapacity: true)
            return Self.rms(chunk.samples[...]) < 0.004 ? nil : chunk
        }
    }

    public func closeNow() { queue.sync { file = nil } }

    public func close() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async { [self] in file = nil; c.resume() }
        }
    }

    public static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// Writes 16 kHz samples as a WAV (tests and the debug replay).
    public static func writeWAV(_ samples: [Float], to url: URL) throws {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: Resampler16k.format, frameCapacity: AVAudioFrameCount(max(1, samples.count))), let ch = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in if let b = src.baseAddress { ch.update(from: b, count: samples.count) } }
        try file.write(from: buffer)
    }

    /// All samples of a WAV/AIFF/m4a as 16 kHz mono floats.
    public static func readSamples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let resampler = Resampler16k(from: file.processingFormat) else { return [] }
        let chunk = AVAudioFrameCount(file.processingFormat.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { return [] }
        var out: [Float] = []
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: chunk)
            guard buffer.frameLength > 0 else { break }
            out += resampler.convert(buffer)
        }
        return out
    }
}

// MARK: - Microphone

/// The microphone, as 16 kHz mono samples.
public final class MicCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    public init() {}

    public func start(sink: @escaping @Sendable ([Float]) -> Void) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, let resampler = Resampler16k(from: format) else { throw VoiceError.noMicrophone }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in sink(resampler.convert(buffer)) }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
