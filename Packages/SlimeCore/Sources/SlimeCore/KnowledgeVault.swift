import Foundation
import GRDB
import CryptoKit

public struct KnowledgeNote: Codable,Identifiable,Sendable,FetchableRecord,PersistableRecord,Equatable {
    public static let databaseTableName="notes"
    public var id:String
    public var scope:String
    public var title:String
    public var body:String
    public var source:String
    public var revision:String
    public var updatedAt:Double
    public var connectionJSON: String?
    public var eligibilityReason: String?
    public init(scope:String,title:String,body:String,source:String = "User-authored memory") {
        id=UUID().uuidString;self.scope=scope;self.title=title;self.body=body;self.source=source
        revision=SHA256.hash(data:Data(body.utf8)).map{String(format:"%02x",$0)}.joined();updatedAt=Date().timeIntervalSince1970
    }
    public var citation:String {"[\(title)](mochlet-knowledge:\(id))"}
}

public actor KnowledgeVault {
    let directory:URL
    private let db:DatabaseQueue
    private let allows: @Sendable (KnowledgeNote) async throws -> Bool
    public init(directory:URL, allows: @escaping @Sendable (KnowledgeNote) async throws -> Bool = { $0.connectionJSON == nil }) throws {
        self.allows = allows
        self.directory=directory
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try Self.recoverImport(in: directory)
        db=try DatabaseQueue(path:directory.appendingPathComponent("index.sqlite").path)
        try db.write { db in
            try db.execute(sql:"""
            CREATE TABLE IF NOT EXISTS notes(id TEXT PRIMARY KEY,scope TEXT NOT NULL,title TEXT NOT NULL,body TEXT NOT NULL,source TEXT NOT NULL,revision TEXT NOT NULL,updatedAt DOUBLE NOT NULL);
            CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(id UNINDEXED,title,body);
            """)
            if try !db.columns(in: "notes").contains(where: { $0.name == "connectionJSON" }) {
                try db.execute(sql: "ALTER TABLE notes ADD COLUMN connectionJSON TEXT")
            }
            if try !db.columns(in: "notes").contains(where: { $0.name == "eligibilityReason" }) {
                try db.execute(sql: "ALTER TABLE notes ADD COLUMN eligibilityReason TEXT")
            }
        }
    }
    public func save(_ original:KnowledgeNote, expectedRevision: String? = nil) throws {
        guard UUID(uuidString: original.id) != nil else { throw MochletError.message("Invalid memory identity.") }
        let existing = try? Data(contentsOf: url(original.id))
        let previousRevision = existing.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        if let expectedRevision, previousRevision != expectedRevision {
            throw MochletError.message("This memory changed or was deleted outside the editor. Reload it before saving.")
        }
        if let existing, let previousRevision {
            let history = directory.appendingPathComponent("revisions").appendingPathComponent(original.id)
            try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
            try existing.write(to: history.appendingPathComponent(previousRevision).appendingPathExtension("md"), options: .atomic)
        }
        var note=original;note.updatedAt=Date().timeIntervalSince1970
        note.revision=SHA256.hash(data:Data(note.body.utf8)).map{String(format:"%02x",$0)}.joined()
        var fields:[String:String]=["title":note.title,"x-mochlet-id":note.id,"x-mochlet-scope":note.scope,"x-mochlet-source":note.source]
        if let connection = note.connectionJSON { fields["x-mochlet-connection"] = connection }
        let document = try PortableKnowledge(existing.map { String(decoding: $0, as: UTF8.self) } ?? "---\ntype: Note\n---\n")
        guard document.hasConceptType else { throw MochletError.message("The note's type is missing or uses unsupported YAML syntax. Repair it before editing in Mochlet.") }
        let markdown = try document.replacing(fields, body: note.body)
        note.revision=SHA256.hash(data:Data(markdown.utf8)).map{String(format:"%02x",$0)}.joined()
        try markdown.write(to:url(note.id),atomically:true,encoding:.utf8)
        try index(note)
    }
    private func index(_ note:KnowledgeNote) throws {
        try db.write { db in
            try note.save(db)
            try db.execute(sql:"DELETE FROM notes_fts WHERE id=?",arguments:[note.id])
            try db.execute(sql:"INSERT INTO notes_fts(id,title,body) VALUES(?,?,?)",arguments:[note.id,note.title,note.body])
        }
    }
    public func remove(_ id:String) throws {
        let path=url(id)
        let history = directory.appendingPathComponent("revisions").appendingPathComponent(UUID(uuidString: id)?.uuidString ?? "invalid")
        if FileManager.default.fileExists(atPath: history.path) { try FileManager.default.removeItem(at: history) }
        if FileManager.default.fileExists(atPath:path.path) {try FileManager.default.removeItem(at:path)}
        try db.write {try $0.execute(sql:"DELETE FROM notes WHERE id=?",arguments:[id]);try $0.execute(sql:"DELETE FROM notes_fts WHERE id=?",arguments:[id])}
    }
    public func rebuild() throws {
        let files=try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.isSymbolicLinkKey,.contentModificationDateKey]).filter{$0.pathExtension == "md"}
        var notes:[KnowledgeNote]=[]
        for file in files {
            guard try file.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true else {continue}
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let document = try? PortableKnowledge(text), document.hasConceptType,
                  let id = document.scalar("x-mochlet-id"), UUID(uuidString: id) != nil,
                  id == file.deletingPathExtension().lastPathComponent,
                  let scope = document.scalar("x-mochlet-scope") else { continue }
            var note = KnowledgeNote(scope: scope, title: document.scalar("title") ?? "Note", body: document.body,
                                     source: document.scalar("x-mochlet-source") ?? file.path)
            note.id = id
            note.connectionJSON = document.scalar("x-mochlet-connection") ?? (document.contains("x-mochlet-connection") ? "Invalid connection metadata" : nil)
            note.eligibilityReason = document.exclusionReason()
            note.revision=SHA256.hash(data:Data(text.utf8)).map{String(format:"%02x",$0)}.joined()
            note.updatedAt=try file.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970 ?? 0
            notes.append(note)
        }
        try db.write {db in try db.execute(sql:"DELETE FROM notes;DELETE FROM notes_fts;")}
        for note in notes {try index(note)}
    }
    public func search(_ query:String,scope:String,includePersonal:Bool=false,limit:Int=30, includeUnavailable: Bool = false) async throws -> [KnowledgeNote] {
        // The small personal vault is authoritative. Refresh before retrieval so
        // external edits/deletion cannot return stale evidence from the derived index.
        try rebuild()
        let scopes=includePersonal && scope != "personal" ? [scope,"personal"]:[scope]
        let tokens=query.split(whereSeparator:{$0.isWhitespace}).prefix(8).map{"\""+$0.replacingOccurrences(of:"\"",with:"\"\"")+"\""}
        let placeholders=scopes.map{_ in "?"}.joined(separator:",")
        let notes:[KnowledgeNote]=try await db.read {db in
            var sql="SELECT * FROM notes WHERE scope IN (\(placeholders))"
            if !includeUnavailable { sql += " AND eligibilityReason IS NULL" }
            var args=StatementArguments(scopes)
            if !tokens.isEmpty {sql += " AND (id IN (SELECT id FROM notes_fts WHERE notes_fts MATCH ?) OR instr(lower(body),lower(?))>0)";args += [tokens.joined(separator:" OR "),query]}
            sql += " ORDER BY updatedAt DESC LIMIT ?";args += [min(max(limit,1),100)]
            return try KnowledgeNote.fetchAll(db,sql:sql,arguments:args)
        }
        var available: [KnowledgeNote] = []
        for note in notes where FileManager.default.fileExists(atPath: url(note.id).path) {
            if includeUnavailable { available.append(note) }
            else if note.eligibilityReason == nil, try await allows(note) { available.append(note) }
        }
        return available
    }
    public func url(_ id:String) -> URL { directory.appendingPathComponent(UUID(uuidString:id)?.uuidString ?? "invalid").appendingPathExtension("md") }
    public func isCurrent(_ note: KnowledgeNote) async throws -> Bool {
        guard try await allows(note) else { return false }
        let data = try Data(contentsOf: url(note.id))
        guard let document = try? PortableKnowledge(String(decoding: data, as: UTF8.self)),
              document.hasConceptType, document.exclusionReason() == nil else { return false }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == note.revision
    }
    public func resolve(_ evidence: KnowledgeEvidence) async throws -> KnowledgeNote {
        try rebuild()
        guard let note = try await db.read({ try KnowledgeNote.fetchOne($0, key: evidence.id) }),
              note.scope == evidence.scope, note.revision == evidence.revision, try await isCurrent(note) else {
            throw MochletError.message("Queued memory was edited, forgotten or lost access. Review and submit the task again.")
        }
        return note
    }
    public func importDocument(_ source: URL, scope: String) throws -> String {
        let attrs = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard attrs.isRegularFile == true, attrs.isSymbolicLink != true, (attrs.fileSize ?? Int.max) <= 2_000_000 else {
            throw MochletError.message("Import a regular Markdown file up to 2 MB.")
        }
        let document = try PortableKnowledge(String(contentsOf: source, encoding: .utf8))
        guard document.hasConceptType else { throw MochletError.message("Each concept needs a nonempty string OKF type.") }
        let id = UUID().uuidString
        let markdown = try document.replacing(["x-mochlet-id": id, "x-mochlet-scope": scope,
            "x-mochlet-source": document.scalar("x-mochlet-source") ?? source.path,
            "x-mochlet-bundle": "", "x-mochlet-path": "",
            "title": document.scalar("title") ?? source.deletingPathExtension().lastPathComponent])
        try markdown.write(to: url(id), atomically: true, encoding: .utf8)
        try rebuild(); return id
    }
    public func reviewLifecycle(_ note: KnowledgeNote, status: String, staleAfter: Date?) throws {
        guard ["draft", "stable", "deprecated"].contains(status) else { throw MochletError.message("Choose a valid lifecycle status.") }
        let path = url(note.id)
        let data = try Data(contentsOf: path)
        let revision = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard revision == note.revision else { throw MochletError.message("Memory changed. Reload before reviewing it.") }
        let document = try PortableKnowledge(String(decoding: data, as: UTF8.self))
        var fields = ["status": status]
        if let staleAfter { fields["stale_after"] = staleAfter.ISO8601Format() }
        let markdown = try document.replacing(fields, removing: staleAfter == nil ? ["stale_after"] : [])
        let history = directory.appendingPathComponent("revisions").appendingPathComponent(note.id)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        try data.write(to: history.appendingPathComponent(revision).appendingPathExtension("md"), options: .atomic)
        try markdown.write(to: path, atomically: true, encoding: .utf8)
        try rebuild()
    }
    public func exportDocument(_ id: String, directory: URL) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw MochletError.message("Invalid memory identity.") }
        let destination = directory.appendingPathComponent(id).appendingPathExtension("md")
        try FileManager.default.copyItem(at: url(id), to: destination)
        return destination
    }
}
