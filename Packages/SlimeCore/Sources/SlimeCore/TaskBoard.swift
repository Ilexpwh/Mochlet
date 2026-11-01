import Foundation
import GRDB

public enum TaskPriority: Int, Codable, CaseIterable, Sendable {
    case low, normal, high, urgent
    public var title: String { switch self { case .low: "Low"; case .normal: "Normal"; case .high: "High"; case .urgent: "Urgent" } }
}
public struct TaskDetails: Codable, Equatable, Sendable {
    public var taskID: String
    public var version = 0
    public var priority = TaskPriority.normal
    public var dueAt: Double?
    public var description = ""
    public var parentID: String?
    public var dependencies: Set<String> = []
    public init(taskID: String) { self.taskID = taskID }
}
public struct TaskComment: Codable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "task_comments"
    public let id: String
    public let taskID: String
    public let body: String
    public let createdAt: Double
    public init(taskID: String, body: String) { id = UUID().uuidString; self.taskID = taskID; self.body = body; createdAt = Date().timeIntervalSince1970 }
}

extension Store {
    public func taskDetails() throws -> [String: TaskDetails] {
        try database.read { db in
            let values = try Data.fetchAll(db, sql: "SELECT payload FROM task_details").map { try JSONDecoder().decode(TaskDetails.self, from: $0) }
            return Dictionary(uniqueKeysWithValues: values.map { ($0.taskID, $0) })
        }
    }
    public func createDraft(projectID: String, title: String, provider: AgentProvider) throws -> WorkTask {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf8.count <= 500 else { throw MochletError.message("Use a task title of 1–500 bytes.") }
        return try database.write { db in
            guard try Project.fetchOne(db, key: projectID) != nil else { throw MochletError.message("Choose a registered project.") }
            var task = WorkTask(projectID: projectID, title: title); task.state = .draft; task.provider = provider.rawValue
            try task.insert(db); return task
        }
    }
    /// Optimistic edit: never replace a task changed by runtime activity after the editor opened.
    public func editTask(expected: WorkTask, updated: WorkTask, details: TaskDetails) throws {
        guard updated.id == expected.id, details.taskID == expected.id,
              !updated.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, updated.title.utf8.count <= 500,
              details.description.utf8.count <= 50_000, details.dependencies.count <= 100,
              details.dueAt?.isFinite != false else { throw MochletError.message("Task fields exceed their limits or have invalid identities.") }
        try database.write { db in
            guard let current = try WorkTask.fetchOne(db, key: expected.id), current == expected,
                  ![.queued, .running, .waiting].contains(current.state),
                  [.draft, .review, .completed, .cancelled, .failed, .interrupted].contains(updated.state) else {
                throw MochletError.message("This task changed or has queued/active work. Reopen it after that work settles.")
            }
            guard current.threadID == updated.threadID, current.sessionCWD == updated.sessionCWD,
                  current.sessionConfirmed == updated.sessionConfirmed, current.output == updated.output,
                  current.createdAt == updated.createdAt, AgentProvider(rawValue: updated.provider) != nil else {
                throw MochletError.message("Task editing cannot rewrite runtime history or session identity.")
            }
            let attempts = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM runs WHERE taskID=?", arguments: [current.id]) ?? 0
            if current.projectID != updated.projectID || current.provider != updated.provider {
                let links = try Int.fetchOne(db, sql: "SELECT (SELECT COUNT(*) FROM task_workspaces WHERE taskID=?) + (SELECT COUNT(*) FROM github_tasks WHERE taskID=?) + (SELECT COUNT(*) FROM connected_task_sources WHERE taskID=?)", arguments: [current.id, current.id, current.id]) ?? 0
                guard current.state == .draft, current.threadID == nil, attempts == 0, links == 0 else {
                    throw MochletError.message("A task with session/history/source bindings stays in its original project and agent. Create a new draft for another destination.")
                }
            }
            guard try Project.fetchOne(db, key: updated.projectID) != nil else { throw MochletError.message("Destination project is unavailable.") }
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM github_publications WHERE taskID=? AND state IN ('pushing','ready','creating')", arguments: [current.id]) == 0 else {
                throw MochletError.message("Resolve this task's GitHub publication before editing it.")
            }
            var all = try Data.fetchAll(db, sql: "SELECT payload FROM task_details").map { try JSONDecoder().decode(TaskDetails.self, from: $0) }
            let previous = all.first { $0.taskID == current.id }
            guard (previous?.version ?? 0) == details.version else { throw MochletError.message("Task details changed. Reopen the editor.") }
            var next = details; next.version += 1
            all.removeAll { $0.taskID == current.id }; all.append(next)
            var tasks = try WorkTask.fetchAll(db); tasks.removeAll { $0.id == current.id }; tasks.append(updated)
            try Self.validateTaskGraph(all, tasks: tasks)
            if updated.state == .completed { try Self.requireCompletedDependencies(next.dependencies, db: db) }
            try updated.save(db)
            try db.execute(sql: "INSERT INTO task_details(taskID,payload) VALUES(?,?) ON CONFLICT(taskID) DO UPDATE SET payload=excluded.payload", arguments: [current.id, try JSONEncoder().encode(next)])
        }
    }
    private static func validateTaskGraph(_ details: [TaskDetails], tasks: [WorkTask]) throws {
        let owners = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.projectID) })
        var edges: [String: Set<String>] = [:]
        for item in details {
            var refs = item.dependencies; if let parent = item.parentID { refs.insert(parent) }
            for ref in refs {
                guard ref != item.taskID, let owner = owners[ref], owner == owners[item.taskID] else {
                    throw MochletError.message("Parents and dependencies must be different tasks in the same project.")
                }
            }
            edges[item.taskID] = refs
        }
        // Topological removal avoids recursive stack growth in long project chains.
        var remaining = edges.mapValues(\.count)
        var reverse: [String: Set<String>] = [:]
        for (id, refs) in edges { for ref in refs { reverse[ref, default: []].insert(id); if remaining[ref] == nil { remaining[ref] = 0 } } }
        var ready = remaining.filter { $0.value == 0 }.map(\.key), visited = 0
        while let id = ready.popLast() {
            visited += 1
            for next in reverse[id] ?? [] {
                remaining[next, default: 0] -= 1
                if remaining[next] == 0 { ready.append(next) }
            }
        }
        guard visited == remaining.count else { throw MochletError.message("This parent/dependency relationship creates a cycle.") }
    }
    static func requireTaskDependencies(_ taskID: String, db: Database) throws {
        guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM task_details WHERE taskID=?", arguments: [taskID]) else { return }
        try requireCompletedDependencies(JSONDecoder().decode(TaskDetails.self, from: data).dependencies, db: db)
    }
    private static func requireCompletedDependencies(_ dependencies: Set<String>, db: Database) throws {
        for id in dependencies {
            guard try WorkTask.fetchOne(db, key: id)?.state == .completed else { throw MochletError.message("Complete and review this task's dependencies before starting it.") }
        }
    }
    public func rejectQueuedCommand(taskID: String) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM queued_commands WHERE taskID=?", arguments: [taskID])
            if db.changesCount == 1 { try db.execute(sql: "UPDATE tasks SET state='interrupted' WHERE id=? AND state='queued'", arguments: [taskID]) }
        }
    }
    public func comments(taskID: String) throws -> [TaskComment] {
        try database.read { try TaskComment.fetchAll($0, sql: "SELECT * FROM task_comments WHERE taskID=? ORDER BY createdAt DESC LIMIT 200", arguments: [taskID]) }
    }
    public func addComment(taskID: String, body: String) throws {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 10_000 else { throw MochletError.message("Comments must contain 1–10,000 bytes.") }
        try database.write { db in try TaskComment(taskID: taskID, body: text).insert(db) }
    }
    public func attempts(taskID: String) throws -> [Run] {
        try database.read { try Run.fetchAll($0, sql: "SELECT * FROM runs WHERE taskID=? ORDER BY startedAt DESC LIMIT 100", arguments: [taskID]) }
    }
}
