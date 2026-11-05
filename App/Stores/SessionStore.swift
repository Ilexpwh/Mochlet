import AppKit
import Observation
import SlimeKit
import MochletCore

/// Live sessions and the mini slimes that embody them. Reductions are pure (`SessionRegistry`);
/// this store performs the effects: stage, sounds, island, timers.
@MainActor
@Observable
final class SessionStore {
    private(set) var registry = SessionRegistry()
    private(set) var cards: [SessionCard] = []
    @ObservationIgnored private unowned let app: AppCoordinator
    @ObservationIgnored private var resetWork: [String: DispatchWorkItem] = [:]
    @ObservationIgnored private var sweepTimer: Timer?
    @ObservationIgnored private(set) var eventCount = 0
    @ObservationIgnored private(set) var lastEventAt: Date?

    init(app: AppCoordinator) {
        self.app = app
    }

    func start() {
        let t = Timer(timeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { AppCoordinator.shared.sessions.apply(.sweep) }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        sweepTimer = t
    }

    var live: [SessionCard] { cards.filter { $0.state != .ended } }
    func card(_ id: String?) -> SessionCard? { id.flatMap { registry.card($0) } }
    var focused: SessionCard? { card(app.notch.focusedSessionID) ?? live.last }
    var mostRecent: SessionCard? { live.last }
    /// Sessions that have something waiting for the user, most recent first.
    var pending: [SessionCard] { live.filter { $0.state == .approval || $0.state == .question }.reversed() }

    func apply(_ input: SessionInput) {
        registry.frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let now = Date()
        if case .hook = input {
            eventCount += 1
            lastEventAt = now
        }
        let effects = registry.reduce(input, now: now)
        for e in effects { perform(e) }
        publish()
    }

    private func perform(_ e: SessionEffect) {
        let stage = app.slime.stage
        switch e {
        case .spawnMini(let id):
            stage.spawnMini(id: id)
        case .setMini(let id, let state):
            stage.setMiniState(id, Self.agentState(state))
        case .mergeMini(let id):
            if registry.card(id) == nil { stage.removeMini(id) } else { stage.setMiniState(id, .idle) }
        case .removeSession(let id):
            stage.removeMini(id)
            resetWork[id]?.cancel()
            resetWork[id] = nil
            if app.notch.focusedSessionID == id { app.notch.focusedSessionID = nil }
        case .sound(let name):
            if let s = SlimeSound(rawValue: name) { app.slime.sound.play(SoundCue(s)) }
        case .openIsland(let view, let id):
            app.notch.focusedSessionID = id
            if app.approvals.isShowing || app.questions.isShowing { return }
            app.window.send(.openExternally(view))
        case .badge(let id, _):
            app.notch.focusedSessionID = id
        case .mainEmote(let name):
            if let em = SlimeEmote(rawValue: name) { stage.main.trigger(em) }
        case .scheduleFinishedReset(let id, _):
            resetWork[id]?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.resetWork[id] = nil
                self.apply(.finishedReset(id: id))
            }
            resetWork[id] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + app.settings.finishedLinger, execute: work)
        case .cancelFinishedReset(let id):
            resetWork[id]?.cancel()
            resetWork[id] = nil
        case .showNote(let text):
            app.notch.showNote(text)
        }
    }

    /// Pushes derived values to the notch store and the main slime's mood.
    func publish() {
        cards = registry.ordered
        let notch = app.notch
        let liveCards = live
        notch.miniCount = liveCards.count
        notch.overflowCount = app.slime.stage.overflowCount
        if let f = notch.focusedSessionID, registry.card(f) == nil { notch.focusedSessionID = nil }
        let tickerCard = card(notch.hoveredMiniID) ?? focused
        notch.tickerText = tickerCard.map { Self.ticker($0) } ?? ""
        let mood = SlimeMoodPolicy.aggregate(liveCards.map(\.state))
        let main = app.slime.stage.main
        let wanted = Self.mainState(mood)
        if main.agentState != wanted { main.agent(wanted) }
    }

    static func ticker(_ c: SessionCard) -> String {
        let step = c.state == .finished ? (c.finalLine ?? "Done") : c.state == .approval ? "Waiting for your approval" : c.state == .question ? "Has a question" : c.tickerText
        return step.isEmpty ? c.label : "\(c.label) · \(step)"
    }

    static func agentState(_ s: SessionState) -> AgentState {
        switch s {
        case .idle, .ended: return .idle
        case .thinking: return .thinking
        case .working: return .working
        case .approval, .question: return .waiting
        case .finished: return .finished
        case .error, .ratelimit: return .error
        }
    }

    /// The main slime mirrors the most urgent session, but celebrates finishes with an emote instead.
    static func mainState(_ s: SessionState) -> AgentState {
        switch s {
        case .approval, .question: return .waiting
        case .error, .ratelimit: return .error
        case .working: return .working
        case .thinking: return .thinking
        default: return .idle
        }
    }

    func endAll() {
        apply(.endAll)
    }
}
