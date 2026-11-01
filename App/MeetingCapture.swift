import AVFoundation
import ScreenCaptureKit
import SlimeCore

// Resampling and microphone tap adapted from Coucou Resampler16k / MicCapture,
// b6a85f2. Copyright (c) 2026 Louis Raillé. MIT: LICENSES/Coucou-MIT.txt.
final class Resampler16k: @unchecked Sendable {
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private let converter: AVAudioConverter
    private let ratio: Double
    init?(from input: AVAudioFormat) {
        guard input.sampleRate > 0, let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false), let converter = AVAudioConverter(from: input, to: output) else { return nil }
        converter.downmix = true; self.converter = converter; ratio = 16000 / input.sampleRate
    }
    func convert(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        guard buffer.frameLength > 0, let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64) else { return [] }
        nonisolated(unsafe) var fed = false
        nonisolated(unsafe) let source = buffer
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if fed { inputStatus.pointee = .noDataNow; return nil }
            fed = true; inputStatus.pointee = .haveData; return source
        }
        guard status != .error, let channels = output.floatChannelData else { throw error ?? NSError(domain: "MochletAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Audio conversion failed."]) }
        return Array(UnsafeBufferPointer(start: channels[0], count: Int(output.frameLength)))
    }
}
struct CapturedAudio: Sendable { var source: String; var offset: Double; var samples: [Float] }

// Audio callbacks own the capture thread; this lock only protects bounded copies.
final class MeetingAudioBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var packets: [CapturedAudio] = []
    private var count = 0
    private var failure: String?
    private var levels: [String: Float] = [:]
    private var lastMicrophone = Date()
    let origin: Double
    let offset: Double
    init(offset: Double) { origin = AVAudioTime.seconds(forHostTime: mach_absolute_time()); self.offset = offset }
    func append(_ samples: [Float], source: String, time: Double) {
        lock.lock(); defer { lock.unlock() }
        guard count + samples.count <= 2_000_000 else { failure = "Audio processing could not keep up. Recording was paused; some samples may be missing."; return }
        guard !samples.isEmpty else { return }
        let position = max(0, offset + time - origin)
        if let index = packets.lastIndex(where: { $0.source == source }), abs(packets[index].offset + Double(packets[index].samples.count) / 16000 - position) < 0.05 {
            packets[index].samples.append(contentsOf: samples)
        } else { packets.append(CapturedAudio(source: source, offset: position, samples: samples)) }
        count += samples.count
        levels[source] = min(1, sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)) * 4)
        if source == "microphone" { lastMicrophone = Date() }
    }
    func fail(_ message: String) { lock.lock(); failure = message; lock.unlock() }
    func status() -> (Float, Float, String?) {
        lock.lock(); defer { lock.unlock() }
        return (levels["microphone"] ?? 0, levels["system"] ?? 0, failure ?? (Date().timeIntervalSince(lastMicrophone) > 5 ? "Microphone stopped delivering audio. Check the input device and resume explicitly." : nil))
    }
    func drain() -> [CapturedAudio] { lock.lock(); defer { lock.unlock() }; let result = packets; packets = []; count = 0; return result }
}

private final class SystemAudioOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let buffer: MeetingAudioBuffer
    private var resampler: Resampler16k?
    private var format: AVAudioFormat?
    init(buffer: MeetingAudioBuffer) { self.buffer = buffer }
    func stream(_ stream: SCStream, didStopWithError error: Error) { buffer.fail("System audio stopped: \(error.localizedDescription)") }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio, sampleBuffer.isValid else { return }
        do {
            try sampleBuffer.withAudioBufferList { list, _ in
                guard let description = sampleBuffer.formatDescription else { throw MochletError.message("Missing system audio format.") }
                let inputFormat = AVAudioFormat(cmAudioFormatDescription: description)
                guard let pcm = AVAudioPCMBuffer(pcmFormat: inputFormat, bufferListNoCopy: list.unsafePointer) else { throw MochletError.message("Unsupported system audio format.") }
                if format != inputFormat { resampler = Resampler16k(from: inputFormat); format = inputFormat }
                guard let resampler else { throw MochletError.message("System audio conversion is unavailable.") }
                let samples = try resampler.convert(pcm)
                buffer.append(samples, source: "system", time: sampleBuffer.presentationTimeStamp.seconds)
            }
        } catch { buffer.fail(error.localizedDescription) }
    }
}

@MainActor final class MeetingCapture {
    private var engine: AVAudioEngine?
    private var stream: SCStream?
    private var output: SystemAudioOutput?
    private var configurationObserver: NSObjectProtocol?
    let buffer: MeetingAudioBuffer
    init(offset: Double) { buffer = MeetingAudioBuffer(offset: offset) }
    func start(applicationID: String?) async throws {
        try Task.checkCancellation()
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw MochletError.message("Microphone permission is required to start this meeting.") }
        try Task.checkCancellation()
        if let applicationID {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            try Task.checkCancellation()
            guard let display = content.displays.first else { throw MochletError.message("No display is available for system audio capture.") }
            let filter: SCContentFilter
            if applicationID == "all" { filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: []) }
            else {
                guard let app = content.applications.first(where: { $0.bundleIdentifier == applicationID }) else { throw MochletError.message("The selected application is no longer running. Choose a source again.") }
                filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
            }
            let config = SCStreamConfiguration(); config.capturesAudio = true; config.excludesCurrentProcessAudio = true
            config.sampleRate = 48000; config.channelCount = 2; config.width = 2; config.height = 2; config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            let output = SystemAudioOutput(buffer: buffer); self.output = output
            let stream = SCStream(filter: filter, configuration: config, delegate: output); self.stream = stream
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: DispatchQueue(label: "Mochlet.system-audio"))
            try await stream.startCapture()
        }
        do {
            try Task.checkCancellation()
            let engine = AVAudioEngine(); self.engine = engine
            let input = engine.inputNode; let format = input.outputFormat(forBus: 0)
            guard format.channelCount > 0, let resampler = Resampler16k(from: format) else { throw MochletError.message("The microphone format is unavailable.") }
            let buffer = buffer
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { pcm, time in
                do { buffer.append(try resampler.convert(pcm), source: "microphone", time: time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : AVAudioTime.seconds(forHostTime: mach_absolute_time())) }
                catch { buffer.fail(error.localizedDescription) }
            }
            configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in buffer.fail("Audio device configuration changed. Resume after checking the selected input.") }
            engine.prepare(); try engine.start()
        } catch { await stop(); throw error }
    }
    func stop() async {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }; configurationObserver = nil
        if let engine { engine.inputNode.removeTap(onBus: 0); engine.stop() }; engine = nil
        if let stream { try? await stream.stopCapture() }; stream = nil; output = nil
    }
}
