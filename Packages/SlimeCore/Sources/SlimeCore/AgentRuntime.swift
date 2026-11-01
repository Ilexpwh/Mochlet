import Foundation

public enum AgentProvider: String, CaseIterable, Codable, Sendable {
    case codex, claude, pi
    public var title: String { switch self { case .codex: "Codex"; case .claude: "Claude Code"; case .pi: "Pi" } }
}

/// UI-facing events use Mochlet's normalized method/params envelope. Provider wire
/// envelopes stay inside adapters; an approval response is never forwarded blindly.
public protocol AgentRuntime: Sendable {
    var events: AsyncStream<JSONValue> { get }
    func prepare(project: Project, threadID: String?, readOnly: Bool) async throws -> String
    func send(threadID: String, text: String) async throws -> String
    func interrupt(threadID: String, turnID: String) async throws
    func reply(id: JSONValue, result: JSONValue) async throws
    func reject(id: JSONValue, message: String) async throws
    func readUsage() async throws -> JSONValue
    func stop() async
}

extension CodexRuntime: AgentRuntime {
    public nonisolated var events: AsyncStream<JSONValue> { client.events }
    public func reply(id: JSONValue, result: JSONValue) async throws { try await client.reply(id: id, result: result) }
    public func reject(id: JSONValue, message: String) async throws { try await client.reject(id: id, message: message) }
    public func readUsage() async throws -> JSONValue { try await client.call("account/rateLimits/read") }
    public func stop() async { await client.stop() }
}

public enum SessionRoute {
    public static func validate(task: WorkTask, project: Project) throws {
        guard AgentProvider(rawValue: task.provider) != nil else { throw MochletError.message("This task's agent provider is unavailable.") }
        if task.threadID != nil {
            if task.provider != AgentProvider.codex.rawValue, !task.sessionConfirmed {
                throw MochletError.message("The agent never confirmed this session. Start a new conversation instead of resuming an unverified session.")
            }
            if let cwd = task.sessionCWD { try ProjectResolver.verifyCWD(expected: cwd, actual: project.root) }
            else if task.provider != AgentProvider.codex.rawValue {
                throw MochletError.message("This session has no verified working-directory binding.")
            }
        }
    }
}
