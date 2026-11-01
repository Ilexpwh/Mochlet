import Foundation
import CryptoKit
import Darwin
import GRDB

public struct FileMove: Codable, Sendable, Identifiable {
    public let id: String
    public let source: String
    public let destination: String
    public let fingerprint: String
    public let createdAt: Date
    public var state: String
    public var message: String?
}

/// Reviewed regular-file moves. Never overwrites; cross-volume moves fail closed.
public actor FileOrganizer {
    private let database: DatabaseQueue
    public init(folder: URL) throws {
        database = try DatabaseQueue(path: folder.appendingPathComponent("file-operations.sqlite").path)
        var migration = DatabaseMigrator()
        migration.registerMigration("file_moves") { db in
            try db.execute(sql: "CREATE TABLE file_moves(id TEXT PRIMARY KEY,payload BLOB NOT NULL,createdAt DOUBLE NOT NULL)")
        }
        try migration.migrate(database)
    }
    public func history(limit: Int = 50, offset: Int = 0) throws -> [FileMove] {
        try database.read { db in try Data.fetchAll(db, sql: "SELECT payload FROM file_moves ORDER BY createdAt DESC,id DESC LIMIT ? OFFSET ?", arguments: [max(1, min(200, limit)), max(0, offset)]).map { try JSONDecoder().decode(FileMove.self, from: $0) } }
    }
    private func save(_ move: FileMove) throws {
        try database.write { db in
            try db.execute(sql: "INSERT INTO file_moves(id,payload,createdAt) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", arguments: [move.id, try JSONEncoder().encode(move), move.createdAt.timeIntervalSince1970])
        }
    }
    private func fingerprint(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: path)
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? NSNumber, size.int64Value <= 100_000_000,
              url.resolvingSymlinksInPath().path == url.standardizedFileURL.path else {
            throw MochletError.message("Moves support regular files up to 100 MB without symbolic-link paths.")
        }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256(); var read = 0
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation(); read += bytes.count
            guard read <= 100_000_000 else { throw MochletError.message("File grew beyond the move limit.") }
            hash.update(data: bytes)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        return "\(attrs[.systemNumber] ?? ""):\(attrs[.systemFileNumber] ?? ""):\(read):\(digest)"
    }
    private func exists(_ path: String) -> Bool {
        // attributesOfItem sees dangling symlinks, unlike fileExists.
        (try? FileManager.default.attributesOfItem(atPath: path)) != nil
    }
    public func preview(paths: [String], destination: URL) throws -> [FileMove] {
        guard !paths.isEmpty, paths.count <= 100 else { throw MochletError.message("Select between one and 100 files.") }
        let destination = destination.resolvingSymlinksInPath().standardizedFileURL
        let resource = try destination.resourceValues(forKeys: [.isDirectoryKey])
        guard resource.isDirectory == true else { throw MochletError.message("Choose an existing destination folder.") }
        var moves: [FileMove] = []; var destinations = Set<String>()
        for path in paths {
            let input = URL(fileURLWithPath: path).standardizedFileURL
            let source = input.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(input.lastPathComponent)
            let target = destination.appendingPathComponent(source.lastPathComponent).path
            guard source.path != target, !exists(target), destinations.insert(target).inserted else {
                throw MochletError.message("Destination already exists or two files have the same name: \(source.lastPathComponent). Nothing was moved.")
            }
            moves.append(FileMove(id: UUID().uuidString, source: source.path, destination: target,
                fingerprint: try fingerprint(source.path), createdAt: Date(), state: "planned"))
        }
        for move in moves { try save(move) }
        return moves
    }
    public func apply(id: String, undo: Bool = false) throws -> FileMove {
        guard let data = try database.read({ try Data.fetchOne($0, sql: "SELECT payload FROM file_moves WHERE id=?", arguments: [id]) }) else {
            throw MochletError.message("Move plan is missing.")
        }
        var move = try JSONDecoder().decode(FileMove.self, from: data)
        guard move.state == (undo ? "applied" : "planned") else { throw MochletError.message("This operation cannot be repeated in its current state.") }
        let from = undo ? move.destination : move.source; let to = undo ? move.source : move.destination
        guard try fingerprint(from) == move.fingerprint else { throw MochletError.message("File changed since review. Nothing was moved.") }
        let parent = URL(fileURLWithPath: to).deletingLastPathComponent()
        guard parent.resolvingSymlinksInPath().path == parent.path, !exists(to) else {
            throw MochletError.message("Destination changed or already exists. Nothing was overwritten.")
        }
        move.state = undo ? "undoing" : "applying"; move.message = nil; try save(move)
        let result = renamex_np(from, to, UInt32(RENAME_EXCL))
        if result != 0 {
            let failure = errno
            move.state = undo ? "applied" : "failed"
            move.message = failure == EXDEV ? "Cross-volume moves are not supported. Use Finder to copy and review these files." : "Move failed (system error \(failure)); no destination was overwritten."
            try save(move); throw MochletError.message(move.message!)
        }
        move.state = undo ? "undone" : "applied"
        do { try save(move) }
        catch { throw MochletError.message("The file moved, but the history update failed. Reopen File operations to reconcile its location before retrying.") }
        return move
    }
    public func reconcile() throws {
        // A crash after rename but before the journal update must not repeat a move.
        let pending = try database.read { db in try Data.fetchAll(db, sql: "SELECT payload FROM file_moves").map { try JSONDecoder().decode(FileMove.self, from: $0) }.filter { ["applying", "undoing"].contains($0.state) } }
        for var move in pending {
            let sourceMatches = (try? fingerprint(move.source)) == move.fingerprint
            let targetMatches = (try? fingerprint(move.destination)) == move.fingerprint
            if targetMatches && !exists(move.source) { move.state = "applied" }
            else if sourceMatches && !exists(move.destination) { move.state = move.state == "undoing" ? "undone" : "planned" }
            else { move.state = "uncertain"; move.message = "Both paths changed or neither contains the reviewed file. Inspect in Finder; no automatic action was taken." }
            try save(move)
        }
    }
}
