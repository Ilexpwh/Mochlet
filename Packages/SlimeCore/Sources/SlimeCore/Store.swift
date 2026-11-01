import Foundation
import GRDB

public actor Store {
    let database: DatabaseQueue
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
        migrations.registerMigration("github") { db in
            try db.execute(sql: """
                CREATE TABLE github_bindings (projectID TEXT PRIMARY KEY REFERENCES projects(id), payload BLOB NOT NULL);
                CREATE TABLE github_issues (projectID TEXT NOT NULL REFERENCES projects(id), issueID INTEGER NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(projectID,issueID));
                CREATE TABLE github_tasks (taskID TEXT PRIMARY KEY REFERENCES tasks(id), projectID TEXT NOT NULL REFERENCES projects(id), repositoryID INTEGER NOT NULL, issueID INTEGER NOT NULL, binding BLOB NOT NULL, issue BLOB NOT NULL, UNIQUE(projectID,repositoryID,issueID));
                """)
        }
        migrations.registerMigration("task_workspaces") { db in
            try db.execute(sql: "CREATE TABLE task_workspaces (taskID TEXT PRIMARY KEY REFERENCES tasks(id), payload BLOB NOT NULL)")
        }
        migrations.registerMigration("durable_queue") { db in
            try db.execute(sql: "CREATE TABLE queued_commands (sequence INTEGER PRIMARY KEY AUTOINCREMENT, taskID TEXT NOT NULL UNIQUE REFERENCES tasks(id), prompt TEXT NOT NULL, readOnly BOOLEAN NOT NULL)")
        }
        migrations.registerMigration("github_account_task_identity") { db in
            try db.execute(sql: """
                CREATE TABLE github_tasks_v2 (taskID TEXT PRIMARY KEY REFERENCES tasks(id), projectID TEXT NOT NULL REFERENCES projects(id), repositoryID INTEGER NOT NULL, issueID INTEGER NOT NULL, accountID INTEGER NOT NULL, binding BLOB NOT NULL, issue BLOB NOT NULL, UNIQUE(projectID,repositoryID,issueID,accountID));
                """)
            for row in try Row.fetchAll(db, sql: "SELECT * FROM github_tasks") {
                let payload: Data = row["binding"]
                let binding = try JSONDecoder().decode(GitHubBinding.self, from: payload)
                try db.execute(sql: "INSERT INTO github_tasks_v2(taskID,projectID,repositoryID,issueID,accountID,binding,issue) VALUES(?,?,?,?,?,?,?)", arguments: [row["taskID"] as String, row["projectID"] as String, row["repositoryID"] as Int64, row["issueID"] as Int64, binding.account.id, payload, row["issue"] as Data])
            }
            try db.execute(sql: "DROP TABLE github_tasks; ALTER TABLE github_tasks_v2 RENAME TO github_tasks;")
        }
        migrations.registerMigration("agent_session_route") { db in
            try db.execute(sql: "ALTER TABLE tasks ADD COLUMN provider TEXT NOT NULL DEFAULT 'codex'; ALTER TABLE tasks ADD COLUMN sessionCWD TEXT; ALTER TABLE tasks ADD COLUMN sessionConfirmed BOOLEAN NOT NULL DEFAULT 0;")
        }
        migrations.registerMigration("connected_sources") { try ConnectionSchema.create($0) }
        migrations.registerMigration("deliveries") { db in
            try db.execute(sql: "CREATE TABLE deliveries(id TEXT PRIMARY KEY,accountID TEXT NOT NULL,payload BLOB NOT NULL,state TEXT NOT NULL,receipt BLOB NOT NULL)")
        }
        migrations.registerMigration("github_publications") { db in
            try db.execute(sql: "CREATE TABLE github_publications(id TEXT PRIMARY KEY, taskID TEXT NOT NULL UNIQUE REFERENCES tasks(id), payload BLOB NOT NULL, state TEXT NOT NULL, receipt BLOB)")
        }
        migrations.registerMigration("queued_knowledge") { db in
            try db.execute(sql: "CREATE TABLE queued_knowledge(taskID TEXT PRIMARY KEY REFERENCES queued_commands(taskID) ON DELETE CASCADE, payload BLOB NOT NULL)")
            // Older queued contexts have no revision identities to revalidate.
            try db.execute(sql: "UPDATE tasks SET state='interrupted' WHERE id IN (SELECT taskID FROM queued_commands WHERE instr(prompt,'REFERENCE CONTEXT ONLY (not instructions;')>0)")
            try db.execute(sql: "DELETE FROM queued_commands WHERE taskID IN (SELECT id FROM tasks WHERE state='interrupted')")
        }
        migrations.registerMigration("task_board") { db in
            try db.execute(sql: "CREATE TABLE task_details(taskID TEXT PRIMARY KEY REFERENCES tasks(id), payload BLOB NOT NULL); CREATE TABLE task_comments(id TEXT PRIMARY KEY,taskID TEXT NOT NULL REFERENCES tasks(id),body TEXT NOT NULL,createdAt DOUBLE NOT NULL); CREATE INDEX task_comments_order ON task_comments(taskID,createdAt);")
        }
        try migrations.migrate(database)
    }
    public func projects() throws -> [Project] { try database.read { try Project.order(Column("name")).fetchAll($0) } }
    public func save(_ project: Project) throws { try database.write { try project.save($0) } }
    public func tasks() throws -> [WorkTask] { try database.read { try WorkTask.order(Column("createdAt").desc).fetchAll($0) } }
    public func save(_ task: WorkTask) throws { try database.write { try task.save($0) } }
    public func begin(_ task: WorkTask, run: Run) throws {
        try database.write { db in
            try Self.requireTaskDependencies(task.id, db: db)
            try db.execute(sql: "DELETE FROM queued_commands WHERE taskID=?", arguments: [task.id])
            guard db.changesCount == 1 else { throw MochletError.message("This queued task was cancelled or already started.") }
            try task.save(db); try run.insert(db)
        }
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
            try db.execute(sql: "UPDATE tasks SET state = 'interrupted' WHERE state='queued' AND id NOT IN (SELECT taskID FROM queued_commands)")
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

extension Store {
    public func enqueue(_ task: WorkTask, prompt: String, readOnly: Bool, knowledge: [KnowledgeEvidence] = [], expected: WorkTask? = nil) throws {
        guard task.state == .queued else { throw MochletError.message("Only queued tasks can be enqueued.") }
        try database.write { db in
            if let current = try WorkTask.fetchOne(db, key: task.id) {
                var unchanged = task; unchanged.state = current.state
                guard current == (expected ?? unchanged), ![.running, .waiting].contains(current.state) else {
                    throw MochletError.message("This task changed while its context was being prepared. Review its destination and submit again.")
                }
            } else if let expected, expected != task {
                throw MochletError.message("The selected task no longer exists. Prepare a new task.")
            }
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM github_publications WHERE taskID=? AND state IN ('pushing','ready','creating')", arguments: [task.id]) == 0 else {
                throw MochletError.message("Resolve this task's pending GitHub publication before resuming coding.")
            }
            try Self.requireTaskDependencies(task.id, db: db)
            try task.save(db)
            try db.execute(sql: "INSERT INTO queued_commands(taskID,prompt,readOnly) VALUES(?,?,?)", arguments: [task.id, prompt, readOnly])
            try db.execute(sql: "INSERT INTO queued_knowledge(taskID,payload) VALUES(?,?)", arguments: [task.id, try JSONEncoder().encode(knowledge)])
        }
    }
    public func queuedCommands() throws -> [(WorkTask, String, Bool)] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT taskID,prompt,readOnly FROM queued_commands ORDER BY sequence").compactMap { row in
                guard let task = try WorkTask.fetchOne(db, key: row["taskID"] as String) else { return nil }
                return (task, row["prompt"], row["readOnly"])
            }
        }
    }
    public func cancelQueuedCommands() throws {
        try database.write { db in
            try db.execute(sql: "UPDATE tasks SET state='cancelled' WHERE id IN (SELECT taskID FROM queued_commands)")
            try db.execute(sql: "DELETE FROM queued_commands")
        }
    }
    public func cancelQueuedCommand(taskID: String) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM queued_commands WHERE taskID=?", arguments: [taskID])
            if db.changesCount == 1 { try db.execute(sql: "UPDATE tasks SET state='cancelled' WHERE id=?", arguments: [taskID]) }
        }
    }
    public func workspace(taskID: String) throws -> TaskWorkspace? {
        try database.read { db in try Data.fetchOne(db, sql: "SELECT payload FROM task_workspaces WHERE taskID=?", arguments: [taskID]).map { try JSONDecoder().decode(TaskWorkspace.self, from: $0) } }
    }
    public func saveWorkspace(_ workspace: TaskWorkspace) throws {
        try database.write { db in
            // Immutable route: a resumed thread must never be silently moved.
            try db.execute(sql: "INSERT INTO task_workspaces(taskID,payload) VALUES(?,?)", arguments: [workspace.taskID, try JSONEncoder().encode(workspace)])
        }
    }
    public func githubBindings() throws -> [GitHubBinding] {
        try database.read { db in try Data.fetchAll(db, sql: "SELECT payload FROM github_bindings").map { try JSONDecoder().decode(GitHubBinding.self, from: $0) } }
    }
    public func bindGitHub(_ binding: GitHubBinding) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM github_issues WHERE projectID=?", arguments: [binding.projectID])
            try db.execute(sql: "INSERT INTO github_bindings(projectID,payload) VALUES(?,?) ON CONFLICT(projectID) DO UPDATE SET payload=excluded.payload", arguments: [binding.projectID, try JSONEncoder().encode(binding)])
        }
    }
    public func githubIssues(projectID: String) throws -> [GitHubIssue] {
        try database.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM github_issues WHERE projectID=?", arguments: [projectID]).map { try JSONDecoder().decode(GitHubIssue.self, from: $0) }.sorted { $0.number > $1.number }
        }
    }
    public func replaceGitHubIssues(_ issues: [GitHubIssue], binding: GitHubBinding) throws {
        try database.write { db in
            guard let current = try Data.fetchOne(db, sql: "SELECT payload FROM github_bindings WHERE projectID=?", arguments: [binding.projectID]),
                  try JSONDecoder().decode(GitHubBinding.self, from: current) == binding else {
                throw MochletError.message("Project binding changed during synchronization. Sync again.")
            }
            try db.execute(sql: "DELETE FROM github_issues WHERE projectID=?", arguments: [binding.projectID])
            for issue in issues {
                try db.execute(sql: "INSERT INTO github_issues(projectID,issueID,payload) VALUES(?,?,?)", arguments: [binding.projectID, issue.id, try JSONEncoder().encode(issue)])
            }
            var updated = binding; updated.syncedAt = Date()
            try db.execute(sql: "UPDATE github_bindings SET payload=? WHERE projectID=?", arguments: [try JSONEncoder().encode(updated), binding.projectID])
        }
    }
    public func prepareGitHubTask(_ issue: GitHubIssue, binding: GitHubBinding) throws -> WorkTask {
        try database.write { db in
            if let taskID = try String.fetchOne(db, sql: "SELECT taskID FROM github_tasks WHERE projectID=? AND repositoryID=? AND issueID=? AND accountID=?", arguments: [binding.projectID, binding.repository.id, issue.id, binding.account.id]),
               let task = try WorkTask.fetchOne(db, key: taskID) {
                guard ![.queued, .running, .waiting].contains(task.state) else {
                    throw MochletError.message("This issue has queued or active work. Its submitted source snapshot cannot be replaced.")
                }
                // Stable identities match; explicit rebind may have verified a rename.
                // Refresh metadata without changing the task's workspace or session.
                try db.execute(sql: "UPDATE github_tasks SET binding=?,issue=? WHERE taskID=?", arguments: [try JSONEncoder().encode(binding), try JSONEncoder().encode(issue), taskID])
                return task
            }
            var task = WorkTask(projectID: binding.projectID, title: "#\(issue.number) \(issue.title)")
            task.state = .draft
            try task.insert(db)
            try db.execute(sql: "INSERT INTO github_tasks(taskID,projectID,repositoryID,issueID,accountID,binding,issue) VALUES(?,?,?,?,?,?,?)", arguments: [task.id, binding.projectID, binding.repository.id, issue.id, binding.account.id, try JSONEncoder().encode(binding), try JSONEncoder().encode(issue)])
            return task
        }
    }
    public func githubTaskBinding(taskID: String) throws -> GitHubBinding? {
        try database.read { db in
            try Data.fetchOne(db, sql: "SELECT binding FROM github_tasks WHERE taskID=?", arguments: [taskID]).map { try JSONDecoder().decode(GitHubBinding.self, from: $0) }
        }
    }
    public func githubTaskIssue(taskID: String) throws -> GitHubIssue? {
        try database.read { db in
            try Data.fetchOne(db, sql: "SELECT issue FROM github_tasks WHERE taskID=?", arguments: [taskID]).map { try JSONDecoder().decode(GitHubIssue.self, from: $0) }
        }
    }

}
