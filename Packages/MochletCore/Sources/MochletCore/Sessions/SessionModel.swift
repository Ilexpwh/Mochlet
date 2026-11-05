import Foundation

/// What a session is doing, as the card and its mini slime show it.
public enum SessionState: String, Sendable, Codable {
    case idle, thinking, working, approval, question, finished, error, ratelimit, ended

    public var isBusy: Bool { self == .thinking || self == .working }
}

/// One ticker line.
public struct SessionStep: Sendable, Equatable, Codable, Identifiable {
    public enum Kind: Sendable, Equatable, Codable {
        case text
        case diff(id: String, name: String, added: Int, removed: Int)
        case subagent
    }
    public var id: Int
    public var text: String
    public var kind: Kind
    public var at: Date
    public init(id: Int, text: String, kind: Kind = .text, at: Date) {
        self.id = id
        self.text = text
        self.kind = kind
        self.at = at
    }
}

/// A project a session belongs to (the registry of milestone 5 fills `isRegistered`).
public struct ProjectRef: Sendable, Equatable, Codable, Hashable {
    public var name: String
    public var path: String
    public var isRegistered: Bool
    public init(name: String, path: String, isRegistered: Bool = false) {
        self.name = name
        self.path = path
        self.isRegistered = isRegistered
    }
}

/// How the app observes a session.
public enum SessionTransport: Sendable, Equatable, Codable {
    case observed
    case headless(runnerID: String)
}

/// A live coding-agent session: one card, one mini slime.
public struct SessionCard: Sendable, Equatable, Codable, Identifiable {
    public static let maxSteps = 20
    public static let maxDiffs = 50

    public var id: String
    public var agent: AgentKind
    public var project: ProjectRef
    public var cwd: String
    public var terminal: TerminalIdentity
    public var state: SessionState
    public var steps: [SessionStep]
    public var diffs: [FileDiff]
    public var finalLine: String?
    public var startedAt: Date
    public var lastActivity: Date
    public var lastWorked: Date
    public var isWorking: Bool
    public var transport: SessionTransport
    public var pendingApprovals: Int
    public var badge: SessionState?
    public var stepCounter: Int

    public init(id: String, agent: AgentKind, project: ProjectRef, cwd: String, terminal: TerminalIdentity, state: SessionState = .idle,
                startedAt: Date, transport: SessionTransport = .observed) {
        self.id = id
        self.agent = agent
        self.project = project
        self.cwd = cwd
        self.terminal = terminal
        self.state = state
        steps = []
        diffs = []
        finalLine = nil
        self.startedAt = startedAt
        lastActivity = startedAt
        lastWorked = .distantPast
        isWorking = false
        self.transport = transport
        pendingApprovals = 0
        badge = nil
        stepCounter = 0
    }

    public var label: String { project.name }
    public var tickerText: String { steps.last?.text ?? (state == .finished ? (finalLine ?? "Done") : "") }

    public mutating func appendStep(_ text: String, kind: SessionStep.Kind = .text, at: Date) {
        stepCounter += 1
        steps.append(SessionStep(id: stepCounter, text: text, kind: kind, at: at))
        if steps.count > Self.maxSteps { steps.removeFirst(steps.count - Self.maxSteps) }
    }

    public mutating func appendDiff(_ d: FileDiff, at: Date) {
        diffs.append(d)
        if diffs.count > Self.maxDiffs { diffs.removeFirst(diffs.count - Self.maxDiffs) }
        appendStep("\(d.name) \(d.summary)", kind: .diff(id: d.id, name: d.name, added: d.added, removed: d.removed), at: at)
    }
}

/// The notch's overall mood from all sessions: the most urgent state wins.
public enum SlimeMoodPolicy {
    public static func aggregate(_ states: [SessionState]) -> SessionState {
        let priority: [SessionState] = [.approval, .question, .error, .ratelimit, .working, .thinking, .finished, .idle]
        for p in priority where states.contains(p) { return p }
        return .idle
    }
}
