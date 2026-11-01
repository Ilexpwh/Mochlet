import Foundation
import GRDB

public struct TaskBoardOrder: Codable, Equatable, Sendable {
    public let projectID: String
    public var version: Int
    public var taskIDs: [String]
}

extension Store {
    public func taskBoardOrder(projectID: String) throws -> TaskBoardOrder {
        try database.read { try Self.taskBoardOrder(projectID: projectID, db: $0) }
    }
    private static func taskBoardOrder(projectID: String, db: Database) throws -> TaskBoardOrder {
        guard try Project.fetchOne(db, key: projectID) != nil else { throw MochletError.message("Choose a registered project to order its tasks.") }
        let ids = try String.fetchAll(db, sql: "SELECT id FROM tasks WHERE projectID=? ORDER BY createdAt,id", arguments: [projectID])
        let saved = try Data.fetchOne(db, sql: "SELECT payload FROM task_board_order WHERE projectID=?", arguments: [projectID]).map { try JSONDecoder().decode(TaskBoardOrder.self, from: $0) }
        let current = Set(ids), previous = Set(saved?.taskIDs ?? [])
        return TaskBoardOrder(projectID: projectID, version: saved?.version ?? 0,
                              taskIDs: (saved?.taskIDs ?? []).filter { current.contains($0) } + ids.filter { !previous.contains($0) })
    }
    /// Presentation only: never edits task state, priority, sessions or execution order.
    public func moveTaskOnBoard(_ taskID: String, relativeTo targetID: String, after: Bool = false, expected: TaskBoardOrder) throws -> TaskBoardOrder {
        try database.write { db in
            let current = try Self.taskBoardOrder(projectID: expected.projectID, db: db)
            guard current == expected else { throw MochletError.message("This board changed. Refresh before moving the card again.") }
            guard taskID != targetID, current.taskIDs.contains(taskID), current.taskIDs.contains(targetID),
                  let source = try WorkTask.fetchOne(db, key: taskID), let target = try WorkTask.fetchOne(db, key: targetID),
                  Self.boardLane(source.state) == Self.boardLane(target.state) else {
                throw MochletError.message("Move cards within the same project and column. Edit task details to change status.")
            }
            var next = current
            next.taskIDs.removeAll { $0 == taskID }
            guard let index = next.taskIDs.firstIndex(of: targetID) else { throw MochletError.message("Target card is unavailable.") }
            next.taskIDs.insert(taskID, at: index + (after ? 1 : 0)); next.version += 1
            try db.execute(sql: "INSERT INTO task_board_order(projectID,payload) VALUES(?,?) ON CONFLICT(projectID) DO UPDATE SET payload=excluded.payload", arguments: [next.projectID, try JSONEncoder().encode(next)])
            return next
        }
    }
    private static func boardLane(_ state: WorkState) -> Int {
        switch state {
        case .draft, .cancelled, .failed, .interrupted: 0
        case .queued, .running, .waiting: 1
        case .review: 2
        case .completed: 3
        }
    }
}
