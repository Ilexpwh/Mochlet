import Foundation
import GRDB

public struct Project: Codable, Identifiable, Sendable, FetchableRecord, PersistableRecord, Equatable {
    public static let databaseTableName = "projects"
    public var id: String
    public var name: String
    public var root: String
    public var aliases: String
    public init(name: String, root: String, aliases: String = "") {
        id = UUID().uuidString; self.name = name
        self.root = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
        self.aliases = aliases
    }
}

public enum WorkState: String, Codable, Sendable, CaseIterable {
    case draft, queued, running, waiting, review, completed, interrupted, failed, cancelled
}

public struct WorkTask: Codable, Identifiable, Sendable, FetchableRecord, PersistableRecord, Equatable {
    public static let databaseTableName = "tasks"
    public var id: String
    public var projectID: String
    public var title: String
    public var state: WorkState
    public var threadID: String?
    public var provider: String = AgentProvider.codex.rawValue
    public var sessionCWD: String?
    public var sessionConfirmed = false
    public var createdAt: Double
    public var output: String
    public init(projectID: String, title: String) {
        id = UUID().uuidString; self.projectID = projectID; self.title = title
        state = .queued; createdAt = Date().timeIntervalSince1970; output = ""
    }
}

public struct Run: Codable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "runs"
    public var id: String
    public var taskID: String
    public var state: WorkState
    public var startedAt: Double
    public var endedAt: Double?
    public var prompt: String
    public init(taskID: String, prompt: String) {
        id = UUID().uuidString; self.taskID = taskID; self.prompt = prompt
        state = .running; startedAt = Date().timeIntervalSince1970
    }
}

public enum MochletError: LocalizedError, Sendable {
    case message(String)
    public var errorDescription: String? { if case let .message(s) = self { return s }; return nil }
}

public enum ProjectResolver {
    public static func resolve(_ name: String, projects: [Project]) throws -> Project {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches = projects.filter { p in
            p.id == name || ([p.name] + p.aliases.split(separator: ",").map(String.init))
                .contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == key }
        }
        guard matches.count == 1 else {
            throw MochletError.message(matches.isEmpty ? "Choose a registered project." : "Several projects match. Choose the destination explicitly.")
        }
        return matches[0]
    }
    public static func validateRoot(_ project: Project) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project.root, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MochletError.message("The project folder is unavailable. Reconnect it before running work.")
        }
    }
    public static func verifyCWD(expected: String, actual: String) throws {
        let a = URL(fileURLWithPath: expected).resolvingSymlinksInPath().standardizedFileURL.path
        let b = URL(fileURLWithPath: actual).resolvingSymlinksInPath().standardizedFileURL.path
        guard a == b else { throw MochletError.message("Codex returned a different working folder. No turn was sent.") }
    }
}
