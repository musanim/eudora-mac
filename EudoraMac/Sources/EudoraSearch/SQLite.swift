import Foundation
import SQLite3

/// SQLite tells bound text to be copied (not referenced) with this sentinel.
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum SQLiteError: Error, CustomStringConvertible {
    case open(String)
    case prepare(String)
    case step(String)

    public var description: String {
        switch self {
        case .open(let m):    return "sqlite open: \(m)"
        case .prepare(let m): return "sqlite prepare: \(m)"
        case .step(let m):    return "sqlite step: \(m)"
        }
    }
}

/// Thin wrapper over the C SQLite API. No dependencies — uses the system
/// sqlite3 that ships with macOS (FTS5 included).
final class SQLiteDB {
    private var handle: OpaquePointer?

    init(path: String) throws {
        if sqlite3_open(path, &handle) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(handle))
            throw SQLiteError.open(msg)
        }
        // If another connection briefly holds a write lock (e.g. an overlapping
        // reindex of the same file), wait up to 5s rather than fail immediately.
        sqlite3_busy_timeout(handle, 5000)
    }

    deinit { sqlite3_close(handle) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(err)
            throw SQLiteError.step(msg)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(handle))
            throw SQLiteError.prepare(msg)
        }
        return Statement(stmt: stmt)
    }
}

/// A prepared statement. Bind (1-based), then `execute()` for writes or
/// `step()` in a loop for reads. `reset()` to reuse.
final class Statement {
    private let stmt: OpaquePointer?
    init(stmt: OpaquePointer?) { self.stmt = stmt }
    deinit { sqlite3_finalize(stmt) }

    func bind(_ index: Int32, _ text: String) {
        sqlite3_bind_text(stmt, index, text, -1, SQLITE_TRANSIENT)
    }
    func bind(_ index: Int32, _ value: Int) {
        sqlite3_bind_int64(stmt, index, Int64(value))
    }

    /// Advance for a write; throws on a real error.
    func execute() throws {
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE && rc != SQLITE_ROW {
            throw SQLiteError.step("rc=\(rc)")
        }
    }

    /// Advance for a read; true while a row is available.
    func step() -> Bool { sqlite3_step(stmt) == SQLITE_ROW }

    func reset() {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
    }

    func text(_ column: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, column) else { return "" }
        return String(cString: c)
    }
    func int(_ column: Int32) -> Int {
        Int(sqlite3_column_int64(stmt, column))
    }
}
