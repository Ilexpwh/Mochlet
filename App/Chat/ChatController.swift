import AppKit
import Observation
import SlimeKit
import MochletCore

/// Threads, messages and streaming for the chat view. Providers come from settings and the keychain.
@MainActor
@Observable
final class ChatController {
    private(set) var threads: [ChatThread] = []
    private(set) var current: ChatThread?
    private(set) var messages: [ChatMessage] = []
    private(set) var isStreaming = false
    private(set) var streamingText = ""
    private(set) var streamingActivity: [String] = []
    private(set) var lastError: String?
    var pendingAttachments: [ChatAttachment] = []
    var input = ""
    private(set) var modelLists: [ChatProviderKind: [String]] = [:]
    private(set) var modelListError: String?
    @ObservationIgnored private unowned let app: AppCoordinator
    @ObservationIgnored private var repo: ChatRepository?
    @ObservationIgnored private var streamTask: Task<Void, Never>?

    init(app: AppCoordinator) {
        self.app = app
    }

    static var storeURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Mochlet/store.sqlite")
    }

    func start() {
        do {
            let dir = Self.storeURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            repo = try ChatRepository(db: try SQLiteDB(path: Self.storeURL.path))
            threads = try repo?.threads() ?? []
            if let t = threads.first, Date().timeIntervalSince(t.updatedAt) < 3600 { select(t) }
        } catch {
            lastError = "Chat history unavailable: \(error.localizedDescription)"
        }
    }

    var providerKind: ChatProviderKind {
        ChatProviderKind(rawValue: app.settings.chatProvider) ?? .claudeCLI
    }

    var model: String { app.settings.chatModel }

    func setProvider(_ k: ChatProviderKind) {
        guard k != providerKind else { return }
        app.settings.chatProvider = k.rawValue
        app.settings.chatModel = k.defaultModels.first ?? ""
        // A thread is bound to the backend that remembers it; switching starts a new one.
        if current != nil { newThread() }
    }

    func setModel(_ m: String) {
        app.settings.chatModel = m
        if var t = current { t.model = m; current = t; try? repo?.save(t) }
    }

    func models(for kind: ChatProviderKind) -> [String] {
        let listed = modelLists[kind] ?? []
        let base = listed.isEmpty ? kind.defaultModels : listed
        return base
    }

    func refreshModels(for kind: ChatProviderKind) {
        guard !kind.isCLI else { return }
        let provider = httpProvider(kind)
        Task { [weak self] in
            do {
                let list = try await provider.models()
                await MainActor.run { self?.modelLists[kind] = list; self?.modelListError = nil }
            } catch {
                await MainActor.run { self?.modelListError = error.localizedDescription }
            }
        }
    }

    // MARK: Threads

    func newThread(project: Project? = nil, cwd: String? = nil) {
        cancel()
        let t = ChatThread(provider: providerKind.rawValue, model: model, projectSlug: project?.slug, cwd: cwd ?? project?.primaryPath)
        current = t
        messages = []
        lastError = nil
    }

    func select(_ t: ChatThread) {
        cancel()
        current = t
        messages = (try? repo?.messages(threadID: t.id)) ?? []
        lastError = nil
        if let k = ChatProviderKind(rawValue: t.provider), k != providerKind { app.settings.chatProvider = k.rawValue; app.settings.chatModel = t.model }
    }

    func delete(_ t: ChatThread) {
        try? repo?.delete(threadID: t.id)
        threads.removeAll { $0.id == t.id }
        if current?.id == t.id { current = nil; messages = [] }
    }

    func attach(_ a: ChatAttachment) {
        pendingAttachments.removeAll { $0.id == a.id || ($0.kind == a.kind && $0.title == a.title) }
        pendingAttachments.append(a)
    }

    /// Text-like files become inline context (≤ 200 KB); others are referenced by path.
    func attachFile(_ url: URL) {
        let name = url.lastPathComponent
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if size <= 200_000, let text = try? String(contentsOf: url, encoding: .utf8), !text.contains("\0") {
            attach(ChatAttachment(kind: .file, title: name, text: text, path: url.path))
        } else {
            attach(ChatAttachment(kind: .file, title: name, text: "(\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) file at \(url.path))", path: url.path))
        }
    }

    func removeAttachment(_ id: String) { pendingAttachments.removeAll { $0.id == id } }

    // MARK: Sending

    func send(_ textOverride: String? = nil) {
        let text = (textOverride ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingAttachments.isEmpty, !isStreaming else { return }
        if textOverride == nil { input = "" }
        if current == nil { newThread() }
        guard var thread = current else { return }
        if messages.isEmpty { thread.title = String(OneLine.collapse(text.isEmpty ? (pendingAttachments.first?.title ?? "Chat") : text, limit: 48)) }
        thread.updatedAt = Date()
        current = thread
        let user = ChatMessage(threadID: thread.id, role: .user, text: text, attachments: pendingAttachments)
        pendingAttachments = []
        messages.append(user)
        persist(thread)
        try? repo?.save(user)
        lastError = nil
        stream(thread: thread)
    }

    func retryLast() {
        guard let last = messages.last, last.role == .assistant, last.error != nil, let thread = current else { return }
        messages.removeLast()
        stream(thread: thread)
    }

    func cancel() {
        guard isStreaming else { return }
        streamTask?.cancel()
        streamTask = nil
        finishStreaming(error: "Stopped.")
    }

    private func stream(thread: ChatThread) {
        let kind = ChatProviderKind(rawValue: thread.provider) ?? providerKind
        let provider: ChatProvider
        if kind.isCLI {
            let cli = CLIChatProvider(kind: kind)
            cli.onRateLimits = { info in Task { @MainActor in AppCoordinator.shared.plans.receive(claudeRateLimitEvent: info) } }
            provider = cli
        } else {
            if kind.needsKey, !KeychainStore.has(kind.keychainAccount) {
                finishStreaming(error: ChatProviderError.noKey(kind.displayName).localizedDescription, appendMessage: true)
                return
            }
            provider = httpProvider(kind)
        }
        let request = ChatRequest(messages: messages, system: systemPrompt(thread: thread), model: thread.model.isEmpty ? (kind.isCLI ? "" : (kind.defaultModels.first ?? "")) : thread.model,
                                  continuation: thread.continuation, cwd: thread.cwd)
        isStreaming = true
        streamingText = ""
        streamingActivity = []
        app.window.hold("chat", true)
        app.sessions.publish()
        let sessionID = kind == .claudeCLI && thread.continuation == nil ? UUID().uuidString : nil
        streamTask = Task { [weak self] in
            let events = (provider as? CLIChatProvider).map { $0.stream(request, sessionID: sessionID) } ?? provider.stream(request)
            var continuation: String? = sessionID
            var usage: ChatUsage?
            var failure: String?
            do {
                for try await ev in events {
                    if Task.isCancelled { break }
                    switch ev {
                    case .started(let c): if let c, !c.isEmpty { continuation = c }
                    case .textDelta(let t): self?.streamingText += t
                    case .activity(let a): self?.appendActivity(a)
                    case .usage(let u): usage = u
                    case .done: break
                    case .failed(let msg): failure = msg
                    }
                }
            } catch {
                failure = error.localizedDescription
            }
            guard let self, !Task.isCancelled else { return }
            if kind.isCLI, let continuation, var t = self.current, t.id == thread.id, t.continuation != continuation {
                t.continuation = continuation
                self.current = t
                self.persist(t)
            }
            self.finishStreaming(error: failure, usage: usage, appendMessage: true)
        }
    }

    private func appendActivity(_ a: String) {
        if streamingActivity.last != a { streamingActivity.append(a) }
        if streamingActivity.count > 12 { streamingActivity.removeFirst() }
    }

    private func finishStreaming(error: String? = nil, usage: ChatUsage? = nil, appendMessage: Bool = false) {
        guard isStreaming || appendMessage else { return }
        let text = streamingText
        if appendMessage, let thread = current {
            let reply = ChatMessage(threadID: thread.id, role: .assistant, text: text, activity: streamingActivity, error: error, usage: usage)
            messages.append(reply)
            try? repo?.save(reply)
            var t = thread
            t.updatedAt = Date()
            persist(t)
        }
        isStreaming = false
        streamingText = ""
        streamingActivity = []
        lastError = error
        app.window.hold("chat", false)
        app.sessions.publish()
        if let error, error != "Stopped." {
            app.slime.stage.main.trigger(.confused)
            app.slime.sound.play(SoundCue(.error))
        } else if error == nil, !text.isEmpty {
            app.slime.stage.main.trigger(.happy)
            app.slime.sound.play(SoundCue(.finish))
        }
    }

    private func persist(_ t: ChatThread) {
        current = t
        try? repo?.save(t)
        threads.removeAll { $0.id == t.id }
        threads.insert(t, at: 0)
    }

    private func httpProvider(_ kind: ChatProviderKind) -> HTTPChatProvider {
        HTTPChatProvider(kind: kind, baseURL: app.settings.baseURL(for: kind), apiKey: KeychainStore.get(kind.keychainAccount))
    }

    /// Who the slime is, plus what it can see: the project, live agent sessions and pending cards.
    func systemPrompt(thread: ChatThread) -> String {
        var lines = ["You are Mochlet, a small slime assistant that lives in the Mac notch. Answer briefly and concretely; use Markdown sparingly (short lists are fine, no headings)."]
        if let slug = thread.projectSlug, let p = app.projects.file.project(slug: slug) {
            lines.append("Current project: \(p.name) at \(p.primaryPath ?? "?")\(p.description.isEmpty ? "" : " — \(p.description)").")
        } else if let cwd = thread.cwd {
            lines.append("Working folder: \(cwd).")
        }
        let live = app.sessions.live
        if !live.isEmpty {
            lines.append("Coding agent sessions the user is running right now:")
            for c in live.suffix(6) {
                let state = c.state.rawValue
                let last = c.steps.last?.text ?? c.finalLine ?? ""
                lines.append("- \(c.agent.displayName) in \(c.project.name) (\(c.cwd)): \(state)\(last.isEmpty ? "" : " — \(last)")")
            }
        }
        if app.approvals.count > 0 { lines.append("\(app.approvals.count) permission request(s) are waiting for the user in the notch.") }
        let projects = app.projects.file.active
        if !projects.isEmpty { lines.append("Registered projects: " + projects.map(\.name).joined(separator: ", ") + ".") }
        return lines.joined(separator: "\n")
    }
}
