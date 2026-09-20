import CSQLite
import Foundation

struct Record: Equatable, Sendable {
    let id: String
    let parentID: String?
    let path: URL
    let createdAt: Int64
}

struct PathRecord: Equatable, Sendable {
    let id: String
    let path: URL
}

struct MovedRecord: Equatable, Sendable {
    let id: String
    let originalPath: URL
    let trashPath: URL
}

enum SubtreeScope: Sendable {
    case includingRoot
    case descendantsOnly

    fileprivate var minimumDepth: Int64 {
        switch self {
        case .includingRoot: 0
        case .descendantsOnly: 1
        }
    }
}

/// The schema and timestamps match Rift's Rust registry, so existing databases
/// can be opened directly. The lock covers complete transactions as well as
/// individual statements, preventing concurrent calls from joining a transaction.
final class Registry: @unchecked Sendable {
    private let database: OpaquePointer
    private let lock = NSLock()

    init(path: URL) throws {
        var connection: OpaquePointer?
        let result = sqlite3_open_v2(
            path.path,
            &connection,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let connection else {
            let error = Self.error(database: connection, code: result)
            if let connection { sqlite3_close_v2(connection) }
            throw error
        }
        do {
            try Self.executeBatch(
                database: connection,
                sql: """
                PRAGMA busy_timeout = 2000;
                PRAGMA journal_mode = WAL;
                PRAGMA foreign_keys = ON;
                CREATE TABLE IF NOT EXISTS rift (
                  id TEXT PRIMARY KEY,
                  parent_id TEXT REFERENCES rift(id) ON DELETE CASCADE,
                  path TEXT NOT NULL UNIQUE,
                  created_at INTEGER NOT NULL
                );
                CREATE INDEX IF NOT EXISTS rift_parent_id_idx ON rift(parent_id);
                CREATE TABLE IF NOT EXISTS trash (
                  id TEXT PRIMARY KEY,
                  path TEXT NOT NULL UNIQUE,
                  removed_at INTEGER NOT NULL
                );
                """
            )
        } catch {
            sqlite3_close_v2(connection)
            throw error
        }
        database = connection
    }

    deinit {
        sqlite3_close_v2(database)
    }

    func record(at path: URL) throws -> Record? {
        try withDatabase {
            try records(
                sql: "SELECT id, parent_id, path, created_at FROM rift WHERE path = ?1",
                values: [.text(path.path)]
            ).first
        }
    }

    func record(id: String) throws -> Record? {
        try withDatabase {
            try records(
                sql: "SELECT id, parent_id, path, created_at FROM rift WHERE id = ?1",
                values: [.text(id)]
            ).first
        }
    }

    func insertRoot(id: String, path: URL) throws {
        try withDatabase {
            try execute(
                "INSERT INTO rift (id, parent_id, path, created_at) VALUES (?1, NULL, ?2, ?3)",
                values: [.text(id), .text(path.path), .integer(Self.timestamp())]
            )
        }
    }

    func insertChild(id: String, parentID: String, path: URL) throws {
        try withDatabase {
            try execute(
                "INSERT INTO rift (id, parent_id, path, created_at) VALUES (?1, ?2, ?3, ?4)",
                values: [.text(id), .text(parentID), .text(path.path), .integer(Self.timestamp())]
            )
        }
    }

    func childPaths(parentID: String) throws -> [URL] {
        try withDatabase {
            try query(
                "SELECT path FROM rift WHERE parent_id = ?1 ORDER BY created_at, id",
                values: [.text(parentID)]
            ) { statement in
                URL(fileURLWithPath: try text(statement, column: 0), isDirectory: true)
            }
        }
    }

    func subtree(id: String, scope: SubtreeScope) throws -> [PathRecord] {
        try withDatabase {
            try query(
                """
                WITH RECURSIVE subtree(id, path, depth, trail, cycle) AS (
                  SELECT id, path, 0, ',' || hex(id) || ',', 0 FROM rift WHERE id = ?1
                  UNION ALL
                  SELECT rift.id, rift.path, subtree.depth + 1,
                    subtree.trail || hex(rift.id) || ',',
                    instr(subtree.trail, ',' || hex(rift.id) || ',') > 0
                  FROM rift JOIN subtree ON rift.parent_id = subtree.id
                  WHERE subtree.cycle = 0
                ) SELECT id, path, cycle FROM subtree WHERE depth >= ?2 ORDER BY depth DESC, id
                """,
                values: [.text(id), .integer(scope.minimumDepth)],
                row: { statement in
                    guard sqlite3_column_int(statement, 2) == 0 else {
                        throw RiftError.database("Cycle detected in workspace ancestry")
                    }
                    return try self.pathRecord(statement)
                }
            )
        }
    }

    func trashMoved(_ moved: [MovedRecord], unregisteringID: String? = nil) throws {
        try withDatabase {
            try transaction {
                for record in moved {
                    try execute(
                        "INSERT INTO trash (id, path, removed_at) VALUES (?1, ?2, ?3)",
                        values: [.text(record.id), .text(record.trashPath.path), .integer(Self.timestamp())]
                    )
                    try execute("DELETE FROM rift WHERE id = ?1", values: [.text(record.id)])
                }
                if let unregisteringID {
                    try execute("DELETE FROM rift WHERE id = ?1", values: [.text(unregisteringID)])
                }
            }
        }
    }

    func deleteActive(id: String) throws {
        try withDatabase {
            try execute("DELETE FROM rift WHERE id = ?1", values: [.text(id)])
        }
    }

    func trashedPaths() throws -> [PathRecord] {
        try withDatabase {
            try query("SELECT id, path FROM trash ORDER BY removed_at, id", row: pathRecord)
        }
    }

    func activePaths() throws -> [PathRecord] {
        try withDatabase {
            try query("SELECT id, path FROM rift", row: pathRecord)
        }
    }

    func deleteTrash(id: String) throws {
        try withDatabase {
            try execute("DELETE FROM trash WHERE id = ?1", values: [.text(id)])
        }
    }

    func deleteActiveRecords(_ rows: [PathRecord]) throws {
        try withDatabase {
            try transaction {
                for record in rows {
                    try execute("DELETE FROM rift WHERE id = ?1", values: [.text(record.id)])
                }
            }
        }
    }

    private func withDatabase<Value>(_ body: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN TRANSACTION")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private enum SQLValue {
        case text(String)
        case integer(Int64)
    }

    private func withStatement<Value>(
        _ sql: String,
        values: [SQLValue],
        body: (OpaquePointer) throws -> Value
    ) throws -> Value {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw Self.error(database: database, code: result)
        }
        defer { sqlite3_finalize(statement) }

        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let text):
                guard text.utf8.count <= Int(Int32.max) else {
                    throw RiftError.database("SQLite text value exceeds its supported length")
                }
                result = text.withCString { bytes in
                    sqlite3_bind_text(
                        statement,
                        index,
                        bytes,
                        Int32(text.utf8.count),
                        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                    )
                }
            case .integer(let integer):
                result = sqlite3_bind_int64(statement, index, integer)
            }
            guard result == SQLITE_OK else {
                throw Self.error(database: database, code: result)
            }
        }
        return try body(statement)
    }

    private func execute(_ sql: String, values: [SQLValue] = []) throws {
        try withStatement(sql, values: values) { statement in
            let result = sqlite3_step(statement)
            guard result == SQLITE_DONE else {
                throw Self.error(database: database, code: result)
            }
        }
    }

    private func query<Value>(
        _ sql: String,
        values: [SQLValue] = [],
        row: (OpaquePointer) throws -> Value
    ) throws -> [Value] {
        try withStatement(sql, values: values) { statement in
            var rows: [Value] = []
            while true {
                let result = sqlite3_step(statement)
                switch result {
                case SQLITE_ROW: rows.append(try row(statement))
                case SQLITE_DONE: return rows
                default: throw Self.error(database: database, code: result)
                }
            }
        }
    }

    private func records(sql: String, values: [SQLValue]) throws -> [Record] {
        try query(sql, values: values) { statement in
            Record(
                id: try text(statement, column: 0),
                parentID: sqlite3_column_type(statement, 1) == SQLITE_NULL ? nil : try text(statement, column: 1),
                path: URL(fileURLWithPath: try text(statement, column: 2), isDirectory: true),
                createdAt: sqlite3_column_int64(statement, 3)
            )
        }
    }

    private func pathRecord(_ statement: OpaquePointer) throws -> PathRecord {
        PathRecord(
            id: try text(statement, column: 0),
            path: URL(fileURLWithPath: try text(statement, column: 1), isDirectory: true)
        )
    }

    private func text(_ statement: OpaquePointer, column: Int32) throws -> String {
        guard let bytes = sqlite3_column_text(statement, column) else {
            throw RiftError.database("Registry contains a null text value at column \(column)")
        }
        let length = Int(sqlite3_column_bytes(statement, column))
        guard let value = String(bytes: UnsafeBufferPointer(start: bytes, count: length), encoding: .utf8) else {
            throw RiftError.database("Registry contains invalid UTF-8 at column \(column)")
        }
        return value
    }

    private static func executeBatch(database: OpaquePointer, sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        defer { sqlite3_free(message) }
        guard result == SQLITE_OK else {
            if let message {
                throw RiftError.database(String(cString: message))
            }
            throw error(database: database, code: result)
        }
    }

    private static func error(database: OpaquePointer?, code: Int32) -> RiftError {
        let message = database.map { String(cString: sqlite3_errmsg($0)) }
            ?? String(cString: sqlite3_errstr(code))
        return .database(message)
    }

    private static func timestamp() -> Int64 {
        Int64(max(0, Date().timeIntervalSince1970 * 1_000))
    }
}
