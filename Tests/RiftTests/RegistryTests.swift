import CSQLite
import Foundation
import XCTest
@testable import Rift

final class RegistryTests: XCTestCase {
    func testOpensExistingRustSchemaWithoutChangingItsData() throws {
        try withTemporaryDirectory { directory in
            let databaseURL = directory.appendingPathComponent("registry.sqlite")
            let root = directory.appendingPathComponent("root", isDirectory: true)
            let child = directory.appendingPathComponent("child's workspace", isDirectory: true)
            let trashed = directory.appendingPathComponent(".trash/old-child", isDirectory: true)
            let fixture = try SQLiteFixture(path: databaseURL)
            try fixture.execute("""
                PRAGMA foreign_keys = ON;
                CREATE TABLE rift (
                  id TEXT PRIMARY KEY,
                  parent_id TEXT REFERENCES rift(id) ON DELETE CASCADE,
                  path TEXT NOT NULL UNIQUE,
                  created_at INTEGER NOT NULL
                );
                CREATE INDEX rift_parent_id_idx ON rift(parent_id);
                CREATE TABLE trash (
                  id TEXT PRIMARY KEY,
                  path TEXT NOT NULL UNIQUE,
                  removed_at INTEGER NOT NULL
                );
                INSERT INTO rift VALUES ('root', NULL, \(sqlString(root.path)), 123);
                INSERT INTO rift VALUES ('child', 'root', \(sqlString(child.path)), 456);
                INSERT INTO trash VALUES ('old-child', \(sqlString(trashed.path)), 789);
                """)

            let registry = try Registry(path: databaseURL)
            XCTAssertEqual(
                try registry.record(id: "root"),
                Record(id: "root", parentID: nil, path: root, createdAt: 123)
            )
            XCTAssertEqual(
                try registry.record(at: child),
                Record(id: "child", parentID: "root", path: child, createdAt: 456)
            )
            XCTAssertEqual(try registry.childPaths(parentID: "root"), [child])
            XCTAssertEqual(try registry.trashedPaths(), [PathRecord(id: "old-child", path: trashed)])

            let swiftChild = directory.appendingPathComponent("swift-child", isDirectory: true)
            try registry.insertChild(id: "swift-child", parentID: "root", path: swiftChild)
            XCTAssertEqual(try fixture.scalar("SELECT parent_id FROM rift WHERE id = 'swift-child'"), "root")
            XCTAssertEqual(try fixture.scalar("SELECT path FROM rift WHERE id = 'swift-child'"), swiftChild.path)
            let timestamp = try XCTUnwrap(Int64(fixture.scalar("SELECT created_at FROM rift WHERE id = 'swift-child'")))
            XCTAssertGreaterThan(timestamp, 1_000_000_000_000)
            XCTAssertEqual(try fixture.scalar("PRAGMA journal_mode"), "wal")
        }
    }

    func testCreatesCompatibleSchemaAndEnforcesConstraints() throws {
        try withTemporaryDirectory { directory in
            let databaseURL = directory.appendingPathComponent("registry.sqlite")
            let registry = try Registry(path: databaseURL)
            let fixture = try SQLiteFixture(path: databaseURL)
            XCTAssertEqual(try fixture.scalar("PRAGMA journal_mode"), "wal")
            XCTAssertEqual(
                try fixture.scalar("SELECT group_concat(name, ',') FROM pragma_table_info('rift')"),
                "id,parent_id,path,created_at"
            )
            XCTAssertEqual(
                try fixture.scalar("SELECT group_concat(name, ',') FROM pragma_table_info('trash')"),
                "id,path,removed_at"
            )
            XCTAssertEqual(
                try fixture.scalar("SELECT count(*) FROM sqlite_master WHERE type = 'index' AND name = 'rift_parent_id_idx'"),
                "1"
            )

            let root = directory.appendingPathComponent("root", isDirectory: true)
            try registry.insertRoot(id: "root", path: root)
            XCTAssertThrowsError(
                try registry.insertChild(id: "orphan", parentID: "missing", path: directory.appendingPathComponent("orphan", isDirectory: true))
            )
            XCTAssertThrowsError(try registry.insertRoot(id: "duplicate-path", path: root))
            XCTAssertThrowsError(try registry.insertRoot(id: "root", path: directory.appendingPathComponent("duplicate-id", isDirectory: true)))
            XCTAssertEqual(try registry.activePaths(), [PathRecord(id: "root", path: root)])
            XCTAssertNil(try registry.record(id: "missing"))
            XCTAssertNil(try registry.record(at: directory.appendingPathComponent("missing", isDirectory: true)))
        }
    }

    func testRecursiveSubtreeIsDeepestFirstWithStableIDOrder() throws {
        try withTemporaryDirectory { directory in
            let registry = try Registry(path: directory.appendingPathComponent("registry.sqlite"))
            let root = directory.appendingPathComponent("root", isDirectory: true)
            let child = directory.appendingPathComponent("child", isDirectory: true)
            let sibling = directory.appendingPathComponent("sibling", isDirectory: true)
            let grandchild = directory.appendingPathComponent("grandchild", isDirectory: true)
            try registry.insertRoot(id: "root", path: root)
            try registry.insertChild(id: "child", parentID: "root", path: child)
            try registry.insertChild(id: "sibling", parentID: "root", path: sibling)
            try registry.insertChild(id: "grandchild", parentID: "child", path: grandchild)

            XCTAssertEqual(
                try registry.subtree(id: "root", scope: .includingRoot).map(\.id),
                ["grandchild", "child", "sibling", "root"]
            )
            XCTAssertEqual(
                try registry.subtree(id: "root", scope: .descendantsOnly).map(\.id),
                ["grandchild", "child", "sibling"]
            )
            XCTAssertEqual(try registry.childPaths(parentID: "root"), [child, sibling])
            XCTAssertTrue(try registry.subtree(id: "missing", scope: .includingRoot).isEmpty)
            XCTAssertTrue(try registry.subtree(id: "grandchild", scope: .descendantsOnly).isEmpty)
        }
    }

    func testDeletingRootCascadesOnlyItsOwnDescendants() throws {
        try withTemporaryDirectory { directory in
            let registry = try Registry(path: directory.appendingPathComponent("registry.sqlite"))
            try registry.insertRoot(id: "root", path: directory.appendingPathComponent("root", isDirectory: true))
            try registry.insertChild(id: "child", parentID: "root", path: directory.appendingPathComponent("child", isDirectory: true))
            try registry.insertChild(id: "grandchild", parentID: "child", path: directory.appendingPathComponent("grandchild", isDirectory: true))
            let unrelated = directory.appendingPathComponent("unrelated", isDirectory: true)
            try registry.insertRoot(id: "unrelated", path: unrelated)

            try registry.deleteActive(id: "root")
            XCTAssertEqual(try registry.activePaths(), [PathRecord(id: "unrelated", path: unrelated)])
        }
    }

    func testTrashTransactionRollsBackEveryMoveOnConstraintFailure() throws {
        try withTemporaryDirectory { directory in
            let registry = try Registry(path: directory.appendingPathComponent("registry.sqlite"))
            let root = directory.appendingPathComponent("root", isDirectory: true)
            let first = directory.appendingPathComponent("first", isDirectory: true)
            let second = directory.appendingPathComponent("second", isDirectory: true)
            let sharedTrashPath = directory.appendingPathComponent(".trash/shared", isDirectory: true)
            try registry.insertRoot(id: "root", path: root)
            try registry.insertChild(id: "first", parentID: "root", path: first)
            try registry.insertChild(id: "second", parentID: "root", path: second)

            XCTAssertThrowsError(try registry.trashMoved([
                MovedRecord(id: "first", originalPath: first, trashPath: sharedTrashPath),
                MovedRecord(id: "second", originalPath: second, trashPath: sharedTrashPath),
            ]))
            XCTAssertEqual(Set(try registry.activePaths().map(\.id)), Set(["root", "first", "second"]))
            XCTAssertTrue(try registry.trashedPaths().isEmpty)

            let secondTrashPath = directory.appendingPathComponent(".trash/second", isDirectory: true)
            try registry.trashMoved([
                MovedRecord(id: "first", originalPath: first, trashPath: sharedTrashPath),
                MovedRecord(id: "second", originalPath: second, trashPath: secondTrashPath),
            ])
            XCTAssertEqual(try registry.activePaths(), [PathRecord(id: "root", path: root)])
            XCTAssertEqual(try registry.trashedPaths(), [
                PathRecord(id: "first", path: sharedTrashPath),
                PathRecord(id: "second", path: secondTrashPath),
            ])
            try registry.deleteTrash(id: "first")
            XCTAssertEqual(try registry.trashedPaths(), [PathRecord(id: "second", path: secondTrashPath)])
        }
    }

    func testBulkActiveDeletionRollsBackIfAnyDeleteFails() throws {
        try withTemporaryDirectory { directory in
            let databaseURL = directory.appendingPathComponent("registry.sqlite")
            let registry = try Registry(path: databaseURL)
            let first = PathRecord(id: "first", path: directory.appendingPathComponent("first", isDirectory: true))
            let blocked = PathRecord(id: "blocked", path: directory.appendingPathComponent("blocked", isDirectory: true))
            try registry.insertRoot(id: first.id, path: first.path)
            try registry.insertRoot(id: blocked.id, path: blocked.path)
            let fixture = try SQLiteFixture(path: databaseURL)
            try fixture.execute("""
                CREATE TRIGGER refuse_delete BEFORE DELETE ON rift
                WHEN OLD.id = 'blocked'
                BEGIN SELECT RAISE(ABORT, 'blocked'); END;
                """)

            XCTAssertThrowsError(try registry.deleteActiveRecords([first, blocked]))
            XCTAssertEqual(Set(try registry.activePaths().map(\.id)), Set(["first", "blocked"]))
            try fixture.execute("DROP TRIGGER refuse_delete")
            try registry.deleteActiveRecords([first, blocked])
            XCTAssertTrue(try registry.activePaths().isEmpty)
        }
    }

    func testConcurrentTransactionsUseOneSerializedConnection() throws {
        try withTemporaryDirectory { directory in
            let registry = try Registry(path: directory.appendingPathComponent("registry.sqlite"))
            let errors = ConcurrentErrors()
            DispatchQueue.concurrentPerform(iterations: 40) { index in
                do {
                    let id = "workspace-\(index)"
                    let path = directory.appendingPathComponent(id, isDirectory: true)
                    let trash = directory.appendingPathComponent(".trash/\(id)", isDirectory: true)
                    try registry.insertRoot(id: id, path: path)
                    try registry.trashMoved([MovedRecord(id: id, originalPath: path, trashPath: trash)])
                } catch {
                    errors.append(String(describing: error))
                }
            }

            XCTAssertEqual(errors.snapshot(), [])
            XCTAssertTrue(try registry.activePaths().isEmpty)
            XCTAssertEqual(try registry.trashedPaths().count, 40)
        }
    }
}

private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rift-registry-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

private func sqlString(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
}

private final class SQLiteFixture {
    private let database: OpaquePointer

    init(path: URL) throws {
        var database: OpaquePointer?
        let result = sqlite3_open(path.path, &database)
        guard result == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw RiftError.database("Failed to open SQLite test fixture")
        }
        self.database = database
    }

    deinit { sqlite3_close(database) }

    func execute(_ sql: String) throws {
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw RiftError.database(String(cString: sqlite3_errmsg(database)))
        }
    }

    func scalar(_ sql: String) throws -> String {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw RiftError.database(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else {
            throw RiftError.database("SQLite fixture query returned no value")
        }
        return String(cString: text)
    }
}

private final class ConcurrentErrors: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [String] = []

    func append(_ error: String) {
        lock.lock()
        defer { lock.unlock() }
        errors.append(error)
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return errors
    }
}
