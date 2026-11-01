import Foundation
import GRDB

public struct GoogleMailSnapshot: Codable, Equatable, Sendable {
    public var version = UUID().uuidString
    public var accountGeneration: String
    public var threadIDs: Set<String> = []
    public var records: [ConnectedSource] = []
    public var historyID: String?
    public var syncedAt: Date?
}

struct GoogleMailDelta: Sendable {
    let historyID: String
    let changed: [ConnectedSource]
    let deleted: Set<String>
    let startedAt: Date
}

extension GoogleReader {
    static func validHistoryID(_ value: String?) -> Bool {
        guard let value, !value.isEmpty, value.utf8.count <= 30 else { return false }
        return value.utf8.allSatisfy { (48...57).contains($0) }
    }
    func mailHistory(since: String) async throws -> (String, Set<String>) {
        guard Self.validHistoryID(since) else { throw MochletError.message("Gmail history cursor is invalid. Rebuild tracked threads.") }
        var query = ["startHistoryId": since, "maxResults": "100"], pages = Set<String>(), threads = Set<String>()
        var count = 0
        for _ in 0..<20 {
            try Task.checkCancellation()
            let page = try await get("gmail.googleapis.com", ["gmail", "v1", "users", "me", "history"], query)
            guard page["history"] == .null || { if case .array = page["history"] { return true }; return false }() else {
                throw MochletError.message("Gmail history is malformed. Previous sync was kept.")
            }
            for entry in page["history"].array {
                count += 1
                guard count <= 2000, Self.validHistoryID(entry["id"].string) else { throw MochletError.message("Gmail history exceeds the local limit or has invalid identities. Rebuild tracked threads.") }
                var messages: [JSONValue] = []
                for field in ["messagesAdded", "messagesDeleted", "labelsAdded", "labelsRemoved"] {
                    guard entry[field] == .null || { if case .array = entry[field] { return true }; return false }() else { throw MochletError.message("Gmail history change is malformed.") }
                    messages += entry[field].array.map { $0["message"] }
                }
                // Older/minimal responses may expose only the general message list.
                if messages.isEmpty {
                    guard entry["messages"] == .null || { if case .array = entry["messages"] { return true }; return false }() else { throw MochletError.message("Gmail history messages are malformed.") }
                    messages = entry["messages"].array
                }
                for message in messages {
                    guard let id = message["threadId"].string, !id.isEmpty, id.utf8.count <= 256 else { throw MochletError.message("Gmail omitted a changed thread identity. Previous sync was kept.") }
                    threads.insert(id)
                    guard threads.count <= 10_000 else { throw MochletError.message("Gmail history contains too many changed threads. Rebuild tracked threads.") }
                }
            }
            if let next = page["nextPageToken"].string, !next.isEmpty {
                guard next.utf8.count <= 8192, pages.insert(next).inserted else { throw MochletError.message("Gmail repeated a history page. Previous sync was kept.") }
                query["pageToken"] = next
            } else {
                guard let next = page["historyId"].string, Self.validHistoryID(next) else { throw MochletError.message("Gmail omitted its final history cursor. Previous sync was kept.") }
                return (next, threads)
            }
        }
        throw MochletError.message("Gmail history exceeded 20 pages. Rebuild tracked threads.")
    }

    public func syncTrackedMail(store: Store, rebuild: Bool = false) async throws -> GoogleMailSnapshot {
        guard var previous = try await store.mailSnapshot(account: account), !previous.threadIDs.isEmpty else { throw MochletError.message("Track a selected email thread first.") }
        let started = Date()
        try await verify(scope: GoogleScope.mail)
        var replacing = rebuild || previous.accountGeneration != account.generation || previous.historyID == nil
        var historyID = "", requested = previous.threadIDs
        if !replacing, let cursor = previous.historyID {
            do {
                let history = try await mailHistory(since: cursor)
                historyID = history.0; requested = history.1.intersection(previous.threadIDs)
            } catch ConnectorError.http(404) {
                try Task.checkCancellation()
                previous = try await store.invalidateMailSync(account: account, expected: previous)
                replacing = true
            }
        }
        if replacing {
            // Capture before thread reads: changes during those reads will be replayed next time.
            let profile = try await get("gmail.googleapis.com", ["gmail", "v1", "users", "me", "profile"])
            guard let cursor = profile["historyId"].string, Self.validHistoryID(cursor) else { throw MochletError.message("Gmail omitted its mailbox history cursor.") }
            historyID = cursor; requested = previous.threadIDs
        }
        var changed: [ConnectedSource] = [], deleted = Set<String>(), size = 0
        for id in requested.sorted() {
            try Task.checkCancellation()
            do {
                let source = try await readVerifiedThread(id)
                guard Self.validHistoryID(source.revision) else { throw MochletError.message("Gmail omitted the thread revision.") }
                size += source.body.utf8.count
                guard size <= 20_000_000 else { throw MochletError.message("Tracked mail exceeds 20 MB of text. Stop tracking some threads before syncing again.") }
                changed.append(source)
            } catch ConnectorError.http(404) { deleted.insert(id) }
        }
        try Task.checkCancellation()
        return try await store.commitMailSync(.init(historyID: historyID, changed: changed, deleted: deleted, startedAt: started),
                                              account: account, expected: previous, replacing: replacing)
    }
}

extension Store {
    private static func mailSnapshot(accountID: String, db: Database) throws -> GoogleMailSnapshot? {
        try Data.fetchOne(db, sql: "SELECT payload FROM google_mail_sync WHERE accountID=?", arguments: [accountID])
            .map { try JSONDecoder().decode(GoogleMailSnapshot.self, from: $0) }
    }
    private static func requireMailAccount(_ account: ConnectedAccount, db: Database) throws {
        try requireConnection(account, in: db)
        guard account.provider == "google", account.scopes.contains(GoogleScope.mail) else { throw MochletError.message("Gmail read permission is unavailable.") }
    }
    public func mailSnapshot(account: ConnectedAccount) throws -> GoogleMailSnapshot? {
        try database.read { db in
            try Self.requireMailAccount(account, db: db)
            return try Self.mailSnapshot(accountID: account.id, db: db)
        }
    }
    private static func saveMailSnapshot(_ snapshot: GoogleMailSnapshot, account: ConnectedAccount, db: Database) throws {
        let data = try JSONEncoder().encode(snapshot)
        guard snapshot.threadIDs.count <= 100, data.count <= 25_000_000 else { throw MochletError.message("Track at most 100 threads and 25 MB of saved mail text.") }
        try db.execute(sql: "INSERT INTO google_mail_sync(accountID,payload) VALUES(?,?) ON CONFLICT(accountID) DO UPDATE SET payload=excluded.payload", arguments: [account.id, data])
    }
    public func trackMail(_ source: ConnectedSource, account: ConnectedAccount) throws -> GoogleMailSnapshot {
        try database.write { db in
            try Self.requireMailAccount(account, db: db); try Self.requireSource(source, account: account, in: db)
            guard source.service == "gmail", source.collection == "threads", !source.remoteID.isEmpty, source.remoteID.utf8.count <= 256,
                  GoogleReader.validHistoryID(source.revision) else { throw MochletError.message("Read the selected Gmail thread before tracking it.") }
            var snapshot = try Self.mailSnapshot(accountID: account.id, db: db) ?? .init(accountGeneration: account.generation)
            if snapshot.accountGeneration != account.generation { snapshot.records = [] }
            snapshot.version = UUID().uuidString; snapshot.accountGeneration = account.generation
            snapshot.historyID = nil; snapshot.syncedAt = nil; snapshot.threadIDs.insert(source.remoteID)
            snapshot.records.removeAll { $0.remoteID == source.remoteID }; snapshot.records.append(source)
            try Self.saveMailSnapshot(snapshot, account: account, db: db); return snapshot
        }
    }
    public func untrackMail(threadID: String, account: ConnectedAccount) throws -> GoogleMailSnapshot {
        try database.write { db in
            try Self.requireMailAccount(account, db: db)
            var snapshot = try Self.mailSnapshot(accountID: account.id, db: db) ?? .init(accountGeneration: account.generation)
            snapshot.version = UUID().uuidString; snapshot.historyID = nil; snapshot.syncedAt = nil
            if snapshot.accountGeneration != account.generation { snapshot.records = []; snapshot.accountGeneration = account.generation }
            snapshot.threadIDs.remove(threadID); snapshot.records.removeAll { $0.remoteID == threadID }
            try Self.saveMailSnapshot(snapshot, account: account, db: db); return snapshot
        }
    }
    private static func requireMailVersion(_ expected: GoogleMailSnapshot, account: ConnectedAccount, db: Database) throws {
        try requireMailAccount(account, db: db)
        guard try mailSnapshot(accountID: account.id, db: db)?.version == expected.version else { throw MochletError.message("Tracked threads or sync state changed. Synchronize again.") }
    }
    func invalidateMailSync(account: ConnectedAccount, expected: GoogleMailSnapshot) throws -> GoogleMailSnapshot {
        try database.write { db in
            try Self.requireMailVersion(expected, account: account, db: db)
            var cleared = expected; cleared.version = UUID().uuidString; cleared.historyID = nil; cleared.syncedAt = nil; cleared.records = []
            for source in expected.records {
                try db.execute(sql: "DELETE FROM connected_sources WHERE accountID=? AND sourceID=?", arguments: [account.id, source.id])
            }
            try Self.saveMailSnapshot(cleared, account: account, db: db); return cleared
        }
    }
    func commitMailSync(_ delta: GoogleMailDelta, account: ConnectedAccount, expected: GoogleMailSnapshot, replacing: Bool) throws -> GoogleMailSnapshot {
        try database.write { db in
            try Task.checkCancellation(); try Self.requireMailVersion(expected, account: account, db: db)
            guard replacing || expected.accountGeneration == account.generation else { throw MochletError.message("Mail permissions changed. Rebuild tracked threads.") }
            var records = Dictionary(uniqueKeysWithValues: (replacing ? [] : expected.records).map { ($0.remoteID, $0) })
            let incoming = Set(delta.changed.map(\.remoteID)).union(delta.deleted)
            guard incoming.isSubset(of: expected.threadIDs), !replacing || incoming == expected.threadIDs else { throw MochletError.message("Mail synchronization returned an unexpected thread set.") }
            for id in delta.deleted { records[id] = nil }
            for source in delta.changed {
                guard source.accountID == account.id, source.service == "gmail", source.collection == "threads" else { throw MochletError.message("Mail source identity mismatch.") }
                records[source.remoteID] = source
            }
            var snapshot = GoogleMailSnapshot(accountGeneration: account.generation)
            snapshot.threadIDs = expected.threadIDs.subtracting(delta.deleted)
            snapshot.records = records.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            snapshot.historyID = delta.historyID; snapshot.syncedAt = Date()
            try Self.saveMailSnapshot(snapshot, account: account, db: db)
            for id in delta.deleted {
                let source = ConnectedSource(accountID: account.id, service: "gmail", collection: "threads", remoteID: id, title: "", body: "", url: "", revision: "")
                try db.execute(sql: "DELETE FROM connected_sources WHERE accountID=? AND sourceID=?", arguments: [account.id, source.id])
            }
            for source in delta.changed {
                if let data = try Data.fetchOne(db, sql: "SELECT payload FROM connected_sources WHERE accountID=? AND sourceID=?", arguments: [account.id, source.id]),
                   try JSONDecoder().decode(ConnectedSource.self, from: data).fetchedAt > delta.startedAt { continue }
                try db.execute(sql: "INSERT INTO connected_sources(accountID,sourceID,payload) VALUES(?,?,?) ON CONFLICT(accountID,sourceID) DO UPDATE SET payload=excluded.payload", arguments: [account.id, source.id, try JSONEncoder().encode(source)])
            }
            return snapshot
        }
    }
}
