import SwiftUI
import CryptoKit
import SlimeCore

@MainActor @Observable final class MeetingController {
    var sessions: [MeetingSession] = []
    var selectedID: String?
    var activeID: String?
    var phase = "idle"
    var elapsed = 0
    var microphoneLevel: Float = 0
    var systemLevel: Float = 0
    var message: String?
    var title = ""
    var source = "microphone"
    var modelID = UserDefaults.standard.string(forKey: "meetingModel") ?? "nvidia/nemotron-3.5-transcribe" { didSet { UserDefaults.standard.set(modelID, forKey: "meetingModel") } }
    let folder: URL
    let speech: SpeechController
    var store: MeetingStore?
    var capture: MeetingCapture?
    var timer: Task<Void, Never>?
    var operation: Task<Void, Never>?
    var transcriptionJob: Task<Void, Never>?
    var retention: Task<Void, Never>?
    var pendingSegments: [(String, String)] = []
    var flushJob: Task<Void, Never>?
    var shuttingDown = false
    var selected: MeetingSession? { sessions.first { $0.id == selectedID } }
    var recording: Bool { phase == "recording" }
    var active: Bool { activeID != nil || phase != "idle" }
    var applications: [(id: String, name: String)] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }.compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }.sorted { $0.name < $1.name }
    }
    init(folder: URL, speech: SpeechController) { self.folder = folder; self.speech = speech }
    func load() async {
        do {
            let key = try await speech.credentials.read("meeting-audio-key")
            store = try MeetingStore(directory: folder.appendingPathComponent("Meetings"), keyData: key)
            try await store?.recover(); try await refresh()
            retention = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(3600)); try await self?.store?.sweep(); try await self?.refresh() }
                    catch is CancellationError { return }
                    catch { self?.message = error.localizedDescription }
                }
            }
        } catch { message = error.localizedDescription }
    }
    func refresh() async throws { sessions = try await store?.all() ?? [] }
    func prepareKey() async throws {
        if let key = try await speech.credentials.read("meeting-audio-key") { try await store?.setKey(key); return }
        // Never silently replace a lost key when encrypted audio already exists.
        guard !sessions.contains(where: { $0.segments.contains(where: \.audioAvailable) }) else { throw MochletError.message("The meeting audio key is missing. Restore its Keychain item before recording or reprocessing.") }
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        try await speech.credentials.save(key, account: "meeting-audio-key"); try await store?.setKey(key)
    }
    func start(projectID: String?) {
        guard !active, let store else { return }
        phase = "starting"; message = nil
        let selectedSource = source; let selectedModel = modelID; let selectedTitle = title
        operation = Task {
            do {
                try await prepareKey(); try Task.checkCancellation()
                let meeting = MeetingSession(title: selectedTitle.isEmpty ? "Meeting · \(Date().formatted(date: .abbreviated, time: .shortened))" : selectedTitle, projectID: projectID, source: selectedSource, modelID: selectedModel)
                try await store.create(meeting)
                if Task.isCancelled {
                    try? await store.update(meeting.id, event: "startup-cancelled") { $0.state = "paused"; $0.notices.append("Startup cancelled before capture. Resume explicitly.") }
                    throw CancellationError()
                }
                activeID = meeting.id; selectedID = meeting.id
                try await beginCapture(meeting)
            } catch { await captureFailed(error) }
        }
    }
    func beginCapture(_ meeting: MeetingSession) async throws {
        try Task.checkCancellation()
        speech.meetingActive = true
        let capture = MeetingCapture(offset: max(0, Date().timeIntervalSince(meeting.startedAt))); self.capture = capture
        try await capture.start(applicationID: meeting.source == "microphone" ? nil : meeting.source)
        try Task.checkCancellation()
        phase = "recording"
        try await store?.update(meeting.id, event: "capture-started") { $0.state = "recording" }
        try await refresh(); timer?.cancel()
        timer = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, self.recording else { return }
                let status = capture.buffer.status(); self.microphoneLevel = status.0; self.systemLevel = status.1
                self.elapsed = Int(Date().timeIntervalSince(meeting.startedAt))
                if let error = status.2 { self.message = error; await self.pause(reason: error); return }
                ticks += 1
                if ticks % 120 == 0 { await self.flush() }
            }
        }
    }
    func captureFailed(_ error: Error) async {
        let pausing = phase == "pausing"
        message = error.localizedDescription; await capture?.stop(); speech.meetingActive = false
        phase = pausing ? "pausing" : activeID == nil ? "idle" : "paused"
        if let id = activeID { try? await store?.update(id, event: "capture-failed") { $0.state = "paused"; $0.notices.append(error.localizedDescription) } }
        try? await refresh()
    }
    func resume(_ meeting: MeetingSession) {
        guard phase == "paused" || (!active && ["paused", "interrupted"].contains(meeting.state)) else { return }
        activeID = meeting.id; selectedID = meeting.id; phase = "starting"
        operation = Task { do { try await prepareKey(); try await beginCapture(meeting) } catch { await captureFailed(error) } }
    }
    func pause(reason: String = "Paused by you. Resume explicitly when ready.") async {
        guard ["recording", "starting"].contains(phase) else { return }
        operation?.cancel(); timer?.cancel(); phase = "pausing"
        await capture?.stop()
        // Await the cancelled startup before allowing another start. Keychain and
        // database awaits may finish even after cancellation; neither may start capture.
        await operation?.value
        await capture?.stop(); await flush(); capture = nil; microphoneLevel = 0; systemLevel = 0; speech.meetingActive = false
        if let id = activeID { try? await store?.update(id, event: "paused") { $0.state = "paused"; $0.notices.append(reason) } }
        phase = activeID == nil ? "idle" : "paused"; try? await refresh()
    }
    func flush() async {
        while let flushJob { await flushJob.value }
        guard let capture, let id = activeID, let store else { return }
        let packets = capture.buffer.drain(); guard !packets.isEmpty else { return }
        let job = Task {
        defer { flushJob = nil }
        do {
            for packet in packets {
                let wav = await Task.detached { PCM16WAV.encode(packet.samples) }.value
                _ = try await store.appendAudio(meetingID: id, source: packet.source, offset: packet.offset, duration: Double(packet.samples.count) / 16000, wav: wav)
            }
            let start = packets.map(\.offset).min()!
            let end = packets.map { $0.offset + Double($0.samples.count) / 16000 }.max()!
            let mixed = try await Task.detached { PCM16WAV.encode(try AudioAssembly.mix(packets.map { AudioSlice(offset: $0.offset, samples: $0.samples) }, offset: start, duration: end - start)) }.value
            let segment = try await store.appendAudio(meetingID: id, source: "mix", offset: start, duration: end - start, wav: mixed)
            pendingSegments.append((id, segment.id)); drainTranscriptions(); try await refresh()
        } catch {
            message = "Audio segment could not be saved: \(error.localizedDescription)"
            capture.buffer.fail(message!)
            try? await store.update(id, event: "audio-gap") { $0.notices.append("Some audio could not be saved: \(error.localizedDescription)") }
        }
        }
        flushJob = job; await job.value
    }
    func stop() async {
        guard let id = activeID, phase == "recording" || phase == "paused" else { return }
        timer?.cancel(); phase = "processing"; await capture?.stop(); await flush(); capture = nil; speech.meetingActive = false
        try? await store?.update(id, event: "stopped") { $0.state = "processing" }
        try? await refresh()
        pendingSegments = []
        operation = Task { await transcriptionJob?.value; await finalize(id); activeID = nil; phase = "idle" }
    }
    func shutdown() async {
        shuttingDown = true
        operation?.cancel(); timer?.cancel(); retention?.cancel(); transcriptionJob?.cancel(); pendingSegments = []
        await capture?.stop(); await flush(); capture = nil; speech.meetingActive = false
        if let id = activeID { try? await store?.update(id, event: "quit") { $0.state = "interrupted"; $0.notices.append("Stopped when Mochlet quit. Reprocessing is explicit; an interrupted API request may have been billed.") } }
    }
    func cancelOperation() {
        operation?.cancel(); pendingSegments = []; transcriptionJob?.cancel()
        if phase == "starting" {
            Task { await pause(reason: "Recording startup cancelled.") }
        }
    }
    func deleteMeeting(_ meeting: MeetingSession) async {
        guard activeID != meeting.id else { return }
        do { try await store?.delete(meeting.id); selectedID = nil; try await refresh() } catch { message = error.localizedDescription }
    }
    func setKeep(_ meeting: MeetingSession, value: Bool) async {
        do { try await store?.update(meeting.id, event: "retention-choice") { $0.keepAudio = value }; try await store?.sweep(); try await refresh() }
        catch { message = error.localizedDescription }
    }
    func deleteAudio(_ meeting: MeetingSession) async {
        guard activeID != meeting.id else { message = "Stop the meeting before deleting its audio."; return }
        do { try await store?.deleteAudio(meeting.id); try await refresh() } catch { message = error.localizedDescription }
    }
}
