import Foundation
import Testing
@testable import Rift

struct OperationLockTests {
    @Test func hooksCanAcquireAnotherManagerLockAndOuterOperationRelocks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("registry.sqlite")
        let outer = try OperationLock(databaseURL: database)
        let nested = try OperationLock(databaseURL: database)
        var steps: [String] = []
        try outer.withLock {
            steps.append("outer")
            try outer.withoutFileLock {
                try nested.withLock { steps.append("hook") }
            }
            steps.append("resumed")
        }
        try nested.withLock { steps.append("next") }
        #expect(steps == ["outer", "hook", "resumed", "next"])
    }

    @Test func hookFailureReacquiresAndReleasesOperationLock() throws {
        enum Failure: Error { case expected }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("registry.sqlite")
        let outer = try OperationLock(databaseURL: database)
        let nested = try OperationLock(databaseURL: database)
        #expect(throws: Failure.expected) {
            try outer.withLock {
                try outer.withoutFileLock {
                    try nested.withLock { throw Failure.expected }
                }
            }
        }
        try nested.withLock { }
        try outer.withLock { }
    }
}
