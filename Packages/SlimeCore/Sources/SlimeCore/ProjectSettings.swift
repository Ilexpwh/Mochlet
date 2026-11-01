import Foundation
import GRDB

extension Store {
    public func editProject(_ proposed: Project, expected: Project) throws -> Project {
        var project = proposed
        project.name = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let aliases = project.aliases.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        project.aliases = aliases.joined(separator: ", ")
        project.instructions = project.instructions?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard project.id == expected.id, !project.name.isEmpty, project.name.count <= 120,
              aliases.count <= 20, aliases.allSatisfy({ $0.count <= 120 }), (project.instructions?.utf8.count ?? 0) <= 16_000,
              project.root.hasPrefix("/"), !project.root.contains("\0") else { throw MochletError.message("Use a project name up to 120 characters, at most 20 aliases and instructions up to 16 KB.") }
        project.root = URL(fileURLWithPath: project.root).resolvingSymlinksInPath().standardizedFileURL.path
        if project.root != expected.root { try ProjectResolver.validateRoot(project) }
        return try database.write { db in
            guard try Project.fetchOne(db, key: expected.id) == expected else { throw MochletError.message("This project changed in another view. Close and reopen its settings.") }
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tasks WHERE projectID=? AND state IN ('queued','running','waiting')", arguments: [project.id]) == 0 else {
                throw MochletError.message("Finish or cancel this project's active and queued tasks before changing its settings.")
            }
            if project.root != expected.root {
                guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tasks WHERE projectID=?", arguments: [project.id]) == 0,
                      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM github_bindings WHERE projectID=?", arguments: [project.id]) == 0 else {
                    throw MochletError.message("This project already has tasks or a repository binding. Register the new folder as a separate project; existing sessions keep their original folder.")
                }
            }
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM projects WHERE root=? AND id<>?", arguments: [project.root, project.id]) == 0 else {
                throw MochletError.message("That folder is already registered. Select the existing project.")
            }
            try project.update(db); return project
        }
    }
}
