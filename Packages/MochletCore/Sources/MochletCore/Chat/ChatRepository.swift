import Foundation

/// Threads and messages in `store.sqlite`.
public final class ChatRepository: @unchecked Sendable {
    private let db: SQLiteDB
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    static let migrations: [String] = [
        """
        CREATE TABLE IF NOT EXISTS chat_threads (
            id TEXT PRIMARY KEY, title TEXT NOT NULL, provider TEXT NOT NULL, model TEXT NOT NULL,
            continuation TEXT, project TEXT, cwd TEXT, created_at REAL NOT NULL, updated_at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS chat_messages (
            id TEXT PRIMARY KEY, thread_id TEXT NOT NULL REFERENCES chat_threads(id) ON DELETE CASCADE,
            role TEXT NOT NULL, text TEXT NOT NULL, attachments_json TEXT NOT NULL DEFAULT '[]', activity_json TEXT NOT NULL DEFAULT '[]',
            error TEXT, usage_in INTEGER, usage_out INTEGER, created_at REAL NOT NULL);
        CREATE INDEX IF NOT EXISTS chat_messages_thread ON chat_messages(thread_id, created_at);
        """,
    ]

    public init(db: SQLiteDB) throws {
        self.db = db
        try db.migrate(Self.migrations)
    }

    public func threads(limit: Int = 50) throws -> [ChatThread] {
        try db.query("SELECT * FROM chat_threads ORDER BY updated_at DESC LIMIT ?", [.int(Int64(limit))]).map(Self.thread)
    }

    public func thread(id: String) throws -> ChatThread? {
        try db.query("SELECT * FROM chat_threads WHERE id = ?", [.text(id)]).first.map(Self.thread)
    }

    public func save(_ t: ChatThread) throws {
        try db.run("""
            INSERT INTO chat_threads (id, title, provider, model, continuation, project, cwd, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET title=excluded.title, provider=excluded.provider, model=excluded.model, continuation=excluded.continuation,
            project=excluded.project, cwd=excluded.cwd, updated_at=excluded.updated_at
            """, [.text(t.id), .text(t.title), .text(t.provider), .text(t.model), t.continuation.map { .text($0) } ?? .null,
                  t.projectSlug.map { .text($0) } ?? .null, t.cwd.map { .text($0) } ?? .null,
                  .double(t.createdAt.timeIntervalSince1970), .double(t.updatedAt.timeIntervalSince1970)])
    }

    public func delete(threadID: String) throws {
        try db.run("DELETE FROM chat_messages WHERE thread_id = ?", [.text(threadID)])
        try db.run("DELETE FROM chat_threads WHERE id = ?", [.text(threadID)])
    }

    public func messages(threadID: String) throws -> [ChatMessage] {
        try db.query("SELECT * FROM chat_messages WHERE thread_id = ? ORDER BY created_at, rowid", [.text(threadID)]).map(message)
    }

    public func save(_ m: ChatMessage) throws {
        let att = String(decoding: (try? encoder.encode(m.attachments)) ?? Data("[]".utf8), as: UTF8.self)
        let act = String(decoding: (try? encoder.encode(m.activity)) ?? Data("[]".utf8), as: UTF8.self)
        try db.run("""
            INSERT INTO chat_messages (id, thread_id, role, text, attachments_json, activity_json, error, usage_in, usage_out, created_at) VALUES (?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET text=excluded.text, attachments_json=excluded.attachments_json, activity_json=excluded.activity_json,
            error=excluded.error, usage_in=excluded.usage_in, usage_out=excluded.usage_out
            """, [.text(m.id), .text(m.threadID), .text(m.role.rawValue), .text(m.text), .text(att), .text(act),
                  m.error.map { .text($0) } ?? .null, m.usage.map { .int(Int64($0.inputTokens)) } ?? .null, m.usage.map { .int(Int64($0.outputTokens)) } ?? .null,
                  .double(m.createdAt.timeIntervalSince1970)])
    }

    private static func thread(_ r: [String: SQLValue]) -> ChatThread {
        ChatThread(id: r["id"]?.string ?? "", title: r["title"]?.string ?? "", provider: r["provider"]?.string ?? "", model: r["model"]?.string ?? "",
                   continuation: r["continuation"]?.string, projectSlug: r["project"]?.string, cwd: r["cwd"]?.string,
                   createdAt: Date(timeIntervalSince1970: r["created_at"]?.double ?? 0), updatedAt: Date(timeIntervalSince1970: r["updated_at"]?.double ?? 0))
    }

    private func message(_ r: [String: SQLValue]) -> ChatMessage {
        let att = (try? decoder.decode([ChatAttachment].self, from: Data((r["attachments_json"]?.string ?? "[]").utf8))) ?? []
        let act = (try? decoder.decode([String].self, from: Data((r["activity_json"]?.string ?? "[]").utf8))) ?? []
        var usage: ChatUsage?
        if let i = r["usage_in"]?.int, let o = r["usage_out"]?.int { usage = ChatUsage(inputTokens: i, outputTokens: o) }
        return ChatMessage(id: r["id"]?.string ?? "", threadID: r["thread_id"]?.string ?? "", role: ChatRole(rawValue: r["role"]?.string ?? "user") ?? .user,
                           text: r["text"]?.string ?? "", attachments: att, activity: act, error: r["error"]?.string, usage: usage,
                           createdAt: Date(timeIntervalSince1970: r["created_at"]?.double ?? 0))
    }
}
