import Darwin
import Foundation
import Testing
@testable import Rift

@Suite("Protected workspace garbage collection")
struct GarbageCollectionTests {
    @Test(arguments: [CopyMode.filtered, .all])
    func collectionDeletesClonesWithReadOnlyDirectoriesAndImmutableFiles(mode: CopyMode) async throws {
        let fixture = try RiftFixture()
        let locked = fixture.source.appendingPathComponent("locked")
        let original = locked.appendingPathComponent("immutable")
        try fixture.write("protected", to: original)
        try setMode(locked, 0o555)
        try setFlags(original, UInt32(UF_IMMUTABLE))
        defer {
            _ = original.withUnsafeFileSystemRepresentation { lchflags($0!, 0) }
            _ = locked.withUnsafeFileSystemRepresentation { chmod($0!, 0o700) }
        }
        let manager = try fixture.manager()
        _ = try await manager.initialize(at: fixture.source)
        let clone = try await manager.create(
            from: fixture.source, name: "protected", options: CreateOptions(copyMode: mode, hooks: .skip)
        )
        let trash = try fixture.trash(for: clone)

        try await manager.remove(at: clone, options: RemoveOptions(hooks: .skip))
        let collected = try await manager.garbageCollect()

        #expect(collected.map(\.path) == [trash.path])
        #expect(!fixture.exists(trash))
        #expect(try fixture.read(original) == "protected")
        #expect(try metadata(locked).st_mode & 0o7777 == 0o555)
        #expect(try metadata(original).st_flags & UInt32(UF_IMMUTABLE) != 0)
    }

    @Test(arguments: [false, true])
    func failedCollectionPreservesMarkerAndCanBeRetried(blockRoot: Bool) async throws {
        let fixture = try RiftFixture()
        let manager = try fixture.manager()
        _ = try await manager.initialize(at: fixture.source)
        let clone = try await manager.create(from: fixture.source, name: "retry", options: CreateOptions(hooks: .skip))
        let id = try fixture.marker(clone)
        let trash = try fixture.trash(for: clone)
        try await manager.remove(at: clone, options: RemoveOptions(hooks: .skip))
        let blocked = blockRoot ? trash : trash.appendingPathComponent("file.txt")
        let denial = "user:\(NSUserName()) deny delete"
        try chmodACL(["+a", denial, blocked.path])
        defer { try? chmodACL(["-a", denial, blocked.path]) }

        await expectRiftError(matching: {
            if case .io(_, _, let code) = $0 { return code == EACCES || code == EPERM }
            return false
        }, performing: {
            try await manager.garbageCollect()
        })
        #expect(fixture.exists(trash))
        #expect(try fixture.marker(trash) == id)
        try WorkspaceIdentity.verify(at: trash, id: id)

        try chmodACL(["-a", denial, blocked.path])
        let reopened = try fixture.manager()
        let collected = try await reopened.garbageCollect()
        #expect(collected.map(\.path) == [trash.path])
        #expect(!fixture.exists(trash))
    }

    private func chmodACL(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw ACLFixtureError.chmodFailed(String(decoding: message, as: UTF8.self))
        }
    }

    private func metadata(_ path: URL) throws -> stat {
        var info = stat()
        try check(path.withUnsafeFileSystemRepresentation { lstat($0!, &info) })
        return info
    }

    private func setMode(_ path: URL, _ mode: mode_t) throws {
        try check(path.withUnsafeFileSystemRepresentation { chmod($0!, mode) })
    }

    private func setFlags(_ path: URL, _ flags: UInt32) throws {
        try check(path.withUnsafeFileSystemRepresentation { lchflags($0!, flags) })
    }

    private func check(_ result: Int32) throws {
        if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
    }
}

private enum ACLFixtureError: Error {
    case chmodFailed(String)
}
