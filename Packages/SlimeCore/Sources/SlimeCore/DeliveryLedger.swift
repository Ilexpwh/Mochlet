import Foundation
import GRDB
import CryptoKit

public enum DeliveryKind: String, Codable, Sendable, CaseIterable {
    case gmailSend, gmailDraft, calendarCreate, calendarUpdate, calendarCancel
    public var scope: String {
        switch self {
        case .gmailSend: GoogleScope.send
        case .gmailDraft: GoogleScope.compose
        default: GoogleScope.calendarWrite
        }
    }
    public var title: String {
        switch self {
        case .gmailSend: "Send email"
        case .gmailDraft: "Save Gmail draft"
        case .calendarCreate: "Create event"
        case .calendarUpdate: "Update event"
        case .calendarCancel: "Cancel event"
        }
    }
}
public struct DeliveryDraft: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let accountID: String
    public let accountGeneration: String
    public let projectID: String
    public let kind: DeliveryKind
    public let collection: String
    public let remoteID: String
    public let expectedRevision: String
    public let payload: JSONValue
    public let preview: String
    public let expiresAt: Date
    public init(id: String = UUID().uuidString.lowercased(), account: ConnectedAccount, projectID: String, kind: DeliveryKind,
                collection: String, remoteID: String = "", expectedRevision: String = "", payload: JSONValue, preview: String) {
        self.id = id; accountID = account.id; accountGeneration = account.generation; self.projectID = projectID
        self.kind = kind; self.collection = collection; self.remoteID = remoteID; self.expectedRevision = expectedRevision
        self.payload = payload; self.preview = preview; expiresAt = Date().addingTimeInterval(900)
    }
    var conflictKey: String {
        let destination: JSONValue
        if kind == .calendarCreate {
            let event = payload["event"]
            destination = .object(["kind": .string(kind.rawValue), "calendar": .string(collection),
                "title": event["summary"], "start": event["start"], "end": event["end"], "attendees": event["attendees"]])
        } else {
            let group = kind == .calendarUpdate || kind == .calendarCancel ? "calendarExisting" : kind.rawValue
            destination = .array([.string(group), .string(collection), .string(remoteID)])
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try! encoder.encode(destination)).map { String(format: "%02x", $0) }.joined()
    }

}
public struct DeliveryRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String { draft.id }
    public let draft: DeliveryDraft
    public var state: String
    public var receipt: JSONValue
}
extension Store {
    public func prepareDelivery(_ draft: DeliveryDraft) throws {
        try database.write { db in
            try Self.authorizeDelivery(draft, in: db)
            try Self.excludeUncertain(draft, in: db)
            try db.execute(sql: "INSERT INTO deliveries(id,accountID,payload,state,receipt) VALUES(?,?,?,'prepared',?)", arguments: [draft.id, draft.accountID, try JSONEncoder().encode(draft), try JSONEncoder().encode(JSONValue.null)])
        }
    }
    public func claimDelivery(_ draft: DeliveryDraft) throws {
        try database.write { db in
            try Self.authorizeDelivery(draft, in: db)
            guard let row = try Row.fetchOne(db, sql: "SELECT payload,state FROM deliveries WHERE id=?", arguments: [draft.id]),
                  row["state"] as String == "prepared", try JSONDecoder().decode(DeliveryDraft.self, from: row["payload"]) == draft else {
                throw MochletError.message("This action changed or was already attempted. Inspect its delivery record; it will not be repeated.")
            }
            try Self.excludeUncertain(draft, in: db)
            // Commit before network I/O. A crash or lost response stays uncertain, never retryable.
            try db.execute(sql: "UPDATE deliveries SET state='uncertain' WHERE id=?", arguments: [draft.id])
        }
    }
    private static func excludeUncertain(_ draft: DeliveryDraft, in db: Database) throws {
        let prior = try Data.fetchAll(db, sql: "SELECT payload FROM deliveries WHERE accountID=? AND state='uncertain' AND id<>?", arguments: [draft.accountID, draft.id])
        for data in prior {
            let old = try JSONDecoder().decode(DeliveryDraft.self, from: data)
            guard old.conflictKey != draft.conflictKey else {
                throw MochletError.message("An earlier action for this destination is still uncertain. Reconcile it before preparing or delivering another action.")
            }
        }
    }
    private static func authorizeDelivery(_ draft: DeliveryDraft, in db: Database) throws {
        guard draft.expiresAt > Date(), draft.payload.formatted.utf8.count <= 1_500_000,
              let data = try Data.fetchOne(db, sql: "SELECT payload FROM connections WHERE id=?", arguments: [draft.accountID]) else {
            throw MochletError.message("This action expired or its account was disconnected. Prepare a fresh preview.")
        }
        let account = try JSONDecoder().decode(ConnectedAccount.self, from: data)
        guard account.provider == "google", account.generation == draft.accountGeneration, account.scopes.contains(draft.kind.scope),
              account.projectIDs.contains(draft.projectID), try Project.fetchOne(db, key: draft.projectID) != nil else {
            throw MochletError.message("The action's account, permission or project binding changed. Prepare a fresh preview.")
        }
    }
    public func finishDelivery(_ id: String, state: String, receipt: JSONValue) throws {
        guard ["delivered", "rejected", "uncertain"].contains(state) else { throw MochletError.message("Invalid delivery state.") }
        try database.write { db in
            try db.execute(sql: "UPDATE deliveries SET state=?,receipt=? WHERE id=? AND state='uncertain'", arguments: [state, try JSONEncoder().encode(receipt), id])
            guard db.changesCount == 1 else { throw MochletError.message("Delivery record is no longer awaiting a result.") }
        }
    }
    public func deliveries(accountID: String) throws -> [DeliveryRecord] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT payload,state,receipt FROM deliveries WHERE accountID=? ORDER BY rowid DESC LIMIT 200", arguments: [accountID]).compactMap { row in
                let draft = try JSONDecoder().decode(DeliveryDraft.self, from: row["payload"])
                guard draft.accountID == accountID else { return nil }
                return DeliveryRecord(draft: draft, state: row["state"], receipt: try JSONDecoder().decode(JSONValue.self, from: row["receipt"]))
            }
        }
    }
}
