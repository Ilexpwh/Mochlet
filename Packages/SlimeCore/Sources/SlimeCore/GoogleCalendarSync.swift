import Foundation
import GRDB

/// A complete, versioned set of unexpanded calendar records. Never an availability answer.
public struct GoogleCalendarSnapshot: Codable, Equatable, Sendable {
    public let version: String
    public let accountGeneration: String
    public let calendarID: String
    public let syncToken: String
    public let records: [ConnectedSource]
    public let cancelledOccurrences: [GoogleCalendarCancellation]
    public let syncedAt: Date
}

public struct GoogleCalendarCancellation: Codable, Equatable, Sendable {
    public let id: String
    public let seriesID: String
    public let originalStartTime: JSONValue
}

struct GoogleCalendarDelta: Sendable {
    let token: String
    let changed: [ConnectedSource]
    let deleted: Set<String>
    let cancelledOccurrences: [GoogleCalendarCancellation]
    let startedAt: Date
}

extension GoogleReader {
    func calendarChanges(calendarID: String, token: String?) async throws -> GoogleCalendarDelta {
        guard !calendarID.isEmpty, calendarID.utf8.count <= 1024 else { throw MochletError.message("Choose a valid calendar first.") }
        let started = Date()
        try await verify(scope: GoogleScope.calendar)
        // These parameters remain identical between full and incremental requests.
        // Expanding an unbounded recurring series could never finish a full synchronization.
        var query = ["singleEvents": "false", "showDeleted": "true", "maxResults": "250"]
        if let token { query["syncToken"] = token }
        var pages = Set<String>(), identities = Set<String>(), changed: [ConnectedSource] = [], deleted = Set<String>()
        var cancellations: [GoogleCalendarCancellation] = []
        var size = 0
        for _ in 0..<40 {
            try Task.checkCancellation()
            let page = try await get("www.googleapis.com", ["calendar", "v3", "calendars", calendarID, "events"], query)
            guard case .array(let rows) = page["items"] else { throw MochletError.message("Google omitted the calendar records. Previous sync was kept.") }
            for row in rows {
                guard let id = row["id"].string, !id.isEmpty, identities.insert(id).inserted,
                      identities.count <= 5000 else { throw MochletError.message("Calendar sync contains duplicate identities or exceeds 5,000 changes. Previous sync was kept.") }
                if row["status"].string == "cancelled" {
                    deleted.insert(id)
                    if let series = row["recurringEventId"].string {
                        guard !series.isEmpty, row["originalStartTime"]["date"].string != nil || row["originalStartTime"]["dateTime"].string != nil else {
                            throw MochletError.message("A cancelled occurrence has no original start time. Previous sync was kept.")
                        }
                        cancellations.append(.init(id: id, seriesID: series, originalStartTime: row["originalStartTime"]))
                    }
                    continue
                }
                guard let revision = row["etag"].string, !revision.isEmpty else { throw MochletError.message("Calendar sync omitted an event revision. Previous sync was kept.") }
                let source = try calendarSource(row, calendarID: calendarID)
                size += source.body.utf8.count
                guard source.body.utf8.count <= 1_000_000, size <= 20_000_000 else { throw MochletError.message("Calendar text exceeds the local sync limit. Previous sync was kept.") }
                changed.append(source)
            }
            if let next = page["nextPageToken"].string, !next.isEmpty {
                guard next.utf8.count <= 8192, page["nextSyncToken"] == .null, pages.insert(next).inserted else { throw MochletError.message("Calendar pagination is inconsistent. Previous sync was kept.") }
                query["pageToken"] = next
            } else {
                guard let next = page["nextSyncToken"].string, !next.isEmpty, next.utf8.count <= 8192 else { throw MochletError.message("Google omitted the final sync token. Previous sync was kept.") }
                try Task.checkCancellation()
                return .init(token: next, changed: changed, deleted: deleted, cancelledOccurrences: cancellations, startedAt: started)
            }
        }
        throw MochletError.message("Calendar sync exceeded 40 pages. Previous sync was kept.")
    }

    public func syncCalendar(calendarID: String, store: Store) async throws -> GoogleCalendarSnapshot {
        var previous = try await store.calendarSnapshot(account: account, calendarID: calendarID)
        let token = previous?.accountGeneration == account.generation ? previous?.syncToken : nil
        let delta: GoogleCalendarDelta
        do { delta = try await calendarChanges(calendarID: calendarID, token: token) }
        catch ConnectorError.http(410) where token != nil {
            // Invalidate only this calendar; a failed replacement must not look current.
            try Task.checkCancellation()
            try await store.resetCalendarSync(account: account, calendarID: calendarID, expected: previous)
            previous = nil
            delta = try await calendarChanges(calendarID: calendarID, token: nil)
        }
        try Task.checkCancellation()
        return try await store.commitCalendarSync(delta, account: account, calendarID: calendarID,
                                                   expected: previous, replacing: token == nil || previous == nil)
    }
}

extension Store {
    public func savedCalendarIDs(account: ConnectedAccount) throws -> [String] {
        try database.read { db in
            try Self.requireConnection(account, in: db)
            guard account.provider == "google", account.scopes.contains(GoogleScope.calendar) else { return [] }
            return try Data.fetchAll(db, sql: "SELECT payload FROM google_calendar_sync WHERE accountID=? ORDER BY calendarID", arguments: [account.id])
                .map { try JSONDecoder().decode(GoogleCalendarSnapshot.self, from: $0) }
                .filter { $0.accountGeneration == account.generation }.map(\.calendarID)
        }
    }
    private static func calendarSnapshot(accountID: String, calendarID: String, db: Database) throws -> GoogleCalendarSnapshot? {
        try Data.fetchOne(db, sql: "SELECT payload FROM google_calendar_sync WHERE accountID=? AND calendarID=?", arguments: [accountID, calendarID])
            .map { try JSONDecoder().decode(GoogleCalendarSnapshot.self, from: $0) }
    }
    public func calendarSnapshot(account: ConnectedAccount, calendarID: String) throws -> GoogleCalendarSnapshot? {
        try database.read { db in
            try Self.requireConnection(account, in: db)
            guard account.provider == "google", account.scopes.contains(GoogleScope.calendar) else { throw MochletError.message("Calendar read permission is unavailable.") }
            return try Self.calendarSnapshot(accountID: account.id, calendarID: calendarID, db: db)
        }
    }
    private static func requireCalendarVersion(_ expected: GoogleCalendarSnapshot?, account: ConnectedAccount, calendarID: String, db: Database) throws {
        try requireConnection(account, in: db)
        guard account.provider == "google", account.scopes.contains(GoogleScope.calendar),
              try calendarSnapshot(accountID: account.id, calendarID: calendarID, db: db)?.version == expected?.version else {
            throw MochletError.message("Calendar sync or account access changed. Synchronize again.")
        }
    }
    func resetCalendarSync(account: ConnectedAccount, calendarID: String, expected: GoogleCalendarSnapshot?) throws {
        try database.write { db in
            try Self.requireCalendarVersion(expected, account: account, calendarID: calendarID, db: db)
            try db.execute(sql: "DELETE FROM google_calendar_sync WHERE accountID=? AND calendarID=?", arguments: [account.id, calendarID])
            try Self.removeCalendarSources(account: account, calendarID: calendarID, db: db) { _ in true }
        }
    }
    private static func removeCalendarSources(account: ConnectedAccount, calendarID: String, db: Database,
                                              where predicate: (ConnectedSource) throws -> Bool) throws {
        for data in try Data.fetchAll(db, sql: "SELECT payload FROM connected_sources WHERE accountID=?", arguments: [account.id]) {
            let source = try JSONDecoder().decode(ConnectedSource.self, from: data)
            if source.service == "calendar", source.collection == calendarID, try predicate(source) {
                try db.execute(sql: "DELETE FROM connected_sources WHERE accountID=? AND sourceID=?", arguments: [account.id, source.id])
            }
        }
    }
    func commitCalendarSync(_ delta: GoogleCalendarDelta, account: ConnectedAccount, calendarID: String,
                            expected: GoogleCalendarSnapshot?, replacing: Bool) throws -> GoogleCalendarSnapshot {
        try database.write { db in
            try Task.checkCancellation()
            try Self.requireCalendarVersion(expected, account: account, calendarID: calendarID, db: db)
            guard replacing || expected?.accountGeneration == account.generation else { throw MochletError.message("Calendar permissions changed. A full sync is required.") }
            var records = Dictionary(uniqueKeysWithValues: (replacing ? [] : expected?.records ?? []).map { ($0.remoteID, $0) })
            var cancellations = Dictionary(uniqueKeysWithValues: (replacing ? [] : expected?.cancelledOccurrences ?? []).map { ($0.id, $0) })
            let changedIDs = Set(delta.changed.map(\.remoteID))
            for id in delta.deleted { records[id] = nil }
            for source in delta.changed {
                guard source.accountID == account.id, source.service == "calendar", source.collection == calendarID else { throw MochletError.message("Calendar source identity mismatch.") }
                records[source.remoteID] = source
                cancellations[source.remoteID] = nil
            }
            for cancelled in delta.cancelledOccurrences { cancellations[cancelled.id] = cancelled }
            cancellations = cancellations.filter { !delta.deleted.contains($0.value.seriesID) }
            records = try records.filter { _, source in
                let body = try JSONDecoder().decode(JSONValue.self, from: Data(source.body.utf8))
                return !(body["recurringEventId"].string.map { delta.deleted.contains($0) } ?? false)
            }
            let snapshot = GoogleCalendarSnapshot(version: UUID().uuidString, accountGeneration: account.generation,
                calendarID: calendarID, syncToken: delta.token,
                records: records.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending },
                cancelledOccurrences: cancellations.values.sorted { $0.id < $1.id }, syncedAt: Date())
            let payload = try JSONEncoder().encode(snapshot)
            guard records.count + cancellations.count <= 5000, payload.count <= 25_000_000 else { throw MochletError.message("Saved calendar exceeds 5,000 records or 25 MB. Previous sync was kept.") }
            // Invalidate cached agenda instances when their series changes or disappears.
            // Reads completed after this request began remain available for their own revision checks.
            try Self.removeCalendarSources(account: account, calendarID: calendarID, db: db) { source in
                guard source.fetchedAt <= delta.startedAt else { return false }
                if replacing || delta.deleted.contains(source.remoteID) { return true }
                let body = try JSONDecoder().decode(JSONValue.self, from: Data(source.body.utf8))
                return body["recurringEventId"].string.map { changedIDs.contains($0) || delta.deleted.contains($0) } ?? false
            }
            for source in delta.changed {
                if let data = try Data.fetchOne(db, sql: "SELECT payload FROM connected_sources WHERE accountID=? AND sourceID=?", arguments: [account.id, source.id]),
                   try JSONDecoder().decode(ConnectedSource.self, from: data).fetchedAt > delta.startedAt { continue }
                try db.execute(sql: "INSERT INTO connected_sources(accountID,sourceID,payload) VALUES(?,?,?) ON CONFLICT(accountID,sourceID) DO UPDATE SET payload=excluded.payload", arguments: [account.id, source.id, try JSONEncoder().encode(source)])
            }
            try db.execute(sql: "INSERT INTO google_calendar_sync(accountID,calendarID,payload) VALUES(?,?,?) ON CONFLICT(accountID,calendarID) DO UPDATE SET payload=excluded.payload", arguments: [account.id, calendarID, payload])
            return snapshot
        }
    }
}
