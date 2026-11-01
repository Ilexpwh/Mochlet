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
    public init(scope:String,title:String,body:String,source:String = "User-authored memory") {
        id=UUID().uuidString;self.scope=scope;self.title=title;self.body=body;self.source=source
        revision=SHA256.hash(data:Data(body.utf8)).map{String(format:"%02x",$0)}.joined();updatedAt=Date().timeIntervalSince1970
    }
    public var citation:String {"[\(title)](mochlet-knowledge:\(id))"}
}

public actor KnowledgeVault {
    private let directory:URL
    private let db:DatabaseQueue
    public init(directory:URL) throws {
        self.directory=directory
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        db=try DatabaseQueue(path:directory.appendingPathComponent("index.sqlite").path)
        try db.write { db in
            try db.execute(sql:"""
            CREATE TABLE IF NOT EXISTS notes(id TEXT PRIMARY KEY,scope TEXT NOT NULL,title TEXT NOT NULL,body TEXT NOT NULL,source TEXT NOT NULL,revision TEXT NOT NULL,updatedAt DOUBLE NOT NULL);
            CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(id UNINDEXED,title,body);
            """)
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
        let fields:[String:String]=["type":"Note","title":note.title,"x-mochlet-id":note.id,"x-mochlet-scope":note.scope,"x-mochlet-source":note.source]
        let header=try fields.sorted(by:{$0.key<$1.key}).map {key,value in
            "\(key): \(String(decoding:try JSONEncoder().encode(value),as:UTF8.self))"
        }.joined(separator:"\n")
        let markdown="---\n\(header)\n---\n\n\(note.body)"
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
            let text=try String(contentsOf:file,encoding:.utf8)
            guard text.hasPrefix("---\n"),let boundary=text.range(of:"\n---\n") else{continue}
            var fields:[String:String]=[:]
            for line in text[text.index(text.startIndex,offsetBy:4)..<boundary.lowerBound].split(separator:"\n") {
                let pair=line.split(separator:":",maxSplits:1).map(String.init)
                guard pair.count == 2 else{continue}
                let value=pair[1].trimmingCharacters(in:.whitespaces)
                fields[pair[0]]=(try? JSONDecoder().decode(String.self,from:Data(value.utf8))) ?? value
            }
            guard let id=fields["x-mochlet-id"],UUID(uuidString:id) != nil,id == file.deletingPathExtension().lastPathComponent,let scope=fields["x-mochlet-scope"] else{continue}
            var note=KnowledgeNote(scope:scope,title:fields["title"] ?? "Note",body:String(text[boundary.upperBound...]).trimmingCharacters(in:.newlines),source:fields["x-mochlet-source"] ?? file.path)
            note.id=id
            note.revision=SHA256.hash(data:Data(text.utf8)).map{String(format:"%02x",$0)}.joined()
            note.updatedAt=try file.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970 ?? 0
            notes.append(note)
        }
        try db.write {db in try db.execute(sql:"DELETE FROM notes;DELETE FROM notes_fts;")}
        for note in notes {try index(note)}
    }
    public func search(_ query:String,scope:String,includePersonal:Bool=false,limit:Int=30) throws -> [KnowledgeNote] {
        // The small personal vault is authoritative. Refresh before retrieval so
        // external edits/deletion cannot return stale evidence from the derived index.
        try rebuild()
        let scopes=includePersonal && scope != "personal" ? [scope,"personal"]:[scope]
        let tokens=query.split(whereSeparator:{$0.isWhitespace}).prefix(8).map{"\""+$0.replacingOccurrences(of:"\"",with:"\"\"")+"\""}
        let placeholders=scopes.map{_ in "?"}.joined(separator:",")
        let notes:[KnowledgeNote]=try db.read {db in
            var sql="SELECT * FROM notes WHERE scope IN (\(placeholders))"
            var args=StatementArguments(scopes)
            if !tokens.isEmpty {sql += " AND (id IN (SELECT id FROM notes_fts WHERE notes_fts MATCH ?) OR instr(lower(body),lower(?))>0)";args += [tokens.joined(separator:" OR "),query]}
            sql += " ORDER BY updatedAt DESC LIMIT ?";args += [min(max(limit,1),100)]
            return try KnowledgeNote.fetchAll(db,sql:sql,arguments:args)
        }
        return notes.filter {FileManager.default.fileExists(atPath:url($0.id).path)}
    }
    public func url(_ id:String) -> URL { directory.appendingPathComponent(UUID(uuidString:id)?.uuidString ?? "invalid").appendingPathExtension("md") }
}
