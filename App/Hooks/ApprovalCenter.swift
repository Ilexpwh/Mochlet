import AppKit
import Observation
import SlimeKit
import MochletCore

/// Pending permission requests: the head is the card on screen; replies go back down the relay's socket.
@MainActor
@Observable
final class ApprovalCenter {
    private(set) var queue = ApprovalQueue()
    @ObservationIgnored private unowned let app: AppCoordinator
    @ObservationIgnored private var replies: [UUID: HookReply] = [:]
    @ObservationIgnored private var timeouts: [UUID: DispatchWorkItem] = [:]

    init(app: AppCoordinator) {
        self.app = app
    }

    var head: ApprovalRequest? { queue.head }
    var count: Int { queue.count }
    var isShowing: Bool { app.notch.mode == .expanded && app.notch.view == .approval && !queue.isEmpty }

    /// Who answers permission prompts from the notch: editor-hosted agents always, terminals by setting.
    private func wantsCard(_ e: HookEvent) -> Bool {
        if app.settings.observationPaused { return false }
        switch e.agent {
        case .codex, .copilot, .muse, .cursor, .hermes: return true
        default: break
        }
        if e.terminal.isCursor || e.terminal.isVSCode { return true }
        return app.settings.terminalCardsEnabled
    }

    func receive(_ e: HookEvent, reply: HookReply?) {
        guard let reply else { return }
        guard e.tool != "AskUserQuestion", wantsCard(e) else {
            reply.send(ApprovalDecision.ask.reply.any as! [String: Any])
            return
        }
        let request = ApprovalRequest(event: e)
        guard queue.enqueue(request) else {
            reply.send(ApprovalDecision.ask.reply.any as! [String: Any])
            return
        }
        replies[request.id] = reply
        let id = request.id
        reply.onHangup = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.hungUp(id) } }
        }
        let work = DispatchWorkItem { [weak self] in self?.timedOut(id) }
        timeouts[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + request.timeout, execute: work)
        app.sessions.apply(.hook(e))
        app.sessions.apply(.approvalPending(id: e.sessionID, count: queue.items.filter { $0.sessionID == e.sessionID }.count))
        app.slime.sound.play(SoundCue(.waiting))
        app.slime.stage.main.trigger(.surprised)
        show()
    }

    private func show() {
        guard !queue.isEmpty else { return }
        app.notch.focusedSessionID = queue.head?.sessionID
        app.window.hold("approval", true)
        if !app.questions.isShowing {
            app.window.send(.openExternally(.approval))
        }
    }

    /// The user chose on the card shown (the head).
    func decide(_ d: ApprovalDecision) {
        guard let r = queue.head else { return }
        app.window.send(.userInteracted)
        let reply = replies[r.id]
        let sent = reply?.send(d.reply.any as! [String: Any]) ?? false
        finish(r.id, note: nil)
        switch d {
        case .allow, .always, .planAuto, .planDefault:
            app.slime.sound.play(SoundCue(.approve))
            app.slime.stage.main.trigger(.happy)
        case .deny:
            app.slime.stage.main.trigger(.annoyed)
        case .ask:
            app.terminal.jump(to: app.sessions.card(r.sessionID))
        case .planChange:
            app.terminal.jump(to: app.sessions.card(r.sessionID))
        }
        if !sent { note("That request was already handled.") }
    }

    /// Later events from the same session mean the agent moved on (answered in the terminal).
    func resolve(by e: HookEvent) {
        for r in queue.resolved(by: e) {
            replies[r.id]?.close()
            finish(r.id, note: "Handled in \(r.terminal.terminalName ?? r.agent.displayName).")
        }
    }

    private func hungUp(_ id: UUID) {
        guard let r = queue.items.first(where: { $0.id == id }) else { return }
        finish(id, note: "Handled in \(r.terminal.terminalName ?? r.agent.displayName).")
    }

    private func timedOut(_ id: UUID) {
        guard let r = queue.items.first(where: { $0.id == id }) else { return }
        replies[id]?.close()
        finish(id, note: "Still waiting in \(r.terminal.terminalName ?? r.agent.displayName).")
    }

    private func finish(_ id: UUID, note text: String?) {
        guard let r = queue.remove(id: id) else { return }
        replies[id] = nil
        timeouts[id]?.cancel()
        timeouts[id] = nil
        app.sessions.apply(.approvalPending(id: r.sessionID, count: queue.items.filter { $0.sessionID == r.sessionID }.count))
        if let text { note(text) }
        if queue.isEmpty {
            app.window.hold("approval", false)
            if app.notch.view == .approval, app.notch.mode == .expanded {
                if app.questions.isShowing { app.window.send(.switchView(.question)) } else if text == nil { app.window.send(.collapse) } else { app.window.send(.switchView(.sessionDetail)) }
            }
        } else {
            show()
        }
    }

    private func note(_ text: String) {
        app.notch.showNote(text)
    }

    /// Answers everything with `ask` (observation paused, quitting).
    func releaseAll() {
        for r in queue.items {
            replies[r.id]?.send(ApprovalDecision.ask.reply.any as! [String: Any])
            finish(r.id, note: nil)
        }
    }
}
