import AppKit
import Foundation
import MochletCore
import MochletServices
import SlimeKit
import os

private let logger = Logger(subsystem: "com.ilexpwh.Mochlet", category: "meeting")

/// The meeting note-taker: triple-click (or the detector's card) starts a recording of your microphone
/// and of what the Mac plays, transcribed live; stop writes the transcript, the summary, the knowledge
/// page and the files under `~/Mochlet/Meetings/<date>-<slug>/`.
@MainActor
@Observable
final class MeetingController {
    enum State: Equatable {
        case idle, asking, starting, recording, processing, review, failed
    }

    struct LiveLine: Equatable, Identifiable {
        var id: String { "\(speaker)-\(start)" }
        var speaker: String
        var start: Double
        var end: Double
        var text: String
    }

    /// A finished meeting, for the review card and the Meetings list.
    struct Finished: Equatable {
        var meta: MeetingMeta
        var summary: MeetingSummary?
        var lines: [MeetingLine]
        var folder: URL
        var transcriptURL: URL { folder.appendingPathComponent("transcript.md") }
        var summaryURL: URL { folder.appendingPathComponent("summary.md") }
    }

    static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Mochlet/Meetings", isDirectory: true)

    private(set) var state: State = .idle
    private(set) var detection: MeetingDetectionRules.Detection?
    private(set) var current: MeetingMeta?
    private(set) var folder: URL?
    private(set) var liveLines: [LiveLine] = []
    private(set) var micLevel: Float = 0
    private(set) var systemLevel: Float = 0
    private(set) var elapsed: TimeInterval = 0
    private(set) var stage = ""
    private(set) var progress: Double = 0
    private(set) var last: Finished?
    private(set) var error: String?
    private(set) var recent: [Finished] = []
    private(set) var systemAudioError: String?
    var prefs = MeetingPrefs() { didSet { savePrefs() } }

    @ObservationIgnored private unowned let app: AppCoordinator
    @ObservationIgnored private var mic: MicCapture?
    @ObservationIgnored private var tap: SystemAudioTap?
    @ObservationIgnored private var micRec: ChannelRecorder?
    @ObservationIgnored private var sysRec: ChannelRecorder?
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private var transcribing = false
    @ObservationIgnored private var locale: Locale?
    @ObservationIgnored private var detector: MeetingDetector?
    @ObservationIgnored private var askWork: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var loadingPrefs = false

    init(app: AppCoordinator) { self.app = app }

    var isRecording: Bool { state == .recording }

    func start() {
        try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        loadPrefs()
        detector = MeetingDetector(app: app)
        detector?.start()
        Task { await recover(); janitor(); reloadRecent() }
    }

    func shutdown() {
        startTask?.cancel()
        micRec?.closeNow()
        sysRec?.closeNow()
        mic?.stop()
        tap?.stop()
        if var m = current, state == .recording {
            m.endedAt = Date()
            m.durationS = elapsed
            m.processing.status = .recording     // picked up by recover() next launch
            try? Self.write(meta: m, in: folder)
        }
    }

    // MARK: Triple-click and the ask card

    func toggle() {
        switch state {
        case .idle, .failed, .review: beginRecording(app: frontApp(), detection: nil)
        case .asking: accept()
        case .starting: cancelStart()
        case .recording: stop()
        case .processing: app.toast("Still writing the notes of the last meeting…", symbol: "waveform")
        }
    }

    /// The detector saw a call: ask (or capture when the app is set to always).
    func offer(_ d: MeetingDetectionRules.Detection) {
        guard state == .idle || state == .failed || state == .review else { return }
        switch prefs.verdict(for: d) {
        case .ignore: return
        case .capture:
            beginRecording(app: MeetingApp(bundleID: d.bundleID, name: d.appName, windowTitle: d.title), detection: d)
        case .ask:
            guard detection != d else { return }
            detection = d
            state = .asking
            app.slime.stage.main.startQuestion()
            app.slime.sound.play(SoundCue(.question))
            app.window.hold("meeting", true)
            app.window.send(.openExternally(.meetingLive))
            askWork?.cancel()
            askWork = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(45))
                guard let self, !Task.isCancelled, self.state == .asking else { return }
                self.dismissAsk(snooze: true)
            }
        }
    }

    func accept() {
        guard state == .asking, let d = detection else { return }
        askWork?.cancel()
        detection = nil
        beginRecording(app: MeetingApp(bundleID: d.bundleID, name: d.appName, windowTitle: d.title), detection: d)
    }

    func always() {
        guard let d = detection else { return }
        prefs.apps[d.bundleID] = .always
        accept()
    }

    func never() {
        guard let d = detection else { return }
        prefs.apps[d.bundleID] = .never
        dismissAsk(snooze: false)
        app.toast("I won't ask about \(d.appName) again. Change it in Settings → Voice & Meetings.", symbol: "waveform.slash")
    }

    func dismissAsk(snooze: Bool) {
        askWork?.cancel()
        if snooze, let d = detection { prefs.snooze(d) }
        detection = nil
        state = .idle
        app.window.hold("meeting", false)
        app.window.send(.collapse)
    }

    // MARK: Recording

    private func frontApp() -> MeetingApp {
        let front = NSWorkspace.shared.frontmostApplication
        let title = MeetingDetector.focusedWindowTitle(pid: front?.processIdentifier)
        return MeetingApp(bundleID: front?.bundleIdentifier, name: front?.localizedName, windowTitle: title)
    }

    /// The microphone and the Mac's sound. Both can wait on a permission prompt (the microphone the
    /// first time, System Audio Recording the first time), so they start in a task: the card says
    /// "starting" and stays responsive, and Cancel or another triple-click gives up.
    private func beginRecording(app meetingApp: MeetingApp, detection: MeetingDetectionRules.Detection?) {
        guard state != .recording, state != .processing, state != .starting else { return }
        askWork?.cancel()
        self.detection = nil
        error = nil
        let started = Date()
        let title = MeetingWriter.defaultTitle(app: meetingApp, startedAt: started)
        let id = MeetingWriter.slug(title: title, startedAt: started)
        let dir = Self.root.appendingPathComponent(id, isDirectory: true)
        var meta = MeetingMeta(id: id, title: title, startedAt: started, app: meetingApp, locale: app.settings.voiceLocale, retention: app.settings.meetingRetention)
        meta.audio.files = ["mic.wav", "system.wav"]
        state = .starting
        stage = VoiceCapture.permissionDenied ? "microphone access is off" : "starting the microphone"
        progress = 0
        app.window.hold("meeting", true)
        app.window.send(.openExternally(.meetingLive))
        let fm = FileManager.default
        startTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var m: ChannelRecorder?, s: ChannelRecorder?
            var micCapture: MicCapture?
            func undo() {
                micCapture?.stop()
                m?.closeNow()
                s?.closeNow()
                try? fm.removeItem(at: dir)
            }
            do {
                guard !VoiceCapture.permissionDenied, await VoiceCapture.requestPermission() else { throw MeetingError.microphoneDenied }
                guard !Task.isCancelled, self.state == .starting else { return }
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let origin = DispatchTime.now().uptimeNanoseconds
                let mic = try ChannelRecorder(url: dir.appendingPathComponent("mic.wav"), label: "com.ilexpwh.Mochlet.meeting.mic", origin: origin)
                let sys = try ChannelRecorder(url: dir.appendingPathComponent("system.wav"), label: "com.ilexpwh.Mochlet.meeting.sys", origin: origin)
                m = mic
                s = sys
                let capture = MicCapture()
                try capture.start { samples in mic.append(samples) }
                micCapture = capture
                self.stage = "listening to the Mac's sound"
                let t = SystemAudioTap()
                var tapError: String?
                do { try await t.start(offMain: { samples in sys.append(samples) }) } catch { tapError = ErrorText.describe(error) }
                guard !Task.isCancelled, self.state == .starting else { t.stop(); undo(); return }
                self.micRec = mic
                self.sysRec = sys
                self.mic = capture
                self.tap = tapError == nil ? t : nil
                self.systemAudioError = tapError
            } catch {
                undo()
                guard self.state == .starting else { return }
                self.fail("Could not start recording: \(ErrorText.describe(error))")
                return
            }
            self.stage = ""
            try? Self.write(meta: meta, in: dir)
            self.current = meta
            self.folder = dir
            self.liveLines = []
            self.elapsed = 0
            self.state = .recording
            self.app.slime.stage.main.setRecording(true)
            self.app.slime.sound.play(SoundCue(.blip))
            self.app.notch.cardNote = nil
            if self.systemAudioError != nil { self.app.toast("Recording the microphone only: system audio was refused. Allow it in System Settings → Privacy → Screen & System Audio Recording.", symbol: "speaker.slash", seconds: 6) }
            self.locale = await SpeechAssets.locale(for: self.app.settings.voiceLocale)
            self.startLiveLoop()
            if let detection { logger.info("started from detection: \(detection.reason, privacy: .private)") }
        }
    }

    /// Gives up while the microphone or the system audio is still being started (a permission prompt is up).
    func cancelStart() {
        guard state == .starting else { return }
        startTask?.cancel()
        startTask = nil
        state = .idle
        stage = ""
        app.window.hold("meeting", false)
    }

    private func startLiveLoop() {
        liveTask?.cancel()
        liveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.state == .recording, let started = self.current?.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(started)
                self.micLevel = self.micRec?.level ?? 0
                self.systemLevel = self.sysRec?.level ?? 0
                self.app.slime.stage.main.setAudioLevel(Double(min(1, max(self.micLevel, self.systemLevel) * 6)))
                guard !self.transcribing else { continue }
                for (rec, speaker) in [(self.micRec, "me"), (self.sysRec, "others")] {
                    guard let rec, let chunk = rec.takeChunk() else { continue }
                    self.transcribing = true
                    let phrases = await Self.transcribe(chunk.samples, locale: self.locale)
                    self.transcribing = false
                    guard self.state == .recording else { return }
                    for p in phrases {
                        let text = p.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { continue }
                        let line = LiveLine(speaker: speaker, start: chunk.start + p.start, end: chunk.start + p.end, text: text)
                        if var last = self.liveLines.last, last.speaker == speaker, line.start - last.end < 1.4, line.end - last.start < 40 {
                            last.text += (last.text.last.map(VoiceController.isCJK) ?? false) || (text.first.map(VoiceController.isCJK) ?? false) ? text : " " + text
                            last.end = line.end
                            self.liveLines[self.liveLines.count - 1] = last
                        } else {
                            self.liveLines.append(line)
                        }
                    }
                    self.liveLines.sort { $0.start < $1.start }
                    if self.liveLines.count > 200 { self.liveLines.removeFirst(self.liveLines.count - 200) }
                }
            }
        }
    }

    nonisolated private static func transcribe(_ samples: [Float], locale: Locale?) async -> [TimedPhrase] {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mochlet-chunk-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try ChannelRecorder.writeWAV(samples, to: tmp)
            return try await FileTranscriber.transcribe(tmp, locale: locale)
        } catch {
            return []
        }
    }

    func mark(_ text: String = "") {
        guard state == .recording, var m = current else { return }
        m.marks.append(MeetingMark(at: elapsed, text: text.trimmingCharacters(in: .whitespaces)))
        current = m
        try? Self.write(meta: m, in: folder)
        app.slime.stage.main.trigger(.wink)
        app.slime.sound.play(SoundCue(.blip))
    }

    func stop() {
        if state == .starting { cancelStart(); return }
        guard state == .recording, var m = current, let dir = folder else { return }
        liveTask?.cancel()
        mic?.stop()
        tap?.stop()
        mic = nil
        tap = nil
        m.endedAt = Date()
        m.durationS = elapsed
        m.processing.status = .processing
        current = m
        try? Self.write(meta: m, in: dir)
        app.slime.stage.main.setRecording(false)
        app.slime.stage.main.setAudioLevel(0)
        state = .processing
        stage = "closing the recordings"
        progress = 0
        let micRec = self.micRec, sysRec = self.sysRec
        self.micRec = nil
        self.sysRec = nil
        Task {
            await micRec?.close()
            await sysRec?.close()
            await process(m, in: dir, liveFallback: liveLines)
        }
    }

    // MARK: Processing

    /// Everything after the recording, also used to recover a folder found on launch.
    func process(_ meta: MeetingMeta, in dir: URL, liveFallback: [LiveLine] = []) async {
        state = .processing
        current = meta
        folder = dir
        error = nil
        app.window.hold("meeting", true)
        let brain = LLMClient.brain(app)
        let locale = await SpeechAssets.locale(for: meta.locale.isEmpty ? app.settings.voiceLocale : meta.locale)
        do {
            let result = try await MeetingProcessor.run(meta: meta, folder: dir, locale: locale, brain: brain, diarizer: LiteDiarizer()) { [weak self] st, p in
                Task { @MainActor in self?.stage = st; self?.progress = p }
            }
            var finished = Finished(meta: result.meta, summary: result.summary, lines: result.lines, folder: dir)
            last = finished
            finished.meta = try await fileInKnowledge(finished)
            last = finished
            if let e = result.meta.processing.error { logger.error("summary failed for \(result.meta.id, privacy: .public): \(e, privacy: .private)") }
            current = nil
            state = .review
            stage = ""
            reloadRecent()
            app.slime.stage.main.trigger(.proud)
            app.slime.sound.play(SoundCue(.finish))
            app.window.send(.openExternally(.meetingLive))
            logger.info("ready: \(result.meta.id, privacy: .public) (\(result.lines.count) lines, \(result.meta.speakers.count) speakers)")
        } catch {
            var m = meta
            m.processing.status = .failed
            m.processing.error = ErrorText.describe(error)
            try? Self.write(meta: m, in: dir)
            current = m
            fail("Couldn't write the notes: \(ErrorText.describe(error))")
            logger.error("failed: \(String(describing: error), privacy: .private)")
        }
    }

    /// The knowledge page: `meetings/<id>.md`, indexed, logged.
    @discardableResult
    private func fileInKnowledge(_ f: Finished) async throws -> MeetingMeta {
        let doc = MeetingWriter.knowledgePage(meta: f.meta, summary: f.summary, lines: f.lines, transcriptURL: f.transcriptURL, folderURL: f.folder)
        let rel = try await app.knowledge.engine.fileMeeting(doc, id: f.meta.id)
        var m = f.meta
        m.kbPath = rel
        try Self.write(meta: m, in: f.folder)
        if last?.meta.id == m.id { last?.meta = m }
        return m
    }

    /// The summary again when the brain failed the first time (timeout, bad JSON, no backend).
    var summaryError: String? {
        guard let e = last?.meta.processing.error, e.hasPrefix("summary: ") else { return nil }
        return String(e.dropFirst("summary: ".count))
    }

    func retrySummary() {
        guard let f = last, state == .review, stage.isEmpty else { return }
        guard let brain = LLMClient.brain(app) else { app.toast("No brain is configured. Settings → Chat.", symbol: "brain"); return }
        stage = "writing the summary"
        progress = 0.5
        Task {
            let (meta, summary) = await MeetingProcessor.resummarize(meta: f.meta, lines: f.lines, folder: f.folder, brain: brain) { [weak self] st, p in
                Task { @MainActor in self?.stage = st; self?.progress = p }
            }
            var g = f
            g.meta = meta
            g.summary = summary ?? f.summary
            if summary != nil { g.meta = (try? await fileInKnowledge(g)) ?? g.meta }
            last = g
            stage = ""
            reloadRecent()
            if let e = summaryError { app.toast("Summary failed again: \(e)", symbol: "exclamationmark.triangle") }
            else { app.slime.stage.main.trigger(.happy) }
        }
    }

    func retry() {
        guard let m = current, let dir = folder, state == .failed else { return }
        Task { await process(m, in: dir) }
    }

    func dismiss() {
        guard state == .review || state == .failed else { return }
        state = .idle
        error = nil
        app.window.hold("meeting", false)
        app.window.send(.collapse)
    }

    // MARK: Speaker map

    func rename(_ id: String, to name: String) {
        guard var f = last else { return }
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        f.meta.speakers = TranscriptBuilder.rename(f.lines, speakers: f.meta.speakers, id: id, to: clean)
        rewrite(f)
    }

    func merge(_ id: String, into target: String) {
        guard var f = last else { return }
        let (speakers, lines) = TranscriptBuilder.merge(f.lines, speakers: f.meta.speakers, id: id, into: target)
        f.meta.speakers = speakers
        f.lines = lines
        rewrite(f)
    }

    func acceptSuggestedName(_ id: String) {
        guard let s = last?.summary?.participants.first(where: { $0.speakerID == id })?.suggestedName else { return }
        rename(id, to: s)
    }

    private func rewrite(_ f: Finished) {
        Task {
            do {
                try MeetingProcessor.writeFiles(meta: f.meta, summary: f.summary, lines: f.lines, folder: f.folder)
                last = f
                try await fileInKnowledge(f)
                reloadRecent()
            } catch {
                app.toast("Could not rewrite the transcript: \(ErrorText.describe(error))", symbol: "exclamationmark.triangle")
            }
        }
    }

    func setTitle(_ title: String) {
        guard var f = last else { return }
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        f.meta.title = t
        f.meta.titleEdited = true
        if f.summary != nil { f.summary!.title = t }
        rewrite(f)
    }

    // MARK: Files

    static func write(meta: MeetingMeta, in dir: URL?) throws {
        guard let dir else { return }
        try MeetingMeta.encoder.encode(meta).write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
    }

    static func readMeta(_ dir: URL) -> MeetingMeta? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")) else { return nil }
        return try? MeetingMeta.decoder.decode(MeetingMeta.self, from: data)
    }

    static func readFinished(_ dir: URL) -> Finished? {
        guard let meta = readMeta(dir) else { return nil }
        let summary = (try? Data(contentsOf: dir.appendingPathComponent("summary.json"))).flatMap { try? JSONDecoder().decode(MeetingSummary.self, from: $0) }
        let lines = (try? String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)).map { text -> [MeetingLine] in
            let parsed = LarkTranscript.parse(text)
            let ids = Dictionary(uniqueKeysWithValues: meta.speakers.map { ($0.name, $0.id) })
            return parsed.lines.map { MeetingLine(speaker: ids[$0.speaker] ?? $0.speaker, start: $0.start, end: $0.end, text: $0.text) }
        } ?? []
        return Finished(meta: meta, summary: summary, lines: lines, folder: dir)
    }

    func reloadRecent() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? []
        recent = dirs.compactMap { Self.readFinished($0) }.filter { $0.meta.processing.status == .ready }.sorted { $0.meta.startedAt > $1.meta.startedAt }
    }

    /// Folders left recording or processing by a crash are finished now.
    private func recover() async {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            let micURL = dir.appendingPathComponent("mic.wav")
            let micSize = (try? micURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            var meta = Self.readMeta(dir)
            if meta == nil {
                // A folder cut off before its meta was written: nothing recorded → gone; audio → a meeting.
                guard fm.fileExists(atPath: micURL.path), !fm.fileExists(atPath: dir.appendingPathComponent("transcript.md").path) else { continue }
                if micSize < 64_000 { try? fm.removeItem(at: dir); continue }
                let created = (try? micURL.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                var m = MeetingMeta(id: dir.lastPathComponent, title: MeetingWriter.defaultTitle(app: MeetingApp(bundleID: nil, name: nil, windowTitle: nil), startedAt: created),
                                    startedAt: created, app: MeetingApp(bundleID: nil, name: nil, windowTitle: nil), locale: app.settings.voiceLocale, retention: app.settings.meetingRetention)
                m.audio.files = ["mic.wav", "system.wav"]
                m.processing.status = .recording
                meta = m
            }
            guard let meta, meta.processing.status == .recording || meta.processing.status == .processing else { continue }
            guard fm.fileExists(atPath: micURL.path) else { continue }
            if meta.processing.status == .recording, micSize < 64_000 { try? fm.removeItem(at: dir); continue }
            logger.info("recovering \(dir.lastPathComponent, privacy: .private)")
            await process(meta, in: dir)
            if state == .review { state = .idle; app.window.hold("meeting", false) }
        }
    }

    /// Audio past its keep-by date goes.
    func janitor(now: Date = Date()) {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            guard var meta = Self.readMeta(dir), let by = meta.audio.deleteAfter, by < now, !meta.audio.files.isEmpty else { continue }
            for f in meta.audio.files { try? fm.removeItem(at: dir.appendingPathComponent(f)) }
            meta.audio.files = []
            meta.audio.deleteAfter = nil
            try? Self.write(meta: meta, in: dir)
        }
    }

    // MARK: Debug

    func debugSignal() -> MeetingDetectionRules.Signal { detector?.signal() ?? MeetingDetectionRules.Signal(micApps: []) }

    /// Two recordings (any format) processed as a meeting, no microphone involved.
    func processFiles(mic: URL, system: URL?, title: String?) async -> String {
        guard state != .recording, state != .processing else { return "busy" }
        let started = Date()
        let t = title ?? "Replay \(mic.deletingPathExtension().lastPathComponent)"
        let id = MeetingWriter.slug(title: t, startedAt: started)
        let dir = Self.root.appendingPathComponent(id, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try ChannelRecorder.writeWAV(try ChannelRecorder.readSamples(mic), to: dir.appendingPathComponent("mic.wav"))
            if let system { try ChannelRecorder.writeWAV(try ChannelRecorder.readSamples(system), to: dir.appendingPathComponent("system.wav")) }
        } catch {
            return "failed to stage files: \(ErrorText.describe(error))"
        }
        var meta = MeetingMeta(id: id, title: t, startedAt: started, app: MeetingApp(name: "Replay"), locale: app.settings.voiceLocale, retention: app.settings.meetingRetention)
        meta.titleEdited = title != nil
        meta.audio.files = ["mic.wav", "system.wav"]
        await process(meta, in: dir)
        if let f = last, state == .review {
            return "ready \(f.folder.lastPathComponent) | \(f.lines.count) lines | speakers \(f.meta.speakers.map(\.name).joined(separator: ", ")) | kb \(f.meta.kbPath ?? "-") | \(OneLine.collapse(f.summary?.overview ?? "no summary", limit: 160))"
        }
        return "failed: \(error ?? "?")"
    }

    func openFolder(_ f: Finished? = nil) { NSWorkspace.shared.activateFileViewerSelecting([(f ?? last)?.folder ?? Self.root]) }
    func openTranscript(_ f: Finished? = nil) { if let u = (f ?? last)?.transcriptURL { NSWorkspace.shared.open(u) } }
    func openSummary(_ f: Finished? = nil) { if let u = (f ?? last)?.summaryURL { NSWorkspace.shared.open(u) } }

    // MARK: Prefs

    private var prefsURL: URL { Self.root.appendingPathComponent("prefs.json") }

    private func loadPrefs() {
        loadingPrefs = true
        defer { loadingPrefs = false }
        if let data = try? Data(contentsOf: prefsURL), let p = try? JSONDecoder().decode(MeetingPrefs.self, from: data) { prefs = p }
    }

    private func savePrefs() {
        guard !loadingPrefs else { return }
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        try? e.encode(prefs).write(to: prefsURL, options: .atomic)
    }

    private func fail(_ message: String) {
        error = message
        state = .failed
        app.slime.stage.main.setRecording(false)
        app.slime.stage.main.trigger(.confused)
        app.toast(message, symbol: "waveform.slash", seconds: 5)
        app.window.hold("meeting", true)
        app.window.send(.openExternally(.meetingLive))
    }
}
