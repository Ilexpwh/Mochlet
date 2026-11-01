import Foundation
import GRDB

public actor Store {
    private let database: DatabaseQueue
    public init(path: String) throws {
        database = try DatabaseQueue(path: path)
        var migrations = DatabaseMigrator()
        migrations.registerMigration("initial") { db in
            try db.execute(sql: """
                CREATE TABLE projects (id TEXT PRIMARY KEY, name TEXT NOT NULL, root TEXT NOT NULL UNIQUE, aliases TEXT NOT NULL);
                CREATE TABLE tasks (id TEXT PRIMARY KEY, projectID TEXT NOT NULL REFERENCES projects(id), title TEXT NOT NULL,
                    state TEXT NOT NULL, threadID TEXT, createdAt DOUBLE NOT NULL, output TEXT NOT NULL);
                CREATE TABLE runs (id TEXT PRIMARY KEY, taskID TEXT NOT NULL REFERENCES tasks(id), state TEXT NOT NULL,
                    startedAt DOUBLE NOT NULL, endedAt DOUBLE, prompt TEXT NOT NULL);
                CREATE TABLE events (id INTEGER PRIMARY KEY AUTOINCREMENT, runID TEXT NOT NULL REFERENCES runs(id), kind TEXT NOT NULL,
                    body TEXT NOT NULL, createdAt DOUBLE NOT NULL);
                CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                """)
        }
        try migrations.migrate(database)
    }
    public func projects() throws -> [Project] { try database.read { try Project.order(Column("name")).fetchAll($0) } }
    public func save(_ project: Project) throws { try database.write { try project.save($0) } }
    public func tasks() throws -> [WorkTask] { try database.read { try WorkTask.order(Column("createdAt").desc).fetchAll($0) } }
    public func save(_ task: WorkTask) throws { try database.write { try task.save($0) } }
    public func begin(_ task: WorkTask, run: Run) throws {
        try database.write { db in try task.save(db); try run.insert(db) }
    }
    public func finish(_ task: WorkTask, runID: String) throws {
        try database.write { db in
            try task.save(db)
            try db.execute(sql: "UPDATE runs SET state = ?, endedAt = ? WHERE id = ?", arguments: [task.state.rawValue, Date().timeIntervalSince1970, runID])
        }
    }
    public func event(runID: String, kind: String, body: String) throws {
        try database.write { db in
            try db.execute(sql: "INSERT INTO events(runID,kind,body,createdAt) VALUES(?,?,?,?)", arguments: [runID, kind, body, Date().timeIntervalSince1970])
        }
    }
    public func recover() throws {
        try database.write { db in
            try db.execute(sql: "UPDATE tasks SET state = 'interrupted' WHERE state IN ('running','waiting')")
            try db.execute(sql: "UPDATE runs SET state = 'interrupted', endedAt = ? WHERE state IN ('running','waiting')", arguments: [Date().timeIntervalSince1970])
        }
    }
    public func setting(_ key: String) throws -> String? {
        try database.read { try String.fetchOne($0, sql: "SELECT value FROM settings WHERE key = ?", arguments: [key]) }
    }
    public func setSetting(_ key: String, value: String) throws {
        try database.write { try $0.execute(sql: "INSERT INTO settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", arguments: [key, value]) }
    }
}
