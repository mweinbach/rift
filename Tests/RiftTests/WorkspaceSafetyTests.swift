import CSQLite
import Darwin
import Foundation
import Rift
import Testing

@Suite("Workspace ownership and inaccessible paths")
struct WorkspaceSafetyTests {
    @Test("Case aliases preserve identity and cannot bypass the recursive-copy guard")
    func caseAliasesCannotCopyIntoSource() async throws {
        let fixture = try RiftFixture()
        let alias = fixture.source.deletingLastPathComponent().appendingPathComponent("APP", isDirectory: true)
        // Case-sensitive volumes have no alias to exercise.
        guard fixture.exists(alias) else { return }
        let manager = try fixture.manager()
        _ = try await manager.initialize(at: fixture.source)
        #expect(try await manager.initialize(at: alias) == .alreadyInitialized)
        #expect(try await manager.workspace(at: alias) == fixture.source)
        let storage = alias.appendingPathComponent("storage", isDirectory: true)
        await expectRiftError(matching: {
            if case .insideSource = $0 { return true }
            return false
        }, performing: {
            try await manager.create(from: fixture.source, name: "recursive", into: storage)
        })
        #expect(!fixture.exists(storage))
        #expect(try fixture.read(fixture.source.appendingPathComponent("file.txt")) == "hello")
    }

    @Test("Custom storage cannot nest a logical sibling inside an active workspace")
    func creationRefusesNestedSibling() async throws {
        let fixture = try RiftFixture()
        let manager = try fixture.manager()
        _ = try await manager.initialize(at: fixture.source)
        let first = try await manager.create(from: fixture.source, name: "first")
        let sibling = first.appendingPathComponent("sibling", isDirectory: true)

        await expectRiftError(matching: {
            if case .overlappingWorkspace(_, let other) = $0 { return other.path == first.path }
            return false
        }, performing: {
            try await manager.create(from: fixture.source, name: "sibling", into: first)
        })

        #expect(!fixture.exists(sibling))
        #expect(try fixture.read(first.appendingPathComponent("file.txt")) == "hello")
        let children = try await manager.list(of: fixture.source)
        #expect(children.map(\.path) == [first.path])
    }

    @Test("Custom storage cannot create a live workspace inside registered trash")
    func creationRefusesTrashStorage() async throws {
        let fixture = try RiftFixture()
        let manager = try fixture.manager()
        _ = try await manager.initialize(at: fixture.source)
        let first = try await manager.create(from: fixture.source, name: "first")
        let trash = try fixture.trash(for: first)
        try await manager.remove(at: first)

        await expectRiftError(matching: {
            if case .overlappingWorkspace(_, let other) = $0 { return other.path == trash.path }
            return false
        }, performing: {
            try await manager.create(from: fixture.source, name: "sibling", into: trash)
        })

        #expect(!fixture.exists(trash.appendingPathComponent("sibling")))
        #expect(try fixture.read(trash.appendingPathComponent("file.txt")) == "hello")
        let children = try await manager.list(of: fixture.source)
        #expect(children.isEmpty)
    }

    @Test("Initialization rejects independent roots beneath existing workspaces", arguments: [false, true])
    func initializationRefusesNestedRoot(existingIsCreated: Bool) async throws {
        let fixture = try RiftFixture()
        let manager = try fixture.manager()
        _ = try await manager.initialize(at: fixture.source)
        let existing = existingIsCreated
            ? try await manager.create(from: fixture.source, name: "first")
            : fixture.source
        let nested = existing.appendingPathComponent("nested", isDirectory: true)
        try fixture.mkdir(nested)
        try fixture.write("preserved", to: nested.appendingPathComponent("data.txt"))
        let originalID = try fixture.marker(existing)

        await expectRiftError(matching: {
            if case .overlappingWorkspace(_, let other) = $0 { return other.path == existing.path }
            return false
        }, performing: { try await manager.initialize(at: nested) })

        #expect(!fixture.exists(nested.appendingPathComponent(".rift")))
        #expect(try fixture.read(nested.appendingPathComponent("data.txt")) == "preserved")
        #expect(try fixture.marker(existing) == originalID)
    }

    @Test("Initialization rejects independent roots containing existing workspaces", arguments: [false, true])
    func initializationRefusesContainingRoot(existingIsCreated: Bool) async throws {
        let fixture = try RiftFixture()
        let manager = try fixture.manager()
        _ = try await manager.initialize(at: fixture.source)
        let existing = existingIsCreated
            ? try await manager.create(from: fixture.source, name: "first")
            : fixture.source
        let parent = existing.deletingLastPathComponent()
        let originalID = try fixture.marker(existing)

        await expectRiftError(matching: {
            if case .overlappingWorkspace(_, let other) = $0 { return other.path == existing.path }
            return false
        }, performing: { try await manager.initialize(at: parent) })

        #expect(!fixture.exists(parent.appendingPathComponent(".rift")))
        #expect(try fixture.marker(existing) == originalID)
        #expect(try fixture.read(existing.appendingPathComponent("file.txt")) == "hello")
    }

    @Test("Legacy physical nesting cannot remove an unrelated registered workspace", arguments: [false, true])
    func removalProtectsLegacyNestedWorkspace(nestedIsRoot: Bool) async throws {
        let fixture = try RiftFixture()
        let manager = try fixture.manager()
        _ = try await manager.initialize(at: fixture.source)
        let first = try await manager.create(from: fixture.source, name: "first")
        let originalNested: URL
        if nestedIsRoot {
            originalNested = fixture.path("independent-source")
            try fixture.mkdir(originalNested)
            try fixture.write("hello", to: originalNested.appendingPathComponent("file.txt"))
            _ = try await manager.initialize(at: originalNested)
        } else {
            originalNested = try await manager.create(from: fixture.source, name: "sibling")
        }
        let nestedID = try fixture.marker(originalNested)
        let nested = first.appendingPathComponent("nested", isDirectory: true)
        try fixture.move(originalNested, to: nested)
        let database = try SafetySQLiteFixture(path: fixture.databaseURL)
        try database.execute("UPDATE rift SET path = \(safetySQLString(nested.path)) WHERE id = \(safetySQLString(nestedID))")
        let firstTrash = try fixture.trash(for: first)

        await expectRiftError(matching: {
            if case .overlappingWorkspace = $0 { return true }
            return false
        }, performing: { try await manager.remove(at: first, options: RemoveOptions(hooks: .skip)) })

        #expect(fixture.exists(first) && fixture.exists(nested))
        #expect(!fixture.exists(firstTrash))
        #expect(try fixture.read(nested.appendingPathComponent("file.txt")) == "hello")
        #expect(try database.scalar("SELECT count(*) FROM rift WHERE id = \(safetySQLString(nestedID))") == "1")
        #expect(try database.scalar("SELECT count(*) FROM trash") == "0")
    }

    @Test("Legacy active workspaces inside trash block permanent collection")
    func collectionProtectsLegacyActiveWorkspaceInsideTrash() async throws {
        let fixture = try RiftFixture()
        let manager = try fixture.manager()
        _ = try await manager.initialize(at: fixture.source)
        let first = try await manager.create(from: fixture.source, name: "first")
        let trash = try fixture.trash(for: first)
        try await manager.remove(at: first)
        let originalNested = fixture.path("independent-source")
        try fixture.mkdir(originalNested)
        try fixture.write("preserved", to: originalNested.appendingPathComponent("data.txt"))
        _ = try await manager.initialize(at: originalNested)
        let nestedID = try fixture.marker(originalNested)
        let nested = trash.appendingPathComponent("independent-source", isDirectory: true)
        try fixture.move(originalNested, to: nested)
        let database = try SafetySQLiteFixture(path: fixture.databaseURL)
        try database.execute("UPDATE rift SET path = \(safetySQLString(nested.path)) WHERE id = \(safetySQLString(nestedID))")

        await expectRiftError(matching: {
            if case .overlappingWorkspace = $0 { return true }
            return false
        }, performing: { try await manager.garbageCollect() })

        #expect(fixture.exists(trash) && fixture.exists(nested))
        #expect(try fixture.read(nested.appendingPathComponent("data.txt")) == "preserved")
        #expect(try database.scalar("SELECT count(*) FROM rift WHERE id = \(safetySQLString(nestedID))") == "1")
        #expect(try database.scalar("SELECT count(*) FROM trash") == "1")
    }

    @Test("Permission errors do not prune existing active workspace records")
    func collectionPreservesInaccessibleWorkspace() async throws {
        let fixture = try RiftFixture()
        let manager = try fixture.manager()
        _ = try await manager.initialize(at: fixture.source)
        let child = try await manager.create(from: fixture.source, name: "child")
        let parent = child.deletingLastPathComponent()
        let originalID = try fixture.marker(child)
        defer { chmod(parent.path, 0o755) }
        #expect(chmod(parent.path, 0) == 0)

        await expectRiftError(matching: {
            if case .io(_, let path, let code) = $0 { return path.path == child.path && code == EACCES }
            return false
        }, performing: { try await manager.garbageCollect() })

        #expect(chmod(parent.path, 0o755) == 0)
        #expect(try fixture.marker(child) == originalID)
        #expect(try fixture.read(child.appendingPathComponent("file.txt")) == "hello")
        let children = try await manager.list(of: fixture.source)
        #expect(children.map(\.path) == [child.path])
        let workspace = try await manager.workspace(at: child)
        #expect(workspace.path == child.path)
    }

    @Test("Root unregistration cannot forget inaccessible descendants")
    func unregisterPreservesInaccessibleDescendants() async throws {
        let fixture = try RiftFixture()
        let manager = try fixture.manager()
        _ = try await manager.initialize(at: fixture.source)
        let child = try await manager.create(from: fixture.source, name: "child")
        let parent = child.deletingLastPathComponent()
        let rootID = try fixture.marker(fixture.source)
        let childID = try fixture.marker(child)
        defer { chmod(parent.path, 0o755) }
        #expect(chmod(parent.path, 0) == 0)

        await expectRiftError(matching: {
            if case .io(_, let path, let code) = $0 { return path.path == child.path && code == EACCES }
            return false
        }, performing: { try await manager.remove(at: fixture.source, options: RemoveOptions(hooks: .skip)) })

        #expect(chmod(parent.path, 0o755) == 0)
        #expect(try fixture.marker(fixture.source) == rootID)
        #expect(try fixture.marker(child) == childID)
        #expect(try fixture.read(child.appendingPathComponent("file.txt")) == "hello")
        let children = try await manager.list(of: fixture.source)
        #expect(children.map(\.path) == [child.path])
    }

    @Test("A failed root registry deletion restores markers, child paths, and ancestry")
    func unregisterRollsBackAfterRegistryFailure() async throws {
        let fixture = try RiftFixture()
        let manager = try fixture.manager()
        _ = try await manager.initialize(at: fixture.source)
        let child = try await manager.create(from: fixture.source, name: "child")
        let grandchild = try await manager.create(from: child, name: "grandchild")
        let rootID = try fixture.marker(fixture.source)
        let childID = try fixture.marker(child)
        let grandchildID = try fixture.marker(grandchild)
        let childTrash = try fixture.trash(for: child)
        let grandchildTrash = try fixture.trash(for: grandchild)
        let database = try SafetySQLiteFixture(path: fixture.databaseURL)
        try database.execute("""
            CREATE TRIGGER abort_root_unregistration BEFORE DELETE ON rift
            WHEN OLD.id = \(safetySQLString(rootID))
            BEGIN SELECT RAISE(ABORT, 'injected root deletion failure'); END;
            """)

        await expectRiftError(matching: {
            if case .database = $0 { return true }
            return false
        }, performing: { try await manager.remove(at: fixture.source, options: RemoveOptions(hooks: .skip)) })

        #expect(try fixture.marker(fixture.source) == rootID)
        #expect(try fixture.marker(child) == childID)
        #expect(try fixture.marker(grandchild) == grandchildID)
        #expect(!fixture.exists(childTrash) && !fixture.exists(grandchildTrash))
        #expect(try fixture.read(child.appendingPathComponent("file.txt")) == "hello")
        #expect(try fixture.read(grandchild.appendingPathComponent("file.txt")) == "hello")
        #expect(try database.scalar("SELECT count(*) FROM rift") == "3")
        #expect(try database.scalar("SELECT count(*) FROM trash") == "0")
        let children = try await manager.list(of: fixture.source)
        let ancestors = try await manager.ancestors(of: grandchild)
        #expect(children.map(\.path) == [child.path])
        #expect(ancestors.map(\.path) == [child.path, fixture.source.path])

        try database.execute("DROP TRIGGER abort_root_unregistration")
        try await manager.remove(at: fixture.source, options: RemoveOptions(hooks: .skip))
        #expect(!fixture.exists(fixture.source.appendingPathComponent(".rift")))
        #expect(!fixture.exists(child) && !fixture.exists(grandchild))
        #expect(fixture.exists(childTrash) && fixture.exists(grandchildTrash))
        #expect(try database.scalar("SELECT count(*) FROM rift") == "0")
        #expect(try database.scalar("SELECT count(*) FROM trash") == "2")
    }
}

private func safetySQLString(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
}

private final class SafetySQLiteFixture {
    private let database: OpaquePointer

    init(path: URL) throws {
        var database: OpaquePointer?
        let result = sqlite3_open(path.path, &database)
        guard result == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw RiftError.database("Failed to open SQLite safety fixture")
        }
        self.database = database
    }

    deinit { sqlite3_close(database) }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
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
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else {
            throw RiftError.database("SQLite safety fixture query returned no value")
        }
        return String(cString: value)
    }
}
