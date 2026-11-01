import Foundation
import GRDB

public struct GitHubBoardRecord: Codable, Sendable, Equatable {
    public var snapshot: GitHubBoardSnapshot
    public var statusField: GitHubBoardField?
    public var version: Int
    public var statusMappingCurrent: Bool { statusField.map { snapshot.fields.contains($0) } ?? false }
    public func status(for item: GitHubBoardItem) -> String? {
        guard let field = statusField else { return nil }
        guard statusMappingCurrent else { return "Status mapping changed — select it again" }
        guard let value = item.values.first(where: { $0.field?.id == field.id }), let optionID = value.optionId else { return "No status" }
        return field.options?.first(where: { $0.id == optionID })?.name ?? "Unknown status option — refresh"
    }
}

extension Store {
    public func githubTaskBoard(taskID: String) throws -> GitHubBoardSelection? {
        try database.read { db in try Data.fetchOne(db, sql: "SELECT payload FROM github_task_boards WHERE taskID=?", arguments: [taskID]).map { try JSONDecoder().decode(GitHubBoardSelection.self, from: $0) } }
    }
    static func validateBoardSelection(_ board: GitHubBoardSelection?, issue: GitHubIssue, binding: GitHubBinding, db: Database) throws {
        guard try currentGitHubBinding(binding, db: db) else { throw MochletError.message("Repository binding changed before task preparation.") }
        guard let board else { return }
        guard board.binding.projectID == binding.projectID, board.binding.account == binding.account,
              board.binding.repository == binding.repository, board.item.canPrepare(binding: binding),
              board.item.content?.id == issue.node_id, board.item.content?.number == issue.number,
              let record = try boardRecord(binding.projectID, db: db), !record.snapshot.closed,
              record.snapshot.id == board.boardID, record.snapshot.items.contains(board.item) else {
            throw MochletError.message("The saved board selection changed or does not match this issue. Refresh it before preparing work.")
        }
    }
    static func writeBoardSelection(_ board: GitHubBoardSelection?, taskID: String, db: Database) throws {
        if let board { try db.execute(sql: "INSERT INTO github_task_boards(taskID,payload) VALUES(?,?) ON CONFLICT(taskID) DO UPDATE SET payload=excluded.payload", arguments: [taskID, try JSONEncoder().encode(board)]) }
        else { try db.execute(sql: "DELETE FROM github_task_boards WHERE taskID=?", arguments: [taskID]) }
    }
    public func githubBoard(binding: GitHubBinding) throws -> GitHubBoardRecord? {
        try database.read { db in
            guard try Self.currentGitHubBinding(binding, db: db),
                  let data = try Data.fetchOne(db, sql: "SELECT payload FROM github_boards WHERE projectID=?", arguments: [binding.projectID]) else { return nil }
            let record = try JSONDecoder().decode(GitHubBoardRecord.self, from: data)
            guard record.snapshot.binding.account == binding.account, record.snapshot.binding.repository == binding.repository else { return nil }
            return record
        }
    }
    public func saveGitHubBoard(_ snapshot: GitHubBoardSnapshot, expected: GitHubBoardRecord?) throws -> GitHubBoardRecord {
        try database.write { db in
            guard try Self.currentGitHubBinding(snapshot.binding, db: db) else { throw MochletError.message("Repository binding changed while syncing the board.") }
            let current = try Self.boardRecord(snapshot.binding.projectID, db: db)
            // A rebind deliberately discards a cache owned by another account/repository.
            let sameOwner = current?.snapshot.binding.account == snapshot.binding.account && current?.snapshot.binding.repository == snapshot.binding.repository
            guard (sameOwner ? current : nil) == expected else { throw MochletError.message("Saved board changed during sync. Reopen and refresh it.") }
            let record = GitHubBoardRecord(snapshot: snapshot, statusField: current?.snapshot.id == snapshot.id && sameOwner ? current?.statusField : nil, version: (current?.version ?? -1) + 1)
            try Self.writeBoard(record, db: db)
            return record
        }
    }
    public func mapGitHubBoardStatus(fieldID: String?, expected: GitHubBoardRecord) throws -> GitHubBoardRecord {
        try database.write { db in
            guard try Self.currentGitHubBinding(expected.snapshot.binding, db: db),
                  try Self.boardRecord(expected.snapshot.binding.projectID, db: db) == expected else { throw MochletError.message("Board changed. Reopen it before selecting a status field.") }
            let field = fieldID.flatMap { id in expected.snapshot.fields.first { $0.id == id && $0.dataType == "SINGLE_SELECT" } }
            guard fieldID == nil || field != nil else { throw MochletError.message("Choose an available single-select field.") }
            var record = expected; record.statusField = field; record.version += 1
            try Self.writeBoard(record, db: db); return record
        }
    }
    private static func currentGitHubBinding(_ binding: GitHubBinding, db: Database) throws -> Bool {
        guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM github_bindings WHERE projectID=?", arguments: [binding.projectID]) else { return false }
        let current = try JSONDecoder().decode(GitHubBinding.self, from: data)
        return current.account == binding.account && current.repository == binding.repository
    }
    private static func boardRecord(_ projectID: String, db: Database) throws -> GitHubBoardRecord? {
        try Data.fetchOne(db, sql: "SELECT payload FROM github_boards WHERE projectID=?", arguments: [projectID]).map { try JSONDecoder().decode(GitHubBoardRecord.self, from: $0) }
    }
    private static func writeBoard(_ record: GitHubBoardRecord, db: Database) throws {
        try db.execute(sql: "INSERT INTO github_boards(projectID,payload) VALUES(?,?) ON CONFLICT(projectID) DO UPDATE SET payload=excluded.payload", arguments: [record.snapshot.binding.projectID, try JSONEncoder().encode(record)])
    }
}
