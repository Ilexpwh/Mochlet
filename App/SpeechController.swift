import AVFoundation
import Observation
import SlimeCore

@MainActor @Observable final class SpeechController {
    enum Phase { case idle, requesting, recording, transcribing }
    var phase: Phase = .idle
    var level: Float = 0
    var elapsed: Int = 0
    var message: String?
    var hasKey = false
    var models: [ModelDescriptor] = []
    var refreshing = false
    var modelID = UserDefaults.standard.string(forKey: "speechModel") ?? "nvidia/nemotron-3.5-transcribe" {
        didSet { UserDefaults.standard.set(modelID, forKey: "speechModel") }
    }
    var analysisModel = UserDefaults.standard.string(forKey: "analysisModel") ?? "" {
        didSet { UserDefaults.standard.set(analysisModel, forKey: "analysisModel") }
    }
    var spokenReplies = UserDefaults.standard.bool(forKey: "spokenReplies") {
        didSet { UserDefaults.standard.set(spokenReplies, forKey: "spokenReplies") }
    }
    var voiceID = UserDefaults.standard.string(forKey: "voiceID") ?? "" {
        didSet { UserDefaults.standard.set(voiceID, forKey: "voiceID") }
    }
    var meetingActive = false { didSet { if meetingActive { stopSpeaking(); cancel() } } }
    let service = OpenRouterService()
    let credentials = CredentialStore()
    private let synthesizer = AVSpeechSynthesizer()
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var recordingModelID = ""
    private var job: Task<Void, Never>?
    private var generation = UUID()
    var receiveText: ((String) -> Void)?
    var voices: [AVSpeechSynthesisVoice] { AVSpeechSynthesisVoice.speechVoices().sorted { $0.name < $1.name } }
    var active: Bool { phase != .idle }

    func load() async { do { hasKey = try await credentials.read("openrouter") != nil } catch { message = error.localizedDescription } }
    func saveKey(_ key: String) async {
        do {
            let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty { try await credentials.remove("openrouter"); hasKey = false }
            else { try await credentials.save(Data(key.utf8), account: "openrouter"); hasKey = true }
            message = key.isEmpty ? "API key removed." : "API key saved in Keychain."
        } catch { message = error.localizedDescription }
    }
    func key() async throws -> String {
        guard let data = try await credentials.read("openrouter"), let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw MochletError.message("Add an OpenRouter API key in Speech & Models first.")
        }
        return key
    }
    func refreshModels() async {
        refreshing = true; defer { refreshing = false }
        do { models = try await service.models(transcription: true); message = "Transcription catalog refreshed. Live capability and language quality still depend on the selected model." }
        catch { message = error.localizedDescription }
    }
    func start() {
        guard phase == .idle, !meetingActive else { return }
        guard hasKey else { message = "Add an OpenRouter API key in Speech & Models first."; return }
        phase = .requesting; message = nil; stopSpeaking()
        let token = UUID(); generation = token
        recordingModelID = modelID
        job = Task {
            do {
                _ = try await key()
                let catalog = try await service.models(transcription: true)
                guard catalog.contains(where: { $0.id == recordingModelID && $0.inputModalities.contains("audio") }) else {
                    throw MochletError.message("The selected model is not available in the audio transcription catalog. Refresh Speech & Models and choose a supported model.")
                }
                guard generation == token, !Task.isCancelled else { return }
            } catch {
                if generation == token { phase = .idle; message = error.localizedDescription }; return
            }
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                if generation == token { phase = .idle; message = "Microphone access is unavailable. Enable Mochlet in System Settings → Privacy & Security → Microphone." }; return
            }
            guard generation == token, !Task.isCancelled else { return }
            do {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Mochlet-voice", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
                recordingURL = url
                recorder = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
                recorder?.isMeteringEnabled = true
                guard recorder?.record() == true else { throw MochletError.message("The microphone could not start recording.") }
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                phase = .recording; elapsed = 0
                while generation == token, !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(200))
                    guard recorder?.isRecording == true else { throw MochletError.message("Microphone recording stopped unexpectedly. The command was not submitted.") }
                    recorder?.updateMeters(); level = max(0, min(1, ((recorder?.averagePower(forChannel: 0) ?? -60) + 60) / 60))
                    elapsed = Int(recorder?.currentTime ?? 0)
                    if elapsed >= 120 { stop(); return }
                }
            } catch is CancellationError { }
            catch { if generation == token { cancel(); message = error.localizedDescription } }
        }
    }
    func stop() {
        guard phase == .recording, let url = recordingURL else { if phase == .requesting { cancel() }; return }
        recorder?.stop(); recorder = nil; job?.cancel(); phase = .transcribing; level = 0
        let token = generation; let selectedModel = recordingModelID
        job = Task {
            defer { try? FileManager.default.removeItem(at: url); if generation == token { recordingURL = nil; phase = .idle } }
            do {
                let audio = try await Task.detached { try Data(contentsOf: url) }.value
                let transcript = try await service.transcribe(audio: audio, format: "wav", model: selectedModel, key: key(), diarize: false)
                guard generation == token, !Task.isCancelled else { return }
                guard !transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MochletError.message("No speech was recognized. Try again.") }
                receiveText?(transcript.text); message = "Transcript added to your draft. Review it before sending."
            } catch { if generation == token, !Task.isCancelled { message = error.localizedDescription } }
        }
    }
    func cancel() {
        generation = UUID(); job?.cancel(); job = nil; recorder?.stop(); recorder = nil
        if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
        recordingURL = nil; phase = .idle; level = 0
    }
    func speak(_ text: String) {
        guard !meetingActive, phase == .idle, !text.isEmpty else { return }
        stopSpeaking()
        let utterance = AVSpeechUtterance(string: String(text.prefix(4000)))
        if !voiceID.isEmpty {
            guard let voice = AVSpeechSynthesisVoice(identifier: voiceID) else { message = "The selected voice is no longer installed."; return }
            utterance.voice = voice
        }
        synthesizer.speak(utterance)
    }
    func stopSpeaking() { synthesizer.stopSpeaking(at: .immediate) }
}
