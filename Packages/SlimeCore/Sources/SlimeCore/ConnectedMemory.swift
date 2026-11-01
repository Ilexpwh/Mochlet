import Foundation
import CryptoKit
import GRDB

/// Portable provenance, not an access grant. Retrieval still checks the local
/// connection, project permission and a freshly read remote source.
public struct ConnectedMemoryReference: Codable, Equatable, Sendable {
    public let accountID: String
    public let provider: String
    public let remoteAccountID: String
    public let sourceID: String
    public let revision: String
    public let contentHash: String
    public init(source: ConnectedSource, account: ConnectedAccount) throws {
        guard source.accountID == account.id else { throw MochletError.message("Memory source belongs to another account.") }
        accountID = account.id; provider = account.provider; remoteAccountID = account.remoteID
        sourceID = source.id; revision = source.revision; contentHash = Self.hash(source)
    }
    public static func hash(_ source: ConnectedSource) -> String {
        let data = try! JSONEncoder().encode([source.title, source.body, source.url] + source.warnings)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public func matches(_ source: ConnectedSource) -> Bool {
        source.accountID == accountID && source.id == sourceID && source.revision == revision && Self.hash(source) == contentHash
    }
}

public struct KnowledgeEvidence: Codable, Equatable, Sendable {
    public let id: String
    public let scope: String
    public let revision: String
    public init(_ note: KnowledgeNote) { id = note.id; scope = note.scope; revision = note.revision }
}

extension KnowledgeNote {
    public mutating func bind(source: ConnectedSource, account: ConnectedAccount) throws {
        connectionJSON = String(decoding: try JSONEncoder().encode(ConnectedMemoryReference(source: source, account: account)), as: UTF8.self)
    }
    public func connection() throws -> ConnectedMemoryReference? {
        try connectionJSON.map { try JSONDecoder().decode(ConnectedMemoryReference.self, from: Data($0.utf8)) }
    }
}

extension Store {
    public func memorySource(_ note: KnowledgeNote) throws -> (ConnectedAccount, ConnectedSource)? {
        guard let ref = try note.connection() else { return nil }
        return try sourceSnapshot(ref, projectID: note.scope)
    }
    public func sourceSnapshot(_ ref: ConnectedMemoryReference, projectID: String) throws -> (ConnectedAccount, ConnectedSource) {
        try database.read { try Self.sourceSnapshot(ref, projectID: projectID, in: $0) }
    }
    static func sourceSnapshot(_ ref: ConnectedMemoryReference, projectID: String, in db: Database) throws -> (ConnectedAccount, ConnectedSource) {
        guard let accountData = try Data.fetchOne(db, sql: "SELECT payload FROM connections WHERE id=?", arguments: [ref.accountID]),
              let sourceData = try Data.fetchOne(db, sql: "SELECT payload FROM connected_sources WHERE accountID=? AND sourceID=?", arguments: [ref.accountID, ref.sourceID]) else {
            throw MochletError.message("This connection or source is unavailable. Its retained content cannot be used as current AI context.")
        }
        let account = try JSONDecoder().decode(ConnectedAccount.self, from: accountData)
        let source = try JSONDecoder().decode(ConnectedSource.self, from: sourceData)
        guard account.provider == ref.provider, account.remoteID == ref.remoteAccountID,
              account.projectIDs.contains(projectID), ref.matches(source) else {
            throw MochletError.message("The source's project permission or revision changed. Read it again and prepare fresh context.")
        }
        try Self.requireSource(source, account: account, in: db)
        return (account, source)
    }
    public func allowsMemory(_ note: KnowledgeNote) -> Bool {
        do { _ = try memorySource(note); return true } catch { return false }
    }
    public func invalidateSource(_ source: ConnectedSource, account: ConnectedAccount) throws {
        try database.write { db in
            try Self.requireConnection(account, in: db)
            try db.execute(sql: "DELETE FROM connected_sources WHERE accountID=? AND sourceID=?", arguments: [account.id, source.id])
        }
    }
    public func queuedKnowledge(taskID: String) throws -> [KnowledgeEvidence] {
        try database.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM queued_knowledge WHERE taskID=?", arguments: [taskID]) else { return [] }
            return try JSONDecoder().decode([KnowledgeEvidence].self, from: data)
        }
    }
    public func queuedSource(taskID: String) throws -> ConnectedMemoryReference? {
        try database.read { db in
            try Data.fetchOne(db, sql: "SELECT payload FROM queued_source WHERE taskID=?", arguments: [taskID]).map { try JSONDecoder().decode(ConnectedMemoryReference.self, from: $0) }
        }
    }
}
