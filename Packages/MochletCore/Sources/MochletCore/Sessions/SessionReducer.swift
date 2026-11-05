import Foundation

/// Side effects the app performs after a reduction.
public enum SessionEffect: Sendable, Equatable {
    case spawnMini(id: String)
    case setMini(id: String, state: SessionState)
    case mergeMini(id: String)
    case removeSession(id: String)
    case sound(String)
    case openIsland(NotchView, sessionID: String)
    case badge(id: String, state: SessionState)
    case mainEmote(String)
    case scheduleFinishedReset(id: String, after: TimeInterval)
    case cancelFinishedReset(id: String)
    case showNote(String)
}

/// Inputs beyond hook events.
public enum SessionInput: Sendable, Equatable {
    case hook(HookEvent)
    case finishedReset(id: String)
    case approvalPending(id: String, count: Int)
    case questionPending(id: String, pending: Bool)
    case sweep
    case endAll
}

/// Pure session bookkeeping: cards keyed by session id, ordered by last activity.
public struct SessionRegistry: Sendable, Equatable {
    public static let finishedReset: TimeInterval = 6
    public static let maxSilence: TimeInterval = 12 * 3600
    public static let maxTurnSilence: TimeInterval = 30 * 60
    public static let diffExpiry: TimeInterval = 3600

    public private(set) var cards: [String: SessionCard] = [:]
    public private(set) var order: [String] = []
    /// Whether the terminal hosting a session is frontmost (the app sets it before reducing).
    public var frontmostBundleID: String?

    public init() {}

    public var ordered: [SessionCard] { order.compactMap { cards[$0] } }
    public var live: [SessionCard] { ordered.filter { $0.state != .ended } }
    public var states: [SessionState] { live.map(\.state) }
    public func card(_ id: String) -> SessionCard? { cards[id] }
    public var workingCount: Int { cards.values.filter(\.isWorking).count }

    public mutating func reduce(_ input: SessionInput, now: Date) -> [SessionEffect] {
        switch input {
        case .hook(let e): return reduce(event: e, now: now)
        case .finishedReset(let id):
            guard var c = cards[id], c.state == .finished, !c.isWorking else { return [] }
            c.state = .idle
            c.badge = nil
            cards[id] = c
            return [.mergeMini(id: id)]
        case .approvalPending(let id, let count):
            guard var c = cards[id] else { return [] }
            c.pendingApprovals = count
            if count > 0 { c.state = .approval } else if c.state == .approval { c.state = c.isWorking ? .working : .idle }
            cards[id] = c
            return [.setMini(id: id, state: c.state)]
        case .questionPending(let id, let pending):
            guard var c = cards[id] else { return [] }
            if pending { c.state = .question } else if c.state == .question { c.state = c.isWorking ? .working : .idle }
            cards[id] = c
            return [.setMini(id: id, state: c.state)]
        case .sweep:
            return sweep(now: now)
        case .endAll:
            let ids = order
            cards.removeAll()
            order.removeAll()
            return ids.map { .removeSession(id: $0) }
        }
    }

    private mutating func touch(_ e: HookEvent, working: Bool, now: Date) -> (SessionCard, [SessionEffect]) {
        var fx: [SessionEffect] = []
        var c: SessionCard
        if let existing = cards[e.sessionID] {
            c = existing
        } else {
            c = SessionCard(id: e.sessionID, agent: e.agent, project: ProjectRef(name: e.projectName, path: e.sessionRoot ?? e.cwd), cwd: e.cwd, terminal: e.terminal, startedAt: now)
            order.append(e.sessionID)
            fx.append(.spawnMini(id: e.sessionID))
            fx.append(.sound("work"))
        }
        if let t = e.sessionTitle, !t.isEmpty { c.project.name = t }
        if !e.cwd.isEmpty { c.cwd = e.cwd }
        if e.terminal != TerminalIdentity() { c.terminal = e.terminal }
        if working {
            c.isWorking = true
            c.lastWorked = now
        }
        c.lastActivity = now
        if let i = order.firstIndex(of: c.id), i != order.count - 1 {
            order.remove(at: i)
            order.append(c.id)
        }
        cards[c.id] = c
        return (c, fx)
    }

    private mutating func reduce(event e: HookEvent, now: Date) -> [SessionEffect] {
        var fx = sweep(now: now)
        switch e.name {
        case .sessionStart:
            var (c, f) = touch(e, working: false, now: now)
            fx += f
            c.finalLine = nil
            if c.state == .ended || c.state == .finished { c.state = .idle }
            if e.agent == .hermes, let p = e.raw["platform"].string, p != "cli", !p.isEmpty {
                c.appendStep(p.prefix(1).uppercased() + p.dropFirst(), at: now)
            }
            cards[c.id] = c
            fx.append(.setMini(id: c.id, state: c.state))

        case .userPromptSubmit:
            var (c, f) = touch(e, working: true, now: now)
            fx += f
            fx.append(.cancelFinishedReset(id: c.id))
            c.finalLine = nil
            c.state = .thinking
            if let p = e.prompt, !p.isEmpty { c.appendStep(OneLine.collapse(p, limit: 60), at: now) }
            cards[c.id] = c
            fx.append(.setMini(id: c.id, state: .thinking))

        case .preToolUse:
            guard e.tool != "AskUserQuestion" else { return fx }
            var (c, f) = touch(e, working: true, now: now)
            fx += f
            fx.append(.cancelFinishedReset(id: c.id))
            c.finalLine = nil
            let tool = e.tool ?? ""
            let asks = tool == "ask_question" || tool.hasSuffix(":ask_question")
            c.state = asks ? .question : .working
            c.appendStep(TickerLabel.label(tool: tool, input: e.toolInput), at: now)
            cards[c.id] = c
            fx.append(.setMini(id: c.id, state: c.state))
            if asks { fx.append(.sound("question")); fx.append(.openIsland(.sessionDetail, sessionID: c.id)) }

        case .postToolUse:
            var (c, f) = touch(e, working: true, now: now)
            fx += f
            if c.state != .question { c.state = .working }
            if let d = Self.diff(from: e) { c.appendDiff(d, at: now) }
            cards[c.id] = c
            fx.append(.setMini(id: c.id, state: c.state))

        case .postToolUseFailure:
            var (c, f) = touch(e, working: true, now: now)
            fx += f
            c.state = .working
            c.appendStep("⚠ failed", at: now)
            cards[c.id] = c

        case .notification:
            var (c, f) = touch(e, working: false, now: now)
            fx += f
            let msg = e.message ?? ""
            let lower = msg.lowercased()
            if lower.contains("rate limit") || lower.contains("limite d") {
                c.state = .ratelimit
                fx.append(.sound("error"))
                fx.append(.setMini(id: c.id, state: .ratelimit))
            } else if msg.hasSuffix("?") {
                c.state = .question
                c.appendStep(OneLine.collapse(msg), at: now)
                fx.append(.sound("question"))
                fx.append(.setMini(id: c.id, state: .question))
            }
            cards[c.id] = c

        case .stop:
            var (c, f) = touch(e, working: false, now: now)
            fx += f
            c.isWorking = false
            c.lastWorked = now
            let text = OneLine.firstParagraph(e.lastAssistantMessage ?? e.message ?? "")
            if !text.isEmpty { c.appendStep(text, at: now) }
            c.state = .finished
            c.finalLine = text.isEmpty ? nil : text
            cards[c.id] = c
            let inFront = frontmostBundleID != nil && frontmostBundleID == c.terminal.terminalBundleID
            fx.append(.setMini(id: c.id, state: .finished))
            fx.append(.mainEmote("happy"))
            if inFront {
                fx.append(.badge(id: c.id, state: .finished))
            } else {
                fx.append(.sound("finish"))
                fx.append(.openIsland(.sessionDetail, sessionID: c.id))
            }
            fx.append(.scheduleFinishedReset(id: c.id, after: Self.finishedReset))

        case .stopFailure:
            var (c, f) = touch(e, working: false, now: now)
            fx += f
            c.isWorking = false
            c.state = .error
            c.finalLine = StopFailureDetail.detail(e.raw)
            if let l = c.finalLine { c.appendStep(l, at: now) }
            cards[c.id] = c
            fx.append(.setMini(id: c.id, state: .error))
            fx.append(.sound("error"))
            let inFront = frontmostBundleID != nil && frontmostBundleID == c.terminal.terminalBundleID
            fx.append(inFront ? .badge(id: c.id, state: .error) : .openIsland(.sessionDetail, sessionID: c.id))

        case .interrupt:
            var (c, f) = touch(e, working: false, now: now)
            fx += f
            c.isWorking = false
            c.state = .idle
            c.badge = nil
            cards[c.id] = c
            fx.append(.setMini(id: c.id, state: .idle))

        case .sessionEnd:
            guard var c = cards[e.sessionID] else { return fx }
            c.state = .ended
            c.isWorking = false
            c.finalLine = nil
            c.diffs.removeAll()
            cards[c.id] = c
            fx.append(.cancelFinishedReset(id: c.id))
            fx.append(.mergeMini(id: c.id))
            fx.append(.removeSession(id: c.id))
            cards[c.id] = nil
            order.removeAll { $0 == c.id }

        case .subagentStart:
            var (c, f) = touch(e, working: true, now: now)
            fx += f
            c.appendStep("+ subagent", kind: .subagent, at: now)
            cards[c.id] = c

        case .subagentStop:
            var (c, f) = touch(e, working: true, now: now)
            fx += f
            c.appendStep("• subagent done", kind: .subagent, at: now)
            cards[c.id] = c

        case .preCompact, .permissionRequest, .askUserQuestion, .statusLine, .unknown:
            break
        }
        return fx
    }

    /// Diff for a PostToolUse of Edit / MultiEdit / Write / apply_patch.
    public static func diff(from e: HookEvent) -> FileDiff? {
        let input = e.toolInput
        switch e.tool {
        case "Edit":
            guard let path = input["file_path"].string, let old = input["old_string"].string, let new = input["new_string"].string, old != new else { return nil }
            let d = DiffEngine.fromEdit(path: path, oldString: old, newString: new, replaceAll: input["replace_all"].bool ?? false)
            return d.added + d.removed > 0 ? d : nil
        case "MultiEdit":
            guard let path = input["file_path"].string, let edits = input["edits"].array else { return nil }
            var hunks: [DiffHunk] = []
            var added = 0, removed = 0, countsOnly = false
            for ed in edits {
                guard let old = ed["old_string"].string, let new = ed["new_string"].string, old != new else { continue }
                let d = DiffEngine.fromEdit(path: path, oldString: old, newString: new)
                hunks += d.hunks
                added += d.added
                removed += d.removed
                countsOnly = countsOnly || d.countsOnly
            }
            return added + removed > 0 ? FileDiff(path: path, added: added, removed: removed, hunks: hunks, countsOnly: countsOnly) : nil
        case "Write":
            guard let path = input["file_path"].string, let content = input["content"].string, !content.isEmpty else { return nil }
            return DiffEngine.fromNew(path: path, content: content)
        case "apply_patch":
            let text = input["command"].string ?? input["patch"].string ?? ""
            let ds = DiffEngine.fromApplyPatch(text)
            guard let first = ds.first else { return nil }
            if ds.count == 1 { return first }
            let added = ds.reduce(0) { $0 + $1.added }
            let removed = ds.reduce(0) { $0 + $1.removed }
            return FileDiff(path: "\(ds.count) files", added: added, removed: removed, hunks: ds.flatMap(\.hunks))
        default:
            return nil
        }
    }

    private mutating func sweep(now: Date) -> [SessionEffect] {
        var fx: [SessionEffect] = []
        for id in order {
            guard var c = cards[id] else { continue }
            let silence = now.timeIntervalSince(c.lastActivity)
            if silence > Self.maxSilence {
                cards[id] = nil
                fx.append(.mergeMini(id: id))
                fx.append(.removeSession(id: id))
                continue
            }
            if c.isWorking, silence > Self.maxTurnSilence {
                c.isWorking = false
                if c.state.isBusy { c.state = .idle; fx.append(.setMini(id: id, state: .idle)) }
            }
            if let last = c.diffs.last, now.timeIntervalSince(c.lastActivity) > Self.diffExpiry, !c.diffs.isEmpty {
                _ = last
                c.diffs.removeAll()
            }
            cards[id] = c
        }
        order.removeAll { cards[$0] == nil }
        return fx
    }
}
