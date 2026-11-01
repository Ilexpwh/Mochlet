import Foundation
import GRDB

/// The current attempt's assistant text, independent of the task's combined conversation.
public struct RunOutputBuffer: Equatable, Sendable {
    public static let byteLimit = 1_000_000
    public private(set) var text = ""
    public private(set) var truncated = false
    public init() {}
    public mutating func append(_ delta: String) { text += delta; trim() }
    public mutating func replace(_ snapshot: String) { text = snapshot; truncated = false; trim() }
    private mutating func trim() {
        guard text.utf8.count > Self.byteLimit else { return }
        var bytes = Data(text.utf8.suffix(Self.byteLimit))
        // The suffix may begin inside a multi-byte character; retain only complete UTF-8.
        while let first = bytes.first, first & 0xC0 == 0x80 { bytes.removeFirst() }
        text = String(decoding: bytes, as: UTF8.self); truncated = true
    }
}

public struct SavedRunOutput: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "run_outputs"
    public let runID: String
    public let text: String
    public let truncated: Bool
    public let updatedAt: Double
}

extension Store {
    static func writeRunOutput(runID: String, taskID: String, output: RunOutputBuffer, db: Database) throws {
        guard let run = try Run.fetchOne(db, key: runID), run.taskID == taskID,
              [.running, .waiting].contains(run.state), output.text.utf8.count <= RunOutputBuffer.byteLimit else {
            throw MochletError.message("This attempt is no longer active or belongs to another task. Its saved output was not changed.")
        }
        let record = SavedRunOutput(runID: runID, text: output.text, truncated: output.truncated, updatedAt: Date().timeIntervalSince1970)
        try record.save(db)
    }
    public func checkpointRunOutput(runID: String, taskID: String, output: RunOutputBuffer, combinedOutput: String? = nil) throws {
        try database.write { db in
            try Self.writeRunOutput(runID: runID, taskID: taskID, output: output, db: db)
            if let combinedOutput {
                // Update only text; a concurrent approval reply may have changed the task's state.
                // The run guard and this update share the same transaction as cancellation/finalization.
                try db.execute(sql: "UPDATE tasks SET output=? WHERE id=? AND state IN ('running','waiting')", arguments: [combinedOutput, taskID])
                guard db.changesCount == 1 else { throw MochletError.message("This task is no longer active. Its output checkpoint was not changed.") }
            }
        }
    }
    public func runOutput(runID: String, taskID: String) throws -> SavedRunOutput? {
        try database.read { db in
            guard try Run.fetchOne(db, key: runID)?.taskID == taskID else { throw MochletError.message("This attempt belongs to another task or no longer exists.") }
            return try SavedRunOutput.fetchOne(db, key: runID)
        }
    }
}
