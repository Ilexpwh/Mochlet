import AppKit
import Observation
import SlimeKit
import MochletCore

/// One pending AskUserQuestion at a time, answered from the notch or handed back to the terminal.
@MainActor
@Observable
final class QuestionCenter {
    struct Pending {
        var event: HookEvent
        var question: AskQuestion
        var selections: [[String]]
        var otherText: String
        var index: Int
    }

    private(set) var pending: Pending?
    @ObservationIgnored private unowned let app: AppCoordinator
    @ObservationIgnored private var reply: HookReply?
    @ObservationIgnored private var timeout: DispatchWorkItem?
    static let timeoutSeconds: TimeInterval = 120

    init(app: AppCoordinator) {
        self.app = app
    }

    var isShowing: Bool { pending != nil && app.notch.mode == .expanded && app.notch.view == .question }

    func receive(_ e: HookEvent, question: AskQuestion?, reply: HookReply?) {
        guard let reply else { return }
        guard let question, !app.settings.observationPaused, app.settings.terminalCardsEnabled || e.agent != .claude || e.terminal.isCursor || e.terminal.isVSCode else {
            reply.send(["permissionDecision": "ask"])
            return
        }
        if pending != nil { handBack() }
        self.reply = reply
        pending = Pending(event: e, question: question, selections: Array(repeating: [], count: question.questions.count), otherText: "", index: 0)
        reply.onHangup = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.hungUp() } }
        }
        let work = DispatchWorkItem { [weak self] in self?.handBack(note: "Still waiting in the terminal.") }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeoutSeconds, execute: work)
        app.sessions.apply(.hook(e))
        app.sessions.apply(.questionPending(id: e.sessionID, pending: true))
        app.notch.focusedSessionID = e.sessionID
        app.slime.sound.play(SoundCue(.question))
        app.slime.stage.main.startQuestion()
        app.window.hold("question", true, scope: .card(.question))
        app.window.send(.openExternally(.question))
    }

    func toggle(_ label: String) {
        guard var p = pending else { return }
        let q = p.question.questions[p.index]
        var picks = p.selections[p.index]
        if q.multiSelect {
            if let i = picks.firstIndex(of: label) { picks.remove(at: i) } else { picks.append(label) }
        } else {
            picks = [label]
        }
        p.selections[p.index] = picks
        p.otherText = ""
        pending = p
        app.window.send(.userInteracted)
        if !q.multiSelect { advance() }
    }

    func setOther(_ text: String) {
        guard var p = pending else { return }
        p.otherText = text
        pending = p
    }

    func submitOther() {
        guard var p = pending, !p.otherText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        p.selections[p.index] = [p.otherText.trimmingCharacters(in: .whitespaces)]
        p.otherText = ""
        pending = p
        advance()
    }

    /// Next question, or send when this was the last one.
    func advance() {
        guard var p = pending else { return }
        if p.index + 1 < p.question.questions.count {
            p.index += 1
            pending = p
        } else {
            send()
        }
    }

    func back() {
        guard var p = pending, p.index > 0 else { return }
        p.index -= 1
        pending = p
    }

    func send() {
        guard let p = pending else { return }
        let answers = p.question.answers(selections: p.selections)
        let sent = reply?.send(["permissionDecision": "answer", "answers": answers.any]) ?? false
        app.slime.sound.play(SoundCue(.approve))
        app.slime.stage.main.trigger(.happy)
        finish(note: sent ? nil : "That question was already answered.")
    }

    /// "Reply in terminal", leaving the card, timeout: the agent asks in its own interface.
    func handBack(note: String? = nil) {
        guard pending != nil else { return }
        reply?.send(["permissionDecision": "ask"])
        if note == nil, let e = pending?.event { app.terminal.jump(to: app.sessions.card(e.sessionID)) }
        finish(note: note)
    }

    private func hungUp() {
        guard let e = pending?.event else { return }
        finish(note: "Handled in \(e.terminal.terminalName ?? e.agent.displayName).")
    }

    private func finish(note: String?) {
        guard let p = pending else { return }
        timeout?.cancel()
        timeout = nil
        reply = nil
        pending = nil
        app.sessions.apply(.questionPending(id: p.event.sessionID, pending: false))
        app.window.hold("question", false)
        if let note { app.notch.showNote(note) }
        if app.notch.view == .question, app.notch.mode == .expanded {
            if app.approvals.count > 0 {
                app.window.send(.switchView(.approval))
            } else if note == nil {
                app.window.send(.acknowledged())
            } else {
                app.window.send(.switchView(.sessionDetail))
                app.window.send(.acknowledged(delay: 2.4))
            }
        }
    }
}
