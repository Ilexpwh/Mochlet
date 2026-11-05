import Foundation
import MochletCore

/// "Work on X: task" without a terminal window: runs the agent CLI in the background and feeds
/// its progress into the same session cards and mini slimes as hook-observed sessions, by
/// synthesising hook events. When the agent's own hooks are installed, both streams land on the
/// same session id and merge.
@MainActor
final class HeadlessRunner {
    struct Run {
        var id: String
        var agent: AgentKind
        var cwd: String
        var projectSlug: String?
        var sessionID: String
        var task: Task<Void, Never>?
        var text = ""
        var announced = false
    }

    private(set) var runs: [String: Run] = [:]
    private unowned let app: AppCoordinator

    init(app: AppCoordinator) { self.app = app }

    var count: Int { runs.count }

    @discardableResult
    func start(agent: AgentKind, project: Project?, cwd: String, task: String, resume: String?) -> String {
        let kind: ChatProviderKind = agent == .codex ? .codexCLI : agent == .gemini ? .geminiCLI : .claudeCLI
        let runID = UUID().uuidString
        let provisional = agent == .claude ? (resume ?? UUID().uuidString) : "headless-\(runID.prefix(8))"
        var run = Run(id: runID, agent: agent, cwd: cwd, projectSlug: project?.slug, sessionID: provisional)
        let provider = CLIChatProvider(kind: kind)
        provider.taskMode = true
        provider.onRateLimits = { info in Task { @MainActor in AppCoordinator.shared.plans.receive(claudeRateLimitEvent: info) } }
        let thread = ChatThread(provider: kind.rawValue, model: "", continuation: resume, projectSlug: project?.slug, cwd: cwd)
        let message = ChatMessage(threadID: thread.id, role: .user, text: task)
        let request = ChatRequest(messages: [message], system: nil, model: "", continuation: resume, cwd: cwd)
        if agent == .claude { announce(&run, prompt: task) }
        runs[runID] = run
        let stream = provider.stream(request, sessionID: agent == .claude && resume == nil ? provisional : nil)
        let t = Task { [weak self] in
            var failure: String?
            do {
                for try await ev in stream {
                    guard let self else { return }
                    guard var r = self.runs[runID] else { break }
                    switch ev {
                    case .started(let c):
                        if let c, !c.isEmpty, !r.announced { r.sessionID = c }
                        if !r.announced { self.announce(&r, prompt: task) }
                    case .activity(let a):
                        if !r.announced { self.announce(&r, prompt: task) }
                        self.emit(r, .preToolUse, tool: a)
                    case .textDelta(let t):
                        if !r.announced { self.announce(&r, prompt: task) }
                        r.text += t
                    case .usage: break
                    case .done: break
                    case .failed(let msg): failure = msg
                    }
                    self.runs[runID] = r
                }
            } catch {
                failure = error.localizedDescription
            }
            guard let self, var r = self.runs[runID] else { return }
            if !r.announced { self.announce(&r, prompt: task) }
            if let failure {
                self.emit(r, .stopFailure, raw: ["error_message": .string(failure)])
            } else {
                self.emit(r, .stop, raw: ["last_assistant_message": .string(r.text)])
            }
            if let slug = r.projectSlug { self.app.projects.recordSession(agent: r.agent, sessionID: r.sessionID, projectSlug: slug) }
            self.runs[runID] = r
            let delay = failure == nil ? self.app.settings.finishedLinger + 2 : 8
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated {
                    guard let r = AppCoordinator.shared.headless.runs[runID] else { return }
                    AppCoordinator.shared.headless.emit(r, .sessionEnd)
                    AppCoordinator.shared.headless.runs[runID] = nil
                }
            }
        }
        runs[runID]?.task = t
        return provisional
    }

    func stop(sessionID: String) {
        guard let (id, r) = runs.first(where: { $0.value.sessionID == sessionID }) else { return }
        r.task?.cancel()
        emit(r, .stopFailure, raw: ["error_message": .string("Stopped from the notch.")])
        emit(r, .sessionEnd)
        runs[id] = nil
    }

    func run(forSession id: String) -> Run? { runs.values.first { $0.sessionID == id } }

    private func announce(_ r: inout Run, prompt: String) {
        r.announced = true
        emit(r, .sessionStart)
        emit(r, .userPromptSubmit, raw: ["prompt": .string(prompt)])
    }

    private func emit(_ r: Run, _ name: HookEventName, tool: String? = nil, raw extra: [String: JSONValue] = [:]) {
        var raw: [String: JSONValue] = ["mochlet_transport": .string("headless"), "mochlet_runner": .string(r.id), "hook_event_name": .string(name.rawValue)]
        for (k, v) in extra { raw[k] = v }
        let e = HookEvent(name: name, rawName: name.rawValue, agent: r.agent, sessionID: r.sessionID, cwd: r.cwd, sessionRoot: r.cwd, tool: tool,
                          toolInput: .null, prompt: extra["prompt"]?.string, lastAssistantMessage: extra["last_assistant_message"]?.string, raw: .object(raw))
        app.sessions.apply(.hook(e))
    }
}
