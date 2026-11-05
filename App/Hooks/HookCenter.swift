import Foundation
import MochletCore

/// Owns the socket server and routes every relay line to sessions, approvals, questions or plans.
@MainActor
final class HookCenter {
    private unowned let app: AppCoordinator
    private var server: HookSocketServer?
    private(set) var lineCount = 0
    private(set) var invalidCount = 0
    private(set) var lastError: String?
    private(set) var relayPath: URL?

    init(app: AppCoordinator) {
        self.app = app
    }

    var socketPath: String { HookSocketServer.socketPath }
    var isRunning: Bool { server != nil }

    func start() {
        relayPath = RelayInstaller.ensureInstalled()
        let server = HookSocketServer { line in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { AppCoordinator.shared.hooks.handle(line) }
            }
        }
        do {
            try server.start()
            self.server = server
        } catch {
            lastError = error.localizedDescription
            MochletLogger(category: "hooks").error("hook socket: \(error.localizedDescription)")
        }
    }

    func stop() {
        app.approvals.releaseAll()
        app.questions.handBack(note: "Mochlet quit.")
        server?.stop()
        server = nil
    }

    /// A line from the socket (or injected by the debug channel / replay script).
    func handle(_ line: HookLine) {
        lineCount += 1
        switch HookNormalizer.parse(line.data, now: line.receivedAt) {
        case .invalid(let why):
            invalidCount += 1
            lastError = why
            line.reply?.close()
        case .statusLine(let s):
            app.plans.receive(statusLine: s)
            line.reply?.send(["ok": true])
        case .event(let e):
            if app.settings.observationPaused { return }
            app.approvals.resolve(by: e)
            app.sessions.apply(.hook(e))
            if e.agent == .codex { app.installers.noteCodexEvent() }
        case .permission(let e):
            if app.settings.observationPaused {
                line.reply?.send(["permissionDecision": "ask"])
                return
            }
            app.approvals.receive(e, reply: line.reply)
        case .question(let e, let q):
            if app.settings.observationPaused {
                line.reply?.send(["permissionDecision": "ask"])
                return
            }
            app.questions.receive(e, question: q, reply: line.reply)
        }
    }

    /// Injects a JSON line as if the relay had sent it (debug channel, replay script).
    func inject(_ data: Data, reply: HookReply? = nil) {
        handle(HookLine(data: data, receivedAt: Date(), reply: reply))
    }
}
