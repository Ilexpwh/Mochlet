import Foundation
import SQLite3

public enum SQLValue: Sendable, Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    public var string: String? { if case .text(let s) = self { return s } else { return nil } }
    public var int: Int? {
        switch self {
        case .int(let i): return Int(i)
        case .double(let d): return Int(d)
        default: return nil
        }
    }
    public var double: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }
    public var data: Data? { if case .blob(let d) = self { return d } else { return nil } }
    public var blob: Data? { data }

    public static func integer(_ i: Int) -> SQLValue { .int(Int64(i)) }
    public static func real(_ d: Double) -> SQLValue { .double(d) }
}

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "sqlite \(code): \(message)" }
}

/// A small, serialised wrapper over the system SQLite (FTS5 and JSON1 are compiled in on macOS).
public final class SQLiteDB: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    public let path: String

    public init(path: String) throws {
        self.path = path
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            if let handle { sqlite3_close(handle) }
            throw SQLiteError(code: rc, message: msg)
        }
        db = handle
        sqlite3_busy_timeout(handle, 3000)
        try exec("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA synchronous=NORMAL;")
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    public static func inMemory() throws -> SQLiteDB { try SQLiteDB(path: ":memory:") }

    public func exec(_ sql: String) throws {
        try lock.withLock {
            var err: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_exec(db, sql, nil, nil, &err)
            if rc != SQLITE_OK {
                let msg = err.map { String(cString: $0) } ?? "exec failed"
                sqlite3_free(err)
                throw SQLiteError(code: rc, message: msg)
            }
        }
    }

    @discardableResult
    public func run(_ sql: String, _ params: [SQLValue] = []) throws -> Int {
        try lock.withLock {
            let stmt = try prepare(sql, params)
            defer { sqlite3_finalize(stmt) }
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(db))) }
            return Int(sqlite3_changes(db))
        }
    }

    public func query(_ sql: String, _ params: [SQLValue] = []) throws -> [[String: SQLValue]] {
        try lock.withLock {
            let stmt = try prepare(sql, params)
            defer { sqlite3_finalize(stmt) }
            var rows: [[String: SQLValue]] = []
            let n = sqlite3_column_count(stmt)
            let names = (0..<n).map { String(cString: sqlite3_column_name(stmt, $0)) }
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(db))) }
                var row: [String: SQLValue] = [:]
                for i in 0..<n {
                    switch sqlite3_column_type(stmt, i) {
                    case SQLITE_INTEGER: row[names[Int(i)]] = .int(sqlite3_column_int64(stmt, i))
                    case SQLITE_FLOAT: row[names[Int(i)]] = .double(sqlite3_column_double(stmt, i))
                    case SQLITE_TEXT: row[names[Int(i)]] = .text(String(cString: sqlite3_column_text(stmt, i)))
                    case SQLITE_BLOB:
                        let bytes = sqlite3_column_bytes(stmt, i)
                        row[names[Int(i)]] = .blob(bytes > 0 ? Data(bytes: sqlite3_column_blob(stmt, i), count: Int(bytes)) : Data())
                    default: row[names[Int(i)]] = .null
                    }
                }
                rows.append(row)
            }
            return rows
        }
    }

    public var lastInsertRowID: Int64 { lock.withLock { sqlite3_last_insert_rowid(db) } }

    public var userVersion: Int {
        get { (try? query("PRAGMA user_version"))?.first?["user_version"]?.int ?? 0 }
    }

    /// Applies migration steps whose index ≥ user_version, each in a transaction.
    public func migrate(_ steps: [String]) throws {
        let current = userVersion
        guard current < steps.count else { return }
        for (i, sql) in steps.enumerated() where i >= current {
            try exec("BEGIN; \(sql); PRAGMA user_version = \(i + 1); COMMIT;")
        }
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN")
        do {
            let v = try body()
            try exec("COMMIT")
            return v
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, _ params: [SQLValue]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(db))) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .null: sqlite3_bind_null(stmt, idx)
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, transient)
            case .blob(let d): d.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(d.count), transient) }
            }
        }
        return stmt
    }
}
