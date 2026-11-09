import Foundation

/// `signals.sqlite`: sources' fetch state, items, scores, write-ups, embeddings, events and their links,
/// the hotness history, digests, the fetch log and the daily LLM usage. Pure SQL over `SQLiteDB`.
public final class SignalsStore: @unchecked Sendable {
    public let db: SQLiteDB

    public init(path: String) throws {
        db = try SQLiteDB(path: path)
        try db.migrate(Self.migrations)
    }

    public static func inMemory() throws -> SignalsStore { try SignalsStore(path: ":memory:") }

    static let migrations: [String] = [
        """
        CREATE TABLE IF NOT EXISTS sources(id TEXT PRIMARY KEY, etag TEXT, last_modified TEXT, last_fetch REAL, next_fetch REAL, failures INTEGER DEFAULT 0, last_error TEXT, fetched INTEGER DEFAULT 0);
        CREATE TABLE IF NOT EXISTS items(id TEXT PRIMARY KEY, source_id TEXT NOT NULL, external_id TEXT NOT NULL, url TEXT, canonical_url TEXT, title TEXT, title_norm TEXT, summary TEXT, body TEXT, author TEXT,
            published REAL, discovered REAL NOT NULL, status TEXT NOT NULL, event_id TEXT, backfill INTEGER DEFAULT 0, simhash INTEGER DEFAULT 0, lang TEXT, UNIQUE(source_id, external_id));
        CREATE INDEX IF NOT EXISTS items_discovered ON items(discovered);
        CREATE INDEX IF NOT EXISTS items_status ON items(status);
        CREATE INDEX IF NOT EXISTS items_event ON items(event_id);
        CREATE TABLE IF NOT EXISTS scores(item_id TEXT PRIMARY KEY, score1 REAL, score2 REAL, category TEXT, tags TEXT, main_entity TEXT, reasons TEXT, rubric_hash TEXT, scored_at REAL);
        CREATE TABLE IF NOT EXISTS writings(item_id TEXT PRIMARY KEY, title_en TEXT, summary_en TEXT, reason TEXT);
        CREATE TABLE IF NOT EXISTS item_embeddings(item_id TEXT PRIMARY KEY, dim INTEGER, vector BLOB);
        CREATE TABLE IF NOT EXISTS events(id TEXT PRIMARY KEY, title TEXT, first_seen REAL, last_seen REAL, hotness REAL DEFAULT 0, rising INTEGER DEFAULT 0, is_new INTEGER DEFAULT 1, sources INTEGER DEFAULT 1, top_item TEXT);
        CREATE TABLE IF NOT EXISTS event_links(a TEXT, b TEXT, relation TEXT, confidence REAL, PRIMARY KEY(a, b));
        CREATE TABLE IF NOT EXISTS hotness_history(event_id TEXT, at REAL, hotness REAL);
        CREATE INDEX IF NOT EXISTS hotness_event ON hotness_history(event_id, at);
        CREATE TABLE IF NOT EXISTS digests(day TEXT PRIMARY KEY, path TEXT, items INTEGER, hot INTEGER, composed_at REAL, events TEXT);
        CREATE TABLE IF NOT EXISTS fetch_log(source_id TEXT, at REAL, status TEXT, items INTEGER, error TEXT);
        CREATE INDEX IF NOT EXISTS fetch_log_source ON fetch_log(source_id, at);
        CREATE TABLE IF NOT EXISTS llm_usage(day TEXT, task TEXT, calls INTEGER DEFAULT 0, PRIMARY KEY(day, task));
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
        """,
    ]

    // MARK: Sources

    public struct SourceState: Sendable, Equatable {
        public var etag: String?
        public var lastModified: String?
        public var lastFetch: Date?
        public var nextFetch: Date?
        public var failures: Int
        public var lastError: String?
        public var fetched: Int
        public init(etag: String? = nil, lastModified: String? = nil, lastFetch: Date? = nil, nextFetch: Date? = nil, failures: Int = 0, lastError: String? = nil, fetched: Int = 0) {
            self.etag = etag
            self.lastModified = lastModified
            self.lastFetch = lastFetch
            self.nextFetch = nextFetch
            self.failures = failures
            self.lastError = lastError
            self.fetched = fetched
        }
    }

    public func sourceState(_ id: String) throws -> SourceState {
        guard let r = try db.query("SELECT * FROM sources WHERE id = ?", [.text(id)]).first else { return SourceState() }
        return SourceState(etag: r["etag"]?.string, lastModified: r["last_modified"]?.string, lastFetch: r["last_fetch"]?.double.map { Date(timeIntervalSince1970: $0) },
                           nextFetch: r["next_fetch"]?.double.map { Date(timeIntervalSince1970: $0) }, failures: r["failures"]?.int ?? 0, lastError: r["last_error"]?.string, fetched: r["fetched"]?.int ?? 0)
    }

    public func saveSourceState(_ id: String, _ s: SourceState) throws {
        _ = try db.run("INSERT INTO sources(id, etag, last_modified, last_fetch, next_fetch, failures, last_error, fetched) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET etag=excluded.etag, last_modified=excluded.last_modified, last_fetch=excluded.last_fetch, next_fetch=excluded.next_fetch, failures=excluded.failures, last_error=excluded.last_error, fetched=excluded.fetched",
                       [.text(id), s.etag.map { .text($0) } ?? .null, s.lastModified.map { .text($0) } ?? .null, s.lastFetch.map { .double($0.timeIntervalSince1970) } ?? .null,
                        s.nextFetch.map { .double($0.timeIntervalSince1970) } ?? .null, .integer(s.failures), s.lastError.map { .text($0) } ?? .null, .integer(s.fetched)])
    }

    public func logFetch(_ sourceID: String, status: String, items: Int, error: String?, at: Date = Date()) throws {
        _ = try db.run("INSERT INTO fetch_log(source_id, at, status, items, error) VALUES(?,?,?,?,?)", [.text(sourceID), .double(at.timeIntervalSince1970), .text(status), .integer(items), error.map { .text($0) } ?? .null])
    }

    /// Accepted items per day over the last seven days, for the fetch interval.
    public func yieldPerDay(_ sourceID: String, now: Date = Date()) throws -> Double {
        let since = now.addingTimeInterval(-7 * 24 * 3600).timeIntervalSince1970
        let n = try db.query("SELECT COUNT(*) AS n FROM items WHERE source_id = ? AND discovered >= ? AND status IN ('accepted','written')", [.text(sourceID), .double(since)]).first?["n"]?.int ?? 0
        return Double(n) / 7
    }

    // MARK: Items

    /// Inserts when the item is new; returns false when the URL or the (source, external id) is already known.
    @discardableResult
    public func insert(_ it: SignalItem) throws -> Bool {
        let n = try db.run("INSERT OR IGNORE INTO items(id, source_id, external_id, url, canonical_url, title, title_norm, summary, body, author, published, discovered, status, event_id, backfill, simhash, lang) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                           [.text(it.id), .text(it.sourceID), .text(it.externalID), .text(it.url), .text(it.canonicalURL), .text(it.title), .text(it.titleNorm), .text(it.summary), .text(it.body),
                            it.author.map { .text($0) } ?? .null, it.publishedAt.map { .double($0.timeIntervalSince1970) } ?? .null, .double(it.discoveredAt.timeIntervalSince1970), .text(it.status.rawValue),
                            it.eventID.map { .text($0) } ?? .null, .integer(it.backfill ? 1 : 0), .int(Int64(bitPattern: it.simhash)), it.language.map { .text($0) } ?? .null])
        return n > 0
    }

    public func item(_ id: String) throws -> SignalItem? { try db.query("SELECT * FROM items WHERE id = ?", [.text(id)]).first.map(Self.item) }

    public func items(status: ItemStatus, limit: Int = 100) throws -> [SignalItem] {
        try db.query("SELECT * FROM items WHERE status = ? ORDER BY discovered ASC LIMIT ?", [.text(status.rawValue), .integer(limit)]).map(Self.item)
    }

    public func items(since: Date, statuses: [ItemStatus]? = nil) throws -> [SignalItem] {
        let filter = statuses.map { " AND status IN (" + $0.map { "'\($0.rawValue)'" }.joined(separator: ",") + ")" } ?? ""
        return try db.query("SELECT * FROM items WHERE discovered >= ?\(filter) ORDER BY discovered DESC", [.double(since.timeIntervalSince1970)]).map(Self.item)
    }

    public func recentSimhashes(hours: Double = 72, now: Date = Date()) throws -> [(id: String, hash: UInt64)] {
        try db.query("SELECT id, simhash FROM items WHERE discovered >= ?", [.double(now.addingTimeInterval(-hours * 3600).timeIntervalSince1970)]).compactMap { r in
            guard let id = r["id"]?.string, case .int(let h)? = r["simhash"] else { return nil }
            return (id, UInt64(bitPattern: h))
        }
    }

    public func setStatus(_ id: String, _ status: ItemStatus) throws { _ = try db.run("UPDATE items SET status = ? WHERE id = ?", [.text(status.rawValue), .text(id)]) }
    public func setBody(_ id: String, _ body: String) throws { _ = try db.run("UPDATE items SET body = ? WHERE id = ?", [.text(body), .text(id)]) }
    public func setEvent(_ id: String, _ eventID: String) throws { _ = try db.run("UPDATE items SET event_id = ? WHERE id = ?", [.text(eventID), .text(id)]) }
    public func countItems(since: Date) throws -> Int { try db.query("SELECT COUNT(*) AS n FROM items WHERE discovered >= ?", [.double(since.timeIntervalSince1970)]).first?["n"]?.int ?? 0 }
    public func countItems(status: ItemStatus) throws -> Int { try db.query("SELECT COUNT(*) AS n FROM items WHERE status = ?", [.text(status.rawValue)]).first?["n"]?.int ?? 0 }

    static func item(_ r: [String: SQLValue]) -> SignalItem {
        var it = SignalItem(sourceID: r["source_id"]?.string ?? "", externalID: r["external_id"]?.string ?? "", url: r["url"]?.string ?? "", title: r["title"]?.string ?? "",
                            summary: r["summary"]?.string ?? "", body: r["body"]?.string ?? "", author: r["author"]?.string,
                            publishedAt: r["published"]?.double.map { Date(timeIntervalSince1970: $0) }, discoveredAt: Date(timeIntervalSince1970: r["discovered"]?.double ?? 0),
                            backfill: (r["backfill"]?.int ?? 0) != 0, language: r["lang"]?.string)
        it.id = r["id"]?.string ?? it.id
        it.canonicalURL = r["canonical_url"]?.string ?? it.canonicalURL
        it.titleNorm = r["title_norm"]?.string ?? it.titleNorm
        it.status = ItemStatus(rawValue: r["status"]?.string ?? "new") ?? .new
        it.eventID = r["event_id"]?.string
        if case .int(let h)? = r["simhash"] { it.simhash = UInt64(bitPattern: h) }
        return it
    }

    // MARK: Scores, writings, embeddings

    public func saveScore(_ itemID: String, _ s: SignalScore, at: Date = Date()) throws {
        _ = try db.run("INSERT OR REPLACE INTO scores(item_id, score1, score2, category, tags, main_entity, reasons, rubric_hash, scored_at) VALUES(?,?,?,?,?,?,?,?,?)",
                       [.text(itemID), .double(s.score1), .double(s.score2), .text(s.category), .text(s.tags.joined(separator: ",")), s.mainEntity.map { .text($0) } ?? .null, .text(s.reasons), .text(s.rubricHash), .double(at.timeIntervalSince1970)])
    }

    public func score(_ itemID: String) throws -> SignalScore? {
        guard let r = try db.query("SELECT * FROM scores WHERE item_id = ?", [.text(itemID)]).first else { return nil }
        return SignalScore(score1: r["score1"]?.double ?? 0, score2: r["score2"]?.double ?? 0, category: r["category"]?.string ?? "", tags: (r["tags"]?.string ?? "").split(separator: ",").map(String.init),
                           mainEntity: r["main_entity"]?.string, reasons: r["reasons"]?.string ?? "", rubricHash: r["rubric_hash"]?.string ?? "")
    }

    public func saveWriting(_ itemID: String, _ w: SignalWriting) throws {
        // Column names kept from the bilingual era so existing databases need no migration.
        _ = try db.run("INSERT OR REPLACE INTO writings(item_id, title_en, summary_en, reason) VALUES(?,?,?,?)",
                       [.text(itemID), .text(w.title), .text(w.summary), .text(w.reason)])
    }

    public func writing(_ itemID: String) throws -> SignalWriting? {
        guard let r = try db.query("SELECT * FROM writings WHERE item_id = ?", [.text(itemID)]).first else { return nil }
        return SignalWriting(title: r["title_en"]?.string ?? "", summary: r["summary_en"]?.string ?? "", reason: r["reason"]?.string ?? "")
    }

    public func saveEmbedding(_ itemID: String, _ v: [Float]) throws {
        let data = v.withUnsafeBufferPointer { Data(buffer: $0) }
        _ = try db.run("INSERT OR REPLACE INTO item_embeddings(item_id, dim, vector) VALUES(?,?,?)", [.text(itemID), .integer(v.count), .blob(data)])
    }

    public func embeddings(itemIDs: [String]) throws -> [String: [Float]] {
        guard !itemIDs.isEmpty else { return [:] }
        let marks = itemIDs.map { _ in "?" }.joined(separator: ",")
        var out: [String: [Float]] = [:]
        for r in try db.query("SELECT item_id, vector FROM item_embeddings WHERE item_id IN (\(marks))", itemIDs.map { .text($0) }) {
            guard let id = r["item_id"]?.string, let d = r["vector"]?.data else { continue }
            out[id] = d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        return out
    }

    // MARK: Events

    public func saveEvent(_ e: SignalEvent) throws {
        _ = try db.run("INSERT OR REPLACE INTO events(id, title, first_seen, last_seen, hotness, rising, is_new, sources, top_item) VALUES(?,?,?,?,?,?,?,?,?)",
                       [.text(e.id), .text(e.title), .double(e.firstSeen.timeIntervalSince1970), .double(e.lastSeen.timeIntervalSince1970), .double(e.hotness), .integer(e.rising ? 1 : 0), .integer(e.isNew ? 1 : 0), .integer(e.sourceCount), .text(e.topItemID)])
    }

    public func event(_ id: String) throws -> SignalEvent? { try db.query("SELECT * FROM events WHERE id = ?", [.text(id)]).first.map(Self.event) }

    public func events(since: Date, limit: Int = 200) throws -> [SignalEvent] {
        try db.query("SELECT * FROM events WHERE last_seen >= ? ORDER BY hotness DESC, last_seen DESC LIMIT ?", [.double(since.timeIntervalSince1970), .integer(limit)]).map(Self.event)
    }

    static func event(_ r: [String: SQLValue]) -> SignalEvent {
        SignalEvent(id: r["id"]?.string ?? "", title: r["title"]?.string ?? "", firstSeen: Date(timeIntervalSince1970: r["first_seen"]?.double ?? 0), lastSeen: Date(timeIntervalSince1970: r["last_seen"]?.double ?? 0),
                    hotness: r["hotness"]?.double ?? 0, rising: (r["rising"]?.int ?? 0) != 0, isNew: (r["is_new"]?.int ?? 0) != 0, sourceCount: r["sources"]?.int ?? 1, topItemID: r["top_item"]?.string ?? "")
    }

    public func link(_ a: String, _ b: String, relation: EventRelation, confidence: Double) throws {
        let (x, y) = a < b ? (a, b) : (b, a)
        _ = try db.run("INSERT OR REPLACE INTO event_links(a, b, relation, confidence) VALUES(?,?,?,?)", [.text(x), .text(y), .text(relation.rawValue), .double(confidence)])
    }

    public func linkChecked(_ a: String, _ b: String) throws -> Bool {
        let (x, y) = a < b ? (a, b) : (b, a)
        return !(try db.query("SELECT 1 FROM event_links WHERE a = ? AND b = ?", [.text(x), .text(y)])).isEmpty
    }

    /// Items of an event with their source and tier, for the hotness.
    public func mentions(eventID: String, tiers: [String: SourceTier]) throws -> [Hotness.Mention] {
        try db.query("SELECT source_id, published, discovered FROM items WHERE event_id = ?", [.text(eventID)]).map { r in
            let sid = r["source_id"]?.string ?? ""
            let at = Date(timeIntervalSince1970: r["published"]?.double ?? r["discovered"]?.double ?? 0)
            return Hotness.Mention(sourceID: sid, tier: tiers[sid] ?? .t2, at: at)
        }
    }

    public func recordHotness(_ eventID: String, _ h: Double, at: Date = Date()) throws {
        _ = try db.run("INSERT INTO hotness_history(event_id, at, hotness) VALUES(?,?,?)", [.text(eventID), .double(at.timeIntervalSince1970), .double(h)])
    }

    public func hotness(_ eventID: String, before: Date) throws -> Double? {
        try db.query("SELECT hotness FROM hotness_history WHERE event_id = ? AND at <= ? ORDER BY at DESC LIMIT 1", [.text(eventID), .double(before.timeIntervalSince1970)]).first?["hotness"]?.double
    }

    // MARK: Digests, usage, meta

    public func saveDigest(day: String, path: String, items: Int, hot: Int, events: [String], at: Date = Date()) throws {
        _ = try db.run("INSERT OR REPLACE INTO digests(day, path, items, hot, composed_at, events) VALUES(?,?,?,?,?,?)", [.text(day), .text(path), .integer(items), .integer(hot), .double(at.timeIntervalSince1970), .text(events.joined(separator: ","))])
    }

    public func digest(day: String) throws -> (path: String, items: Int, hot: Int)? {
        guard let r = try db.query("SELECT * FROM digests WHERE day = ?", [.text(day)]).first, let p = r["path"]?.string else { return nil }
        return (p, r["items"]?.int ?? 0, r["hot"]?.int ?? 0)
    }

    public func latestDigest() throws -> (day: String, path: String, items: Int, hot: Int)? {
        guard let r = try db.query("SELECT * FROM digests ORDER BY day DESC LIMIT 1").first, let d = r["day"]?.string, let p = r["path"]?.string else { return nil }
        return (d, p, r["items"]?.int ?? 0, r["hot"]?.int ?? 0)
    }

    /// Event ids shown in the last `count` digests, with the source count recorded then (stored as "id:n" or "id").
    /// `excludingDay` leaves out that day's own digest so recomposing a day does not hide what it showed.
    public func recentlyShown(count: Int = 7, excludingDay: String? = nil) throws -> [String: Int] {
        var out: [String: Int] = [:]
        let rows = try excludingDay.map { try db.query("SELECT events FROM digests WHERE day != ? ORDER BY day DESC LIMIT ?", [.text($0), .integer(count)]) }
            ?? db.query("SELECT events FROM digests ORDER BY day DESC LIMIT ?", [.integer(count)])
        for r in rows {
            for e in (r["events"]?.string ?? "").split(separator: ",") {
                let parts = e.split(separator: ":")
                let id = String(parts[0])
                let n = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
                out[id] = max(out[id] ?? 0, n)
            }
        }
        return out
    }

    public func usage(day: String, task: String) throws -> Int { try db.query("SELECT calls FROM llm_usage WHERE day = ? AND task = ?", [.text(day), .text(task)]).first?["calls"]?.int ?? 0 }
    public func bump(day: String, task: String, by: Int = 1) throws {
        _ = try db.run("INSERT INTO llm_usage(day, task, calls) VALUES(?,?,?) ON CONFLICT(day, task) DO UPDATE SET calls = calls + excluded.calls", [.text(day), .text(task), .integer(by)])
    }
    public func usageToday(day: String) throws -> [String: Int] {
        var out: [String: Int] = [:]
        for r in try db.query("SELECT task, calls FROM llm_usage WHERE day = ?", [.text(day)]) { if let t = r["task"]?.string { out[t] = r["calls"]?.int ?? 0 } }
        return out
    }

    public func meta(_ key: String) throws -> String? { try db.query("SELECT value FROM meta WHERE key = ?", [.text(key)]).first?["value"]?.string }
    public func setMeta(_ key: String, _ value: String) throws { _ = try db.run("INSERT OR REPLACE INTO meta(key, value) VALUES(?,?)", [.text(key), .text(value)]) }

    /// Old items and logs go after `days`.
    public func prune(olderThan days: Double = 60, now: Date = Date()) throws {
        let cutoff = now.addingTimeInterval(-days * 24 * 3600).timeIntervalSince1970
        _ = try db.run("DELETE FROM fetch_log WHERE at < ?", [.double(cutoff)])
        _ = try db.run("DELETE FROM hotness_history WHERE at < ?", [.double(cutoff)])
        let old = try db.query("SELECT id FROM items WHERE discovered < ?", [.double(cutoff)]).compactMap { $0["id"]?.string }
        for id in old {
            _ = try db.run("DELETE FROM scores WHERE item_id = ?", [.text(id)])
            _ = try db.run("DELETE FROM writings WHERE item_id = ?", [.text(id)])
            _ = try db.run("DELETE FROM item_embeddings WHERE item_id = ?", [.text(id)])
        }
        _ = try db.run("DELETE FROM items WHERE discovered < ?", [.double(cutoff)])
        _ = try db.run("DELETE FROM events WHERE last_seen < ?", [.double(cutoff)])
    }
}
