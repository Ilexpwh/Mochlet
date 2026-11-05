import Foundation

/// A page as the index stores it.
public struct IndexedDocument: Equatable, Sendable {
    public var path: String
    public var type: String
    public var title: String
    public var description: String?
    public var resource: String?
    public var tags: [String]
    public var status: String?
    public var staleAfter: Date?
    public var generatedBy: String?
    public var generatedAt: Date?
    public var project: String?
    public var lang: String?
    public var sha256: String
    public var mtime: Date
    public var size: Int
    public var frontmatterYAML: String
    public var sourceCount: Int
    public var isHumanOwned: Bool
    public var links: [String]          // resolved relative paths this page links to
    public var unresolvedLinks: [String]

    public init(path: String, type: String, title: String, description: String? = nil, resource: String? = nil, tags: [String] = [], status: String? = nil,
                staleAfter: Date? = nil, generatedBy: String? = nil, generatedAt: Date? = nil, project: String? = nil, lang: String? = nil,
                sha256: String, mtime: Date, size: Int, frontmatterYAML: String = "", sourceCount: Int = 0, isHumanOwned: Bool = false,
                links: [String] = [], unresolvedLinks: [String] = []) {
        self.path = path
        self.type = type
        self.title = title
        self.description = description
        self.resource = resource
        self.tags = tags
        self.status = status
        self.staleAfter = staleAfter
        self.generatedBy = generatedBy
        self.generatedAt = generatedAt
        self.project = project
        self.lang = lang
        self.sha256 = sha256
        self.mtime = mtime
        self.size = size
        self.frontmatterYAML = frontmatterYAML
        self.sourceCount = sourceCount
        self.isHumanOwned = isHumanOwned
        self.links = links
        self.unresolvedLinks = unresolvedLinks
    }
}

/// One retrieval result: a chunk with its page.
public struct KnowledgeHit: Equatable, Sendable, Identifiable {
    public var chunkID: Int
    public var path: String
    public var title: String
    public var type: String
    public var headingPath: String
    public var text: String
    public var lineStart: Int
    public var lineEnd: Int
    public var page: Int?
    public var tsStart: Double?
    public var resource: String?
    public var score: Double
    public var id: String { "\(path)#\(chunkID)" }
}

public struct FindFilters: Equatable, Sendable {
    public var types: [String]?
    public var project: String?
    public var excludePaths: Set<String> = []
    public var pathPrefix: String?
    public init(types: [String]? = nil, project: String? = nil, excludePaths: Set<String> = [], pathPrefix: String? = nil) {
        self.types = types
        self.project = project
        self.excludePaths = excludePaths
        self.pathPrefix = pathPrefix
    }
}

/// Embeddings come from outside the pure core (Apple's NLContextualEmbedding, an API).
public protocol EmbeddingProvider: Sendable {
    var id: String { get }
    var dimension: Int { get }
    func embed(_ texts: [String]) async throws -> [[Float]]
}

/// In-memory unit vectors for one model; cosine top-k by brute force (fine to ≈200k chunks).
public struct VectorStore: Sendable {
    public var model: String
    public var dimension: Int
    public private(set) var ids: [Int] = []
    private var matrix: [Float] = []

    public init(model: String, dimension: Int) {
        self.model = model
        self.dimension = dimension
    }

    public var count: Int { ids.count }

    public mutating func add(id: Int, vector: [Float]) {
        guard vector.count == dimension else { return }
        ids.append(id)
        matrix += Self.normalized(vector)
    }

    public static func normalized(_ v: [Float]) -> [Float] {
        var sum: Float = 0
        for x in v { sum += x * x }
        let n = sum.squareRoot()
        guard n > 0 else { return v }
        return v.map { $0 / n }
    }

    public func topK(_ query: [Float], k: Int) -> [(id: Int, score: Double)] {
        guard query.count == dimension, !ids.isEmpty else { return [] }
        let q = Self.normalized(query)
        var scores: [(Int, Float)] = []
        scores.reserveCapacity(ids.count)
        matrix.withUnsafeBufferPointer { m in
            q.withUnsafeBufferPointer { qp in
                for (row, id) in ids.enumerated() {
                    var dot: Float = 0
                    let base = row * dimension
                    for j in 0..<dimension { dot += m[base + j] * qp[j] }
                    scores.append((id, dot))
                }
            }
        }
        return scores.sorted { $0.1 > $1.1 }.prefix(k).map { ($0.0, Double($0.1)) }
    }
}

/// Reciprocal rank fusion of ranked id lists.
public enum RRF {
    public static func fuse(_ lists: [[Int]], k: Double = 60) -> [(id: Int, score: Double)] {
        var scores: [Int: Double] = [:]
        for list in lists {
            for (rank, id) in list.enumerated() { scores[id, default: 0] += 1 / (k + Double(rank + 1)) }
        }
        return scores.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 || ($0.1 == $1.1 && $0.0 < $1.0) }
    }
}

/// `index.sqlite`: documents, chunks, FTS5 over segmented tokens, embeddings, links, priors.
public final class KnowledgeIndex: @unchecked Sendable {
    public let db: SQLiteDB

    public init(path: String) throws {
        db = try SQLiteDB(path: path)
        if path != ":memory:" {
            // The app and mochlet-cli may open the same file.
            try? db.exec("PRAGMA journal_mode = WAL")
            try? db.exec("PRAGMA busy_timeout = 5000")
        }
        try migrate()
    }

    public static func inMemory() throws -> KnowledgeIndex { try KnowledgeIndex(path: ":memory:") }

    func migrate() throws {
        try db.migrate([
            """
            CREATE TABLE documents(
                id INTEGER PRIMARY KEY, path TEXT UNIQUE NOT NULL, type TEXT NOT NULL, title TEXT NOT NULL, description TEXT, resource TEXT,
                tags_json TEXT, status TEXT, stale_after REAL, generated_by TEXT, generated_at REAL, project TEXT, lang TEXT,
                sha256 TEXT NOT NULL, mtime REAL NOT NULL, size INTEGER NOT NULL, frontmatter_yaml TEXT, source_count INTEGER DEFAULT 0,
                human_owned INTEGER DEFAULT 0, indexed_at REAL NOT NULL, hidden INTEGER DEFAULT 0);
            CREATE TABLE chunks(
                id INTEGER PRIMARY KEY, document_id INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE, ordinal INTEGER NOT NULL,
                heading_path TEXT, text TEXT NOT NULL, token_count INTEGER, line_start INTEGER, line_end INTEGER, ts_start REAL, ts_end REAL,
                speaker TEXT, page INTEGER);
            CREATE INDEX chunks_doc ON chunks(document_id);
            CREATE VIRTUAL TABLE chunks_fts USING fts5(tokens, heading, title, tokenize='unicode61 remove_diacritics 2');
            CREATE TABLE embeddings(chunk_id INTEGER NOT NULL, model TEXT NOT NULL, dim INTEGER NOT NULL, vector BLOB NOT NULL, PRIMARY KEY(chunk_id, model));
            CREATE TABLE doc_links(from_path TEXT NOT NULL, to_path TEXT NOT NULL, resolved INTEGER NOT NULL DEFAULT 1, PRIMARY KEY(from_path, to_path));
            CREATE INDEX doc_links_to ON doc_links(to_path);
            CREATE TABLE ingest_log(source_key TEXT PRIMARY KEY, document_path TEXT, status TEXT NOT NULL, error TEXT, report_json TEXT, created_at REAL NOT NULL);
            CREATE TABLE project_priors(key TEXT NOT NULL, project TEXT NOT NULL, weight REAL NOT NULL, PRIMARY KEY(key, project));
            CREATE TABLE decision_cache(hash TEXT PRIMARY KEY, backend TEXT, answer_json TEXT, created_at REAL NOT NULL);
            CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
            """,
        ])
        try db.exec("PRAGMA foreign_keys = ON")
    }

    // MARK: Documents

    public func upsert(_ d: IndexedDocument, chunks: [Chunk], now: Date = Date()) throws {
        try db.transaction {
            if let existing = try db.query("SELECT id FROM documents WHERE path = ?", [.text(d.path)]).first?["id"]?.int {
                try removeChunks(documentID: existing)
                try db.run("""
                    UPDATE documents SET type=?, title=?, description=?, resource=?, tags_json=?, status=?, stale_after=?, generated_by=?, generated_at=?,
                    project=?, lang=?, sha256=?, mtime=?, size=?, frontmatter_yaml=?, source_count=?, human_owned=?, indexed_at=?, hidden=0 WHERE id=?
                    """, docParams(d, now: now) + [.integer(existing)])
                try insertChunks(documentID: existing, title: d.title, chunks: chunks)
            } else {
                try db.run("""
                    INSERT INTO documents(type, title, description, resource, tags_json, status, stale_after, generated_by, generated_at, project, lang, sha256, mtime, size,
                    frontmatter_yaml, source_count, human_owned, indexed_at, path) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """, docParams(d, now: now) + [.text(d.path)])
                let id = db.lastInsertRowID
                try insertChunks(documentID: Int(id), title: d.title, chunks: chunks)
            }
            try db.run("DELETE FROM doc_links WHERE from_path = ?", [.text(d.path)])
            for l in Set(d.links) { try db.run("INSERT OR REPLACE INTO doc_links(from_path, to_path, resolved) VALUES (?,?,1)", [.text(d.path), .text(l)]) }
            for l in Set(d.unresolvedLinks) { try db.run("INSERT OR REPLACE INTO doc_links(from_path, to_path, resolved) VALUES (?,?,0)", [.text(d.path), .text(l)]) }
        }
    }

    private func docParams(_ d: IndexedDocument, now: Date) -> [SQLValue] {
        let tags = (try? JSONSerialization.data(withJSONObject: d.tags)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        return [.text(d.type), .text(d.title), d.description.map { .text($0) } ?? .null, d.resource.map { .text($0) } ?? .null, .text(tags),
                d.status.map { .text($0) } ?? .null, d.staleAfter.map { .real($0.timeIntervalSince1970) } ?? .null,
                d.generatedBy.map { .text($0) } ?? .null, d.generatedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                d.project.map { .text($0) } ?? .null, d.lang.map { .text($0) } ?? .null, .text(d.sha256), .real(d.mtime.timeIntervalSince1970), .integer(d.size),
                .text(d.frontmatterYAML), .integer(d.sourceCount), .integer(d.isHumanOwned ? 1 : 0), .real(now.timeIntervalSince1970)]
    }

    private func insertChunks(documentID: Int, title: String, chunks: [Chunk]) throws {
        for c in chunks {
            try db.run("INSERT INTO chunks(document_id, ordinal, heading_path, text, token_count, line_start, line_end, page) VALUES (?,?,?,?,?,?,?,?)",
                       [.integer(documentID), .integer(c.ordinal), .text(c.headingPath), .text(c.text), .integer(c.tokenCount), .integer(c.lineStart), .integer(c.lineEnd), c.page.map { .integer($0) } ?? .null])
            let id = db.lastInsertRowID
            try db.run("INSERT INTO chunks_fts(rowid, tokens, heading, title) VALUES (?,?,?,?)",
                       [.integer(Int(id)), .text(CJKSegmenter.segmented(c.text)), .text(CJKSegmenter.segmented(c.headingPath)), .text(CJKSegmenter.segmented(title))])
        }
    }

    public func insertTranscriptChunks(path: String, chunks: [TranscriptChunk]) throws {
        guard let docID = try db.query("SELECT id, title FROM documents WHERE path = ?", [.text(path)]).first, let id = docID["id"]?.int else { return }
        let title = docID["title"]?.string ?? ""
        for c in chunks {
            try db.run("INSERT INTO chunks(document_id, ordinal, heading_path, text, token_count, line_start, line_end, ts_start, ts_end, speaker) VALUES (?,?,?,?,?,?,?,?,?,?)",
                       [.integer(id), .integer(c.ordinal), .text(""), .text(c.text), .integer(c.tokenCount), .integer(0), .integer(0), .real(c.tsStart), .real(c.tsEnd), .text(c.speakers.joined(separator: ","))])
            let cid = db.lastInsertRowID
            try db.run("INSERT INTO chunks_fts(rowid, tokens, heading, title) VALUES (?,?,?,?)", [.integer(Int(cid)), .text(CJKSegmenter.segmented(c.text)), .text(""), .text(CJKSegmenter.segmented(title))])
        }
    }

    private func removeChunks(documentID: Int) throws {
        let ids = try db.query("SELECT id FROM chunks WHERE document_id = ?", [.integer(documentID)]).compactMap { $0["id"]?.int }
        for id in ids {
            try db.run("DELETE FROM chunks_fts WHERE rowid = ?", [.integer(id)])
            try db.run("DELETE FROM embeddings WHERE chunk_id = ?", [.integer(id)])
        }
        try db.run("DELETE FROM chunks WHERE document_id = ?", [.integer(documentID)])
    }

    public func remove(path: String) throws {
        try db.transaction {
            if let id = try db.query("SELECT id FROM documents WHERE path = ?", [.text(path)]).first?["id"]?.int {
                try removeChunks(documentID: id)
                try db.run("DELETE FROM documents WHERE id = ?", [.integer(id)])
            }
            try db.run("DELETE FROM doc_links WHERE from_path = ?", [.text(path)])
        }
    }

    /// path → (sha256, mtime) for change detection.
    public func fingerprints() throws -> [String: (sha256: String, mtime: Date)] {
        var out: [String: (String, Date)] = [:]
        for r in try db.query("SELECT path, sha256, mtime FROM documents WHERE hidden = 0") {
            if let p = r["path"]?.string, let s = r["sha256"]?.string, let m = r["mtime"]?.double { out[p] = (s, Date(timeIntervalSince1970: m)) }
        }
        return out
    }

    public func document(path: String) throws -> IndexedDocument? {
        try db.query("SELECT * FROM documents WHERE path = ?", [.text(path)]).first.map(Self.document(from:))
    }

    /// Pages (and, when `includeReferences`, the indexed raw sources under `references/`).
    public func documents(types: [String]? = nil, pathPrefix: String? = nil, includeReferences: Bool = false) throws -> [IndexedDocument] {
        var sql = "SELECT * FROM documents WHERE hidden = 0"
        var params: [SQLValue] = []
        if let types, !types.isEmpty {
            sql += " AND type IN (" + types.map { _ in "?" }.joined(separator: ",") + ")"
            params += types.map { .text($0) }
        } else if !includeReferences {
            sql += " AND type <> 'reference'"
        }
        if let pathPrefix { sql += " AND path LIKE ?"; params.append(.text(pathPrefix + "%")) }
        sql += " ORDER BY path"
        return try db.query(sql, params).map(Self.document(from:))
    }

    static func document(from r: [String: SQLValue]) -> IndexedDocument {
        let tags = (r["tags_json"]?.string).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String] } ?? []
        return IndexedDocument(path: r["path"]?.string ?? "", type: r["type"]?.string ?? "", title: r["title"]?.string ?? "", description: r["description"]?.string,
                               resource: r["resource"]?.string, tags: tags, status: r["status"]?.string,
                               staleAfter: r["stale_after"]?.double.map { Date(timeIntervalSince1970: $0) }, generatedBy: r["generated_by"]?.string,
                               generatedAt: r["generated_at"]?.double.map { Date(timeIntervalSince1970: $0) }, project: r["project"]?.string, lang: r["lang"]?.string,
                               sha256: r["sha256"]?.string ?? "", mtime: Date(timeIntervalSince1970: r["mtime"]?.double ?? 0), size: r["size"]?.int ?? 0,
                               frontmatterYAML: r["frontmatter_yaml"]?.string ?? "", sourceCount: r["source_count"]?.int ?? 0, isHumanOwned: (r["human_owned"]?.int ?? 0) == 1)
    }

    public var documentCount: Int { (try? db.query("SELECT COUNT(*) AS n FROM documents WHERE hidden = 0 AND type <> 'reference'").first?["n"]?.int) ?? 0 }
    public var referenceCount: Int { (try? db.query("SELECT COUNT(*) AS n FROM documents WHERE hidden = 0 AND type = 'reference'").first?["n"]?.int) ?? 0 }
    public var chunkCount: Int { (try? db.query("SELECT COUNT(*) AS n FROM chunks").first?["n"]?.int) ?? 0 }

    // MARK: Links

    public func links(from path: String) throws -> [(to: String, resolved: Bool)] {
        try db.query("SELECT to_path, resolved FROM doc_links WHERE from_path = ? ORDER BY to_path", [.text(path)]).map { ($0["to_path"]?.string ?? "", ($0["resolved"]?.int ?? 1) == 1) }
    }

    public func backlinks(to path: String) throws -> [String] {
        try db.query("SELECT from_path FROM doc_links WHERE to_path = ? AND resolved = 1 ORDER BY from_path", [.text(path)]).compactMap { $0["from_path"]?.string }
    }

    public func allLinks() throws -> [(from: String, to: String, resolved: Bool)] {
        try db.query("SELECT from_path, to_path, resolved FROM doc_links").map { ($0["from_path"]?.string ?? "", $0["to_path"]?.string ?? "", ($0["resolved"]?.int ?? 1) == 1) }
    }

    // MARK: Embeddings

    public func chunksNeedingEmbedding(model: String, limit: Int = 64) throws -> [(chunkID: Int, text: String)] {
        try db.query("""
            SELECT c.id AS id, c.heading_path AS h, c.text AS t FROM chunks c
            WHERE NOT EXISTS (SELECT 1 FROM embeddings e WHERE e.chunk_id = c.id AND e.model = ?) ORDER BY c.id LIMIT ?
            """, [.text(model), .integer(limit)]).compactMap { r in
            guard let id = r["id"]?.int else { return nil }
            let h = r["h"]?.string ?? ""
            let t = r["t"]?.string ?? ""
            return (id, (h.isEmpty ? "" : h + "\n") + String(t.prefix(1400)))
        }
    }

    public func store(embedding: [Float], chunkID: Int, model: String) throws {
        let data = embedding.withUnsafeBufferPointer { Data(buffer: $0) }
        try db.run("INSERT OR REPLACE INTO embeddings(chunk_id, model, dim, vector) VALUES (?,?,?,?)", [.integer(chunkID), .text(model), .integer(embedding.count), .blob(data)])
    }

    public func loadVectors(model: String) throws -> VectorStore? {
        let rows = try db.query("SELECT chunk_id, dim, vector FROM embeddings WHERE model = ?", [.text(model)])
        guard let first = rows.first, let dim = first["dim"]?.int else { return nil }
        var store = VectorStore(model: model, dimension: dim)
        for r in rows {
            guard let id = r["chunk_id"]?.int, let blob = r["vector"]?.blob, blob.count == dim * 4 else { continue }
            let v = blob.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            store.add(id: id, vector: v)
        }
        return store
    }

    // MARK: Retrieval

    /// BM25 over the segmented tokens ∪ vector neighbours → RRF → priors → best 2 chunks per page → top k.
    public func find(_ query: String, k: Int = 8, filters: FindFilters = FindFilters(), vectors: VectorStore? = nil, queryVector: [Float]? = nil, now: Date = Date()) throws -> [KnowledgeHit] {
        var lists: [[Int]] = []
        if let p = QueryPatternBuilder.build(query) {
            var ids = try ftsIDs(p.and, limit: 50)
            if ids.count < 5, p.terms.count > 1 { ids += try ftsIDs(p.or, limit: 50).filter { !ids.contains($0) } }
            if !ids.isEmpty { lists.append(ids) }
        }
        if let vectors, let queryVector {
            let near = vectors.topK(queryVector, k: 50).filter { $0.score > 0.2 }.map(\.id)
            if !near.isEmpty { lists.append(near) }
        }
        guard !lists.isEmpty else { return [] }
        let fused = RRF.fuse(lists)
        var hits: [KnowledgeHit] = []
        var perDoc: [String: Int] = [:]
        for (id, base) in fused {
            guard let r = try db.query("""
                SELECT c.id AS cid, c.heading_path, c.text, c.line_start, c.line_end, c.page, c.ts_start, d.path, d.title, d.type, d.status, d.stale_after, d.project, d.resource
                FROM chunks c JOIN documents d ON d.id = c.document_id WHERE c.id = ? AND d.hidden = 0
                """, [.integer(id)]).first else { continue }
            let path = r["path"]?.string ?? ""
            let type = r["type"]?.string ?? ""
            if let types = filters.types, !types.isEmpty, !types.contains(type) { continue }
            if filters.excludePaths.contains(path) { continue }
            if let prefix = filters.pathPrefix, !path.hasPrefix(prefix) { continue }
            var score = base
            if r["status"]?.string == "deprecated" { score *= 0.5 }
            if let stale = r["stale_after"]?.double, stale < now.timeIntervalSince1970 { score *= 0.8 }
            if let p = filters.project, r["project"]?.string == p { score *= 1.2 }
            if type == "report" || type == "synthesis" || type == "concept" || type == "entity" { score *= 1.05 }
            if type == "reference" { score *= 0.9 }   // the page about a source outranks the raw source
            if perDoc[path, default: 0] >= 2 { continue }
            perDoc[path, default: 0] += 1
            hits.append(KnowledgeHit(chunkID: id, path: path, title: r["title"]?.string ?? "", type: type, headingPath: r["heading_path"]?.string ?? "",
                                     text: r["text"]?.string ?? "", lineStart: r["line_start"]?.int ?? 0, lineEnd: r["line_end"]?.int ?? 0, page: r["page"]?.int,
                                     tsStart: r["ts_start"]?.double, resource: r["resource"]?.string, score: score))
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(k))
    }

    private func ftsIDs(_ match: String, limit: Int) throws -> [Int] {
        do {
            return try db.query("SELECT rowid AS id FROM chunks_fts WHERE chunks_fts MATCH ? ORDER BY bm25(chunks_fts, 1.0, 1.5, 2.0) LIMIT ?", [.text(match), .integer(limit)]).compactMap { $0["id"]?.int }
        } catch {
            return []   // a malformed MATCH expression is not an error for the user
        }
    }

    /// Literal substring search over chunk text (the MCP `grep` tool).
    public func grep(_ needle: String, limit: Int = 50, pathPrefix: String? = nil) throws -> [KnowledgeHit] {
        var sql = """
            SELECT c.id AS cid, c.heading_path, c.text, c.line_start, c.line_end, c.page, c.ts_start, d.path, d.title, d.type, d.resource
            FROM chunks c JOIN documents d ON d.id = c.document_id WHERE d.hidden = 0 AND c.text LIKE ? ESCAPE '\\'
            """
        var params: [SQLValue] = [.text("%" + needle.replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%")]
        if let pathPrefix { sql += " AND d.path LIKE ?"; params.append(.text(pathPrefix + "%")) }
        sql += " ORDER BY d.path, c.ordinal LIMIT ?"
        params.append(.integer(limit))
        return try db.query(sql, params).map { r in
            KnowledgeHit(chunkID: r["cid"]?.int ?? 0, path: r["path"]?.string ?? "", title: r["title"]?.string ?? "", type: r["type"]?.string ?? "",
                         headingPath: r["heading_path"]?.string ?? "", text: r["text"]?.string ?? "", lineStart: r["line_start"]?.int ?? 0, lineEnd: r["line_end"]?.int ?? 0,
                         page: r["page"]?.int, tsStart: r["ts_start"]?.double, resource: r["resource"]?.string, score: 1)
        }
    }

    // MARK: Ingest log, priors, meta, decisions

    public func ingestRecord(sourceKey: String) throws -> (path: String?, status: String)? {
        try db.query("SELECT document_path, status FROM ingest_log WHERE source_key = ?", [.text(sourceKey)]).first.map { ($0["document_path"]?.string, $0["status"]?.string ?? "") }
    }

    public func recordIngest(sourceKey: String, path: String?, status: String, error: String? = nil, reportJSON: String? = nil, now: Date = Date()) throws {
        try db.run("INSERT OR REPLACE INTO ingest_log(source_key, document_path, status, error, report_json, created_at) VALUES (?,?,?,?,?,?)",
                   [.text(sourceKey), path.map { .text($0) } ?? .null, .text(status), error.map { .text($0) } ?? .null, reportJSON.map { .text($0) } ?? .null, .real(now.timeIntervalSince1970)])
    }

    public func priors() throws -> [(key: String, project: String, weight: Double)] {
        try db.query("SELECT key, project, weight FROM project_priors").map { ($0["key"]?.string ?? "", $0["project"]?.string ?? "", $0["weight"]?.double ?? 1) }
    }

    public func bumpPrior(key: String, project: String, by delta: Double = 0.25) throws {
        let current = try db.query("SELECT weight FROM project_priors WHERE key = ? AND project = ?", [.text(key), .text(project)]).first?["weight"]?.double ?? 1
        try db.run("INSERT OR REPLACE INTO project_priors(key, project, weight) VALUES (?,?,?)", [.text(key), .text(project), .real(min(4, max(0.25, current + delta)))])
    }

    public func meta(_ key: String) -> String? { (try? db.query("SELECT value FROM meta WHERE key = ?", [.text(key)]).first?["value"]?.string) ?? nil }
    public func setMeta(_ key: String, _ value: String?) throws {
        if let value { try db.run("INSERT OR REPLACE INTO meta(key, value) VALUES (?,?)", [.text(key), .text(value)]) } else { try db.run("DELETE FROM meta WHERE key = ?", [.text(key)]) }
    }

    public func cachedDecision(hash: String, maxAge: TimeInterval = 86_400, now: Date = Date()) throws -> String? {
        guard let r = try db.query("SELECT answer_json, created_at FROM decision_cache WHERE hash = ?", [.text(hash)]).first,
              let t = r["created_at"]?.double, now.timeIntervalSince1970 - t <= maxAge else { return nil }
        return r["answer_json"]?.string
    }

    public func cacheDecision(hash: String, backend: String, answerJSON: String, now: Date = Date()) throws {
        try db.run("INSERT OR REPLACE INTO decision_cache(hash, backend, answer_json, created_at) VALUES (?,?,?,?)", [.text(hash), .text(backend), .text(answerJSON), .real(now.timeIntervalSince1970)])
    }
}
