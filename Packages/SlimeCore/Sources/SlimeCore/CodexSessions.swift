import Foundation
import GRDB

public struct StoredCodexSession: Sendable, Equatable, Identifiable {
    public let id: String
    public let cwd: String
    public let title: String
    public let preview: String
    public let source: String
    public let serverStatus: String
    public let updatedAt: Date
    public let observedAt: Date
    public var mayImport: Bool { ["notLoaded", "idle"].contains(serverStatus) }
}
public struct CodexSessionPage: Sendable {
    public let sessions: [StoredCodexSession]
    public let nextCursor: String?
}
public struct CodexHistoryPage: Sendable {
    public let session: StoredCodexSession
    public let text: String
    public let nextCursor: String?
}

/// Stored activity only: this independent app-server cannot establish another process's liveness or answer its approvals.
public actor CodexSessionCatalog {
    public typealias Request = @Sendable (String, JSONValue) async throws -> JSONValue
    private let request: Request
    private let client: RPCClient?
    public init(request: @escaping Request) { self.request = request; client = nil }
    private init(client: RPCClient) { self.client = client; request = { try await client.call($0, params: $1) } }
    public static func open(executable: String, project: Project) async throws -> CodexSessionCatalog {
        try ProjectResolver.validateRoot(project)
        let version = try await CommandProcess().run(executable: executable, arguments: ["--version"])
        guard version.status == 0, String(decoding: version.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "codex-cli 0.155.1" else {
            throw MochletError.message("Session browsing is verified for Codex CLI 0.155.1. Select that version before connecting.")
        }
        let client = RPCClient()
        do {
            try await CodexRuntime(client: client).connect(executable: executable, cwd: project.root)
            try Task.checkCancellation()
            return CodexSessionCatalog(client: client)
        } catch { await client.stop(); throw error }
    }
    public func stop() async { await client?.stop() }
    private func cursor(_ value: JSONValue) throws -> String? {
        if value == .null { return nil }
        guard let cursor = value.string, !cursor.isEmpty, cursor.utf8.count < 4096 else { throw MochletError.message("Invalid session history cursor.") }
        return cursor
    }
    private func metadata(_ value: JSONValue, project: Project) throws -> StoredCodexSession {
        guard let id = value["id"].string, UUID(uuidString: id) != nil,
              let cwd = value["cwd"].string, cwd.hasPrefix("/"),
              let source = value["source"].string, ["cli", "exec", "vscode", "appServer"].contains(source),
              let status = value["status"]["type"].string, ["notLoaded", "idle", "active", "systemError"].contains(status),
              let updated = value["updatedAt"].number, updated.isFinite,
              value["ephemeral"] == .bool(false) else { throw MochletError.message("Codex returned unsupported session metadata.") }
        try ProjectResolver.verifyCWD(expected: project.root, actual: cwd)
        let preview = String((value["preview"].string ?? "").prefix(1000))
        let name = value["name"].string?.trimmingCharacters(in: .whitespacesAndNewlines)
        return StoredCodexSession(id: id, cwd: URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path,
            title: String((name?.isEmpty == false ? name! : (preview.isEmpty ? "Untitled Codex session" : preview)).prefix(200)),
            preview: preview, source: source, serverStatus: status, updatedAt: Date(timeIntervalSince1970: updated), observedAt: Date())
    }
    public func list(project: Project, after: String? = nil) async throws -> CodexSessionPage {
        try ProjectResolver.validateRoot(project)
        var params: [String: JSONValue] = ["cwd": .string(project.root), "limit": .number(25), "sortKey": .string("updated_at"),
            "sortDirection": .string("desc"), "archived": .bool(false), "useStateDbOnly": .bool(true),
            "sourceKinds": .array(["cli", "exec", "vscode", "appServer"].map(JSONValue.string))]
        if let after { _ = try cursor(.string(after)); params["cursor"] = .string(after) }
        let reply = try await request("thread/list", .object(params))
        guard case let .array(rows) = reply["data"], rows.count <= 25 else { throw MochletError.message("Invalid or oversized session page.") }
        let sessions = try rows.map { try metadata($0, project: project) }
        guard Set(sessions.map(\.id)).count == sessions.count else { throw MochletError.message("Duplicate sessions in page. Refresh the list.") }
        let next = try cursor(reply["nextCursor"])
        guard next == nil || next != after else { throw MochletError.message("Session pagination repeated its cursor.") }
        return CodexSessionPage(sessions: sessions, nextCursor: next)
    }
    public func read(id: String, project: Project) async throws -> StoredCodexSession {
        guard UUID(uuidString: id) != nil else { throw MochletError.message("Invalid Codex session ID.") }
        try ProjectResolver.validateRoot(project)
        let reply = try await request("thread/read", .object(["threadId": .string(id), "includeTurns": .bool(false)]))
        let session = try metadata(reply["thread"], project: project)
        guard session.id == id else { throw MochletError.message("Codex returned a different session.") }
        return session
    }
    public func history(id: String, project: Project, after: String? = nil) async throws -> CodexHistoryPage {
        let session = try await read(id: id, project: project)
        var params: [String: JSONValue] = ["threadId": .string(id), "limit": .number(20), "sortDirection": .string("desc"), "itemsView": .string("full")]
        if let after { _ = try cursor(.string(after)); params["cursor"] = .string(after) }
        let reply = try await request("thread/turns/list", .object(params))
        guard case let .array(turns) = reply["data"], turns.count <= 20 else { throw MochletError.message("Invalid or oversized turn history page.") }
        var lines: [String] = []; var remaining = 100_000; var truncated = false
        for turn in turns {
            guard let turnID = turn["id"].string, let status = turn["status"].string,
                  ["completed", "interrupted", "failed", "inProgress"].contains(status), case let .array(items) = turn["items"] else { throw MochletError.message("Unsupported stored turn.") }
            lines.append("Turn \(turnID) · \(status)")
            for item in items.prefix(200) {
                let type = item["type"].string ?? "unknown"
                let content: String
                switch type {
                case "agentMessage", "plan": content = item["text"].string ?? ""
                case "userMessage": content = item["content"].array.compactMap { $0["text"].string }.joined(separator: "\n")
                case "commandExecution": content = (item["command"].string ?? "") + "\n" + (item["aggregatedOutput"].string ?? "")
                case "fileChange": content = item["changes"].array.compactMap { $0["path"].string }.joined(separator: "\n")
                default: content = "Stored \(type) item (details not rendered)."
                }
                let text = String(content.prefix(min(20_000, remaining)))
                if text.count < content.count { truncated = true }
                remaining -= text.count
                lines.append("[\(type)]\n\(text)")
                if remaining <= 0 { break }
            }
            if items.count > 200 { truncated = true }
            if remaining <= 0 { truncated = true; break }
        }
        // A moved/replaced session must not leak history into a different project during an async read.
        _ = try await read(id: id, project: project)
        let next = try cursor(reply["nextCursor"])
        guard next == nil || next != after else { throw MochletError.message("History pagination repeated its cursor.") }
        if truncated { lines.append("[Display truncated: at most 100,000 characters, 20,000 per item and 200 items per turn.]") }
        return CodexHistoryPage(session: session, text: lines.isEmpty ? "No persisted turns yet." : lines.joined(separator: "\n\n"), nextCursor: next)
    }
}

extension Store {
    public func importCodexSession(_ session: StoredCodexSession, project: Project, externalClientStopped: Bool) throws -> WorkTask {
        guard externalClientStopped, session.mayImport, UUID(uuidString: session.id) != nil,
              Date().timeIntervalSince(session.observedAt) < 60 else { throw MochletError.message("Refresh the session and stop its other client before importing it.") }
        try ProjectResolver.validateRoot(project)
        try ProjectResolver.verifyCWD(expected: project.root, actual: session.cwd)
        return try database.write { db in
            guard try Project.fetchOne(db, key: project.id)?.root == project.root else { throw MochletError.message("Project folder changed during import.") }
            let matches = try WorkTask.fetchAll(db, sql: "SELECT * FROM tasks WHERE provider='codex' AND threadID=?", arguments: [session.id])
            if let existing = matches.first {
                guard matches.count == 1, existing.projectID == project.id, existing.sessionCWD == project.root else {
                    throw MochletError.message("This session is already bound to another task destination.")
                }
                guard ![.queued, .running, .waiting].contains(existing.state) else { throw MochletError.message("This session already has active Mochlet work.") }
                return existing
            }
            var task = WorkTask(projectID: project.id, title: session.title)
            task.state = .interrupted; task.provider = "codex"; task.threadID = session.id
            task.sessionCWD = project.root; task.sessionConfirmed = true
            task.output = "Existing Codex session imported. Review its stored history in Sessions. No new turn has started."
            try task.insert(db)
            return task
        }
    }
}
