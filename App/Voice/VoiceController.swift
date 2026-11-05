import AppKit
import AVFoundation
import Foundation
import MochletCore
import MochletServices

/// Push-to-talk: hold the slime (or ⌃⌥V), speak, release. The words show as they form, then the intent
/// router decides what they ask for and the app does it. Assets download on first use per language.
@MainActor
@Observable
final class VoiceController {
    enum State: Equatable, CustomStringConvertible {
        case idle, preparing, listening, processing, waiting, failed
        var description: String {
            switch self {
            case .idle: return "idle"
            case .preparing: return "preparing"
            case .listening: return "listening"
            case .processing: return "processing"
            case .waiting: return "waiting"
            case .failed: return "failed"
            }
        }
    }

    /// One more answer is needed (which project?) before the intent can run.
    struct Pending: Equatable {
        var intent: RoutedIntent
        var question: String
        var deadline: Date
    }

    private(set) var state: State = .idle
    private(set) var finals: [String] = []
    private(set) var caption = ""
    private(set) var level: Double = 0
    private(set) var lastHeard = ""
    private(set) var lastIntent: RoutedIntent?
    private(set) var lastAction: String?
    private(set) var error: String?
    private(set) var pending: Pending?
    private(set) var localeID = ""
    private(set) var assetState: SpeechAssets.State?
    private(set) var downloadProgress: Double?

    @ObservationIgnored private unowned let app: AppCoordinator
    @ObservationIgnored private let capture = VoiceCapture()
    @ObservationIgnored private var transcriber: LiveTranscriber?
    @ObservationIgnored private var releasedEarly = false
    @ObservationIgnored private var pendingWork: Task<Void, Never>?
    @ObservationIgnored private var failWork: Task<Void, Never>?
    @ObservationIgnored private var session = 0

    init(app: AppCoordinator) { self.app = app }

    var transcript: String {
        var parts = finals
        if !caption.isEmpty { parts.append(caption) }
        return Self.join(parts)
    }
    var isActive: Bool { state == .preparing || state == .listening || state == .processing }
    var hasSpeech: Bool { !transcript.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Phrases join with a space unless the seam is CJK.
    static func join(_ parts: [String]) -> String {
        var out = ""
        for p in parts {
            let t = p.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            if out.isEmpty { out = t; continue }
            let seam = (out.last.map(Self.isCJK) ?? false) || (t.first.map(Self.isCJK) ?? false)
            out += (seam ? "" : " ") + t
        }
        return out
    }

    static func isCJK(_ c: Character) -> Bool {
        guard let s = c.unicodeScalars.first else { return false }
        return (0x3000...0x9FFF).contains(s.value) || (0xF900...0xFAFF).contains(s.value) || (0xFF00...0xFFEF).contains(s.value)
    }

    // MARK: Push-to-talk

    func begin() {
        guard state == .idle || state == .failed || state == .waiting else { return }
        failWork?.cancel()
        session += 1
        let s = session
        releasedEarly = false
        finals = []
        caption = ""
        error = nil
        level = 0
        state = .preparing
        app.window.hold("voice", true)
        Task { await prepareAndListen(session: s) }
    }

    private func prepareAndListen(session s: Int) async {
        if VoiceCapture.permissionDenied { fail(VoiceError.permissionDenied.description); return }
        if !VoiceCapture.permissionGranted {
            guard await VoiceCapture.requestPermission() else { fail(VoiceError.permissionDenied.description); return }
        }
        guard s == session else { return }
        guard let locale = await SpeechAssets.locale(for: app.settings.voiceLocale) else {
            fail("Speech recognition is not available for that language on this Mac."); return
        }
        localeID = locale.identifier(.bcp47)
        if !(await LiveTranscriber.isReady(locale)) {
            let st = await SpeechAssets.state(locale)
            assetState = st
            switch st {
            case .installed: break
            case .downloadable, .downloading:
                startDownload(locale)
                fail("Downloading \(Self.name(locale)) speech (\(Int((downloadProgress ?? 0) * 100))%); try again in a moment.")
                return
            case .unsupported:
                fail("\(Self.name(locale)) speech recognition is not supported on this Mac."); return
            }
        }
        guard s == session else { return }
        do {
            let t = try await LiveTranscriber(locale: locale)
            transcriber = t
            try await t.start { [weak self] seg in Task { @MainActor in self?.receive(seg, session: s) } }
            try capture.start(format: t.format, sink: { buf in t.feed(buf) }, level: { [weak self] l in Task { @MainActor in self?.setLevel(l, session: s) } })
        } catch {
            fail(ErrorText.describe(error)); return
        }
        guard s == session else {
            capture.stop()
            let t = transcriber
            transcriber = nil
            Task { await t?.cancel() }
            return
        }
        state = .listening
        if releasedEarly { end() }
    }

    private func receive(_ seg: LiveSegment, session s: Int) {
        guard s == session else { return }
        let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if seg.isFinal {
            if !text.isEmpty { finals.append(text) }
            caption = ""
        } else {
            caption = text
        }
    }

    private func setLevel(_ l: Double, session s: Int) {
        guard s == session, state == .listening else { return }
        level = l
        app.slime.stage.main.setAudioLevel(l)
    }

    func end() {
        switch state {
        case .preparing: releasedEarly = true; return
        case .listening: break
        default: return
        }
        let s = session
        capture.stop()
        state = .processing
        level = 0
        app.slime.stage.main.setAudioLevel(0)
        Task {
            await transcriber?.finish()
            transcriber = nil
            guard s == session else { return }
            let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            caption = ""
            lastHeard = text
            app.slime.stage.main.stopListening(hadSpeech: !text.isEmpty)
            if text.isEmpty {
                state = .idle
                app.window.hold("voice", false)
                return
            }
            await route(text)
        }
    }

    func cancel() {
        guard isActive || state == .waiting || state == .failed else { return }
        session += 1
        capture.stop()
        let t = transcriber
        transcriber = nil
        Task { await t?.cancel() }
        pending = nil
        pendingWork?.cancel()
        caption = ""
        finals = []
        level = 0
        app.slime.stage.main.setAudioLevel(0)
        app.slime.stage.main.stopListening(hadSpeech: false)
        state = .idle
        app.window.hold("voice", false)
    }

    /// Debug and tests: an audio file plays the part of the microphone.
    func beginFromFile(_ url: URL) {
        guard state == .idle || state == .failed else { return }
        session += 1
        let s = session
        finals = []
        caption = ""
        error = nil
        state = .preparing
        app.window.hold("voice", true)
        app.slime.stage.main.startListening()
        app.window.send(.voiceStart)
        Task {
            guard let locale = await SpeechAssets.locale(for: app.settings.voiceLocale) else { fail("No speech locale."); return }
            localeID = locale.identifier(.bcp47)
            do {
                let t = try await LiveTranscriber(locale: locale)
                transcriber = t
                try await t.start { [weak self] seg in Task { @MainActor in self?.receive(seg, session: s) } }
                state = .listening
                let file = try AVAudioFile(forReading: url)
                guard let conv = AVAudioConverter(from: file.processingFormat, to: t.format) else { throw VoiceError.noFormat }
                // Real-time replay: each buffer waits its own duration so the caption forms as it would from a microphone.
                let rate = file.processingFormat.sampleRate
                while s == session, file.framePosition < file.length {
                    guard let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { break }
                    try file.read(into: inBuf)
                    if inBuf.frameLength == 0 { break }
                    if let out = VoiceCapture.convert(inBuf, with: conv, to: t.format) { t.feed(out) }
                    setLevel(VoiceCapture.level(of: inBuf), session: s)
                    try await Task.sleep(for: .milliseconds(Int(Double(inBuf.frameLength) / rate * 1000)))
                }
                guard s == session else { return }
                app.window.send(.voiceEnd)
                end()
            } catch {
                fail(ErrorText.describe(error))
            }
        }
    }

    private func fail(_ message: String) {
        error = message
        state = .failed
        capture.stop()
        level = 0
        app.slime.stage.main.setAudioLevel(0)
        app.slime.stage.main.stopListening(hadSpeech: false)
        app.toast(message, symbol: "mic.slash", seconds: 4)
        failWork?.cancel()
        failWork = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled, self.state == .failed else { return }
            self.state = .idle
            self.app.window.hold("voice", false)
        }
    }

    // MARK: Assets

    static func name(_ locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    func refreshAssetState() {
        Task {
            guard let locale = await SpeechAssets.locale(for: app.settings.voiceLocale) else { assetState = .unsupported; localeID = ""; return }
            localeID = locale.identifier(.bcp47)
            assetState = await SpeechAssets.state(locale)
        }
    }

    func downloadAssets() {
        Task {
            guard let locale = await SpeechAssets.locale(for: app.settings.voiceLocale) else { return }
            startDownload(locale)
        }
    }

    private func startDownload(_ locale: Locale) {
        guard downloadProgress == nil else { return }
        downloadProgress = 0
        assetState = .downloading
        app.notch.cardNote = "Downloading \(Self.name(locale)) speech…"
        Task {
            do {
                try await SpeechAssets.install(locale) { p in Task { @MainActor in self.downloadProgress = p } }
                assetState = .installed
                app.toast("\(Self.name(locale)) speech is ready. Hold me and talk.", symbol: "mic")
            } catch {
                assetState = .downloadable
                app.toast("Speech download failed: \(ErrorText.describe(error))", symbol: "mic.slash", seconds: 4)
            }
            downloadProgress = nil
            app.notch.cardNote = nil
        }
    }

    // MARK: Routing

    /// Typed or transcribed words go the same way.
    func handle(text: String) async {
        await route(text)
    }

    private func route(_ raw: String) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        state = .processing
        app.window.hold("voice", true)
        lastHeard = text
        app.notch.askText = text
        if let p = pending {
            pending = nil
            pendingWork?.cancel()
            await answer(p, with: text)
            return
        }
        let ctx = context()
        var routed = IntentRouter.prepass(text, context: ctx)
        if routed == nil {
            let req = IntentRouter.request(text, context: ctx)
            if let a = await Decisions.decide(req, app: app) {
                routed = IntentRouter.fill(a, text: text, context: ctx)
            } else {
                routed = RoutedIntent(intent: .ask, text: text, confidence: 0, backend: "none")
            }
        }
        lastIntent = routed
        await act(routed!)
    }

    private func context() -> IntentRouter.Context {
        let pb = NSPasteboard.general
        var clip: URL?
        if let s = pb.string(forType: .string), let u = IntentRouter.firstURL(in: s) { clip = u }
        if clip == nil, let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL] { clip = urls.first { $0.scheme?.hasPrefix("http") == true } }
        let chatFocused = app.notch.mode == .expanded && app.notch.view == .chat
        return IntentRouter.Context(clipboardURL: clip, chatFocused: chatFocused, projects: app.projects.projects)
    }

    private func act(_ r: RoutedIntent) async {
        switch r.intent {
        case .cancel:
            done("cancelled")
            app.window.send(.collapse)
        case .ask:
            done("chat")
            app.notch.askText = ""
            app.openChat()
            app.chat.send(r.text)
        case .kbQuery:
            done("knowledge")
            app.notch.askText = ""
            app.openKnowledge(question: r.text)
        case .projectStart:
            if let p = r.project ?? (app.projects.projects.count == 1 ? app.projects.projects.first : nil) {
                done("work on \(p.name)")
                app.notch.askText = ""
                if (r.task ?? "").isEmpty { app.handle(.resume(project: p.name, agent: nil)) } else { app.handle(.workOn(project: p.name, task: r.task ?? "", agent: nil)) }
                speak("On it", language: "en")
            } else if app.projects.projects.isEmpty {
                done("no projects")
                app.toast("No projects yet. Drop a folder on me to add one.", symbol: "folder.badge.questionmark")
            } else {
                ask(r, "Which project?")
            }
        case .projectCreate:
            done("project")
            if let path = r.path { app.handle(.makeProject(path: path, name: r.name)) }
            else if let u = r.url { app.handle(.clone(url: u.absoluteString, name: r.name)) }
            else { app.openProjects(focusNew: true) }
        case .ingestURL:
            if let u = r.url {
                done("chew \(u.host ?? "link")")
                app.notch.askText = ""
                Task { _ = await app.knowledge.add(.link(u), from: "voice") }
            } else {
                done("no link")
                app.toast("No link in what you said or on the clipboard.", symbol: "link")
            }
        case .note:
            let body = (r.task ?? "").isEmpty ? r.text : r.task!
            do {
                let rel = try await app.knowledge.engine.appendNote(body, source: "voice")
                done("note → \(rel)")
                app.notch.askText = ""
                app.slime.stage.main.trigger(.happy)
                app.toast("Noted.", symbol: "note.text")
                speak("Noted", language: "en")
            } catch {
                fail("Could not write the note: \(ErrorText.describe(error))")
            }
        case .settingsOpen:
            done("settings")
            app.openSettings()
        case .meetingStart, .meetingStop:
            done("meeting")
            app.toggleMeetingNotes()
        case .signalsShow:
            done("signals")
            app.toast("The AI signals digest arrives with milestone 10.", symbol: "antenna.radiowaves.left.and.right")
        case .dictate:
            done("dictate")
            if app.notch.view == .chat {
                app.chat.input += (app.chat.input.isEmpty ? "" : " ") + r.text
                app.openChat()
            } else {
                app.notch.askText = r.text
                app.window.send(.openExternally(.ask))
                app.window.focusInput()
            }
        }
    }

    private func done(_ action: String) {
        lastAction = action
        state = .idle
        app.window.hold("voice", false)
    }

    private func ask(_ r: RoutedIntent, _ question: String) {
        pending = Pending(intent: r, question: question, deadline: Date().addingTimeInterval(20))
        state = .waiting
        lastAction = "asking: \(question)"
        app.window.hold("voice", true)
        app.window.send(.openExternally(.ask))
        app.slime.stage.main.startQuestion()
        pendingWork?.cancel()
        pendingWork = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, !Task.isCancelled, self.pending != nil else { return }
            self.pending = nil
            self.done("question expired")
            self.app.window.send(.collapse)
        }
    }

    /// A chip tap or the next push-to-talk answers the pending question.
    func answerPending(project: Project?) {
        guard let p = pending else { return }
        pending = nil
        pendingWork?.cancel()
        guard let project else { done("cancelled"); app.window.send(.collapse); return }
        var r = p.intent
        r.project = project
        Task { await act(r) }
    }

    private func answer(_ p: Pending, with text: String) async {
        let lower = text.lowercased()
        if IntentRouter.isCancel(lower) { done("cancelled"); app.window.send(.collapse); return }
        let project = app.projects.match(text) ?? IntentRouter.bestProject(in: text, context: context())?.0
        guard let project else {
            fail("No project called “\(text)”. I know: \(app.projects.projects.map(\.name).prefix(4).joined(separator: ", ")).")
            return
        }
        var r = p.intent
        r.project = project
        await act(r)
    }

    private func speak(_ text: String, language: String) {
        guard app.settings.voiceSpeakReplies else { return }
        SpeechSynth.shared.speak(text, language: language)
    }
}
