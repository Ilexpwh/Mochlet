import Foundation
import GRDB

public struct SlimeProfile: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var version = 0
    public var name: String
    public var palette: String
    public var instructions: String
    public var provider: AgentProvider
    public var voiceID: String
    public var archived = false
    public static let palettes = ["Mint", "Peach", "Sky", "Lilac"]
    public init(name: String = "Mochlet", palette: String = "Mint", instructions: String = "", provider: AgentProvider = .codex, voiceID: String = "") {
        id = UUID().uuidString; self.name = name; self.palette = palette
        self.instructions = instructions; self.provider = provider; self.voiceID = voiceID
    }
    public func contextPrompt(request: String) -> String {
        guard !instructions.isEmpty else { return request }
        let preferences: JSONValue = .object(["profileID": .string(id), "name": .string(name), "instructions": .string(instructions)])
        return "USER-CONFIGURED COMPANION PREFERENCES (current request and project instructions take precedence):\n" + preferences.formatted + "\n\n" + request
    }
    func validate() throws {
        guard UUID(uuidString: id) != nil, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= 120, Self.palettes.contains(palette), instructions.utf8.count <= 20_000,
              voiceID.utf8.count <= 500 else { throw MochletError.message("Use a profile name up to 120 bytes, a supported palette and instructions up to 20 KB.") }
    }
}
public struct ProfileAssignmentChange: Sendable {
    public let expected: SlimeProfile?
    public let next: SlimeProfile?
    public init(expected: SlimeProfile?, next: SlimeProfile?) { self.expected = expected; self.next = next }
}

extension Store {
    public func profiles() throws -> [SlimeProfile] {
        try database.read { db in try Data.fetchAll(db, sql: "SELECT payload FROM slime_profiles ORDER BY id").map { try JSONDecoder().decode(SlimeProfile.self, from: $0) }.sorted { ($0.name, $0.id) < ($1.name, $1.id) } }
    }
    public func saveProfile(_ profile: SlimeProfile, expected: SlimeProfile?) throws -> SlimeProfile {
        try profile.validate()
        return try database.write { db in
            let current = try Self.profile(profile.id, db: db)
            guard current == expected, expected == nil || expected?.id == profile.id else { throw MochletError.message("This profile changed. Reopen it before saving.") }
            if current == nil {
                guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM slime_profiles") ?? 0 < 100 else { throw MochletError.message("The local profile limit is 100.") }
            }
            var next = profile; next.version = (current?.version ?? -1) + 1
            try db.execute(sql: "INSERT INTO slime_profiles(id,payload) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", arguments: [next.id, try JSONEncoder().encode(next)])
            return next
        }
    }
    public func taskProfiles() throws -> [String: SlimeProfile] {
        try database.read { db in
            try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: "SELECT taskID,payload FROM task_profiles").map { row in
                (row["taskID"] as String, try JSONDecoder().decode(SlimeProfile.self, from: row["payload"] as Data))
            })
        }
    }
    static func profile(_ id: String, db: Database) throws -> SlimeProfile? {
        try Data.fetchOne(db, sql: "SELECT payload FROM slime_profiles WHERE id=?", arguments: [id]).map { try JSONDecoder().decode(SlimeProfile.self, from: $0) }
    }
    static func taskProfile(_ id: String, db: Database) throws -> SlimeProfile? {
        try Data.fetchOne(db, sql: "SELECT payload FROM task_profiles WHERE taskID=?", arguments: [id]).map { try JSONDecoder().decode(SlimeProfile.self, from: $0) }
    }
    static func validateProfileAssignment(_ change: ProfileAssignmentChange, task: WorkTask, db: Database) throws {
        guard try taskProfile(task.id, db: db) == change.expected else { throw MochletError.message("Task profile changed. Reopen the task.") }
        if let next = change.next, next.provider.rawValue != task.provider {
            throw MochletError.message("Choose a profile matching this task's agent, or clear its profile before changing agents.")
        }
        guard change.expected != change.next else { return }
        guard task.state == .draft, task.threadID == nil,
              try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM runs WHERE taskID=?", arguments: [task.id]) == 0 else {
            throw MochletError.message("Existing sessions retain their original companion profile. Assign profiles to unstarted drafts.")
        }
        if let next = change.next {
            guard !next.archived, try profile(next.id, db: db) == next, next.provider.rawValue == task.provider else {
                throw MochletError.message("Choose a current profile matching this draft's agent.")
            }
        }
    }
    static func writeTaskProfile(_ profile: SlimeProfile?, taskID: String, db: Database) throws {
        if let profile {
            try db.execute(sql: "INSERT INTO task_profiles(taskID,payload) VALUES(?,?) ON CONFLICT(taskID) DO UPDATE SET payload=excluded.payload", arguments: [taskID, try JSONEncoder().encode(profile)])
        } else { try db.execute(sql: "DELETE FROM task_profiles WHERE taskID=?", arguments: [taskID]) }
    }
}
