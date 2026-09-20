import Foundation
import Testing
@testable import Rift

struct GitIntegrationTests {
    @Test func distinguishesPlainAndGitDirectories() throws {
        let fixture = try GitFixture()
        #expect(try !GitIntegration.checkSource(at: fixture.directory))
        try fixture.makeDirectory(".git")
        #expect(try GitIntegration.checkSource(at: fixture.directory))
    }

    @Test func rejectsLinkedWorktreeMarkerAndSymbolicGitDirectory() throws {
        let fixture = try GitFixture()
        try fixture.write(".git", "gitdir: elsewhere\n")
        #expect(throws: RiftError.self) { try GitIntegration.checkSource(at: fixture.directory) }
        try FileManager.default.removeItem(at: fixture.url(".git"))
        try fixture.makeDirectory("metadata")
        try FileManager.default.createSymbolicLink(at: fixture.url(".git"), withDestinationURL: fixture.url("metadata"))
        #expect(throws: RiftError.self) { try GitIntegration.checkSource(at: fixture.directory) }
        try FileManager.default.removeItem(at: fixture.url("metadata"))
        #expect(throws: RiftError.self) { try GitIntegration.checkSource(at: fixture.directory) }
    }

    @Test(arguments: [
        "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG",
        "rebase-merge", "rebase-apply", "index.lock", "HEAD.lock", "commondir",
    ])
    func rejectsUnsafeGitStates(_ state: String) throws {
        let fixture = try GitFixture()
        try fixture.makeDirectory(".git")
        try fixture.write(".git/\(state)", "in progress\n")
        #expect(throws: RiftError.self) { try GitIntegration.checkSource(at: fixture.directory) }
    }

    @Test(arguments: ["HEAD", "info", "info/exclude"])
    func rejectsSymbolicMetadataBeforeWriting(_ metadata: String) throws {
        let fixture = try GitFixture()
        try fixture.makeDirectory(".git/info")
        try fixture.write("external", "protected\n")
        let path = fixture.url(".git/\(metadata)")
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: fixture.url("external"))
        #expect(throws: RiftError.self) { try GitIntegration.hideMarker(at: fixture.directory) }
        #expect(try fixture.read("external") == "protected\n")
    }

    @Test func appendsMarkerExclusionAndRemainsIdempotent() throws {
        let fixture = try GitFixture()
        try fixture.makeDirectory(".git")
        try GitIntegration.hideMarker(at: fixture.directory)
        #expect(try fixture.read(".git/info/exclude") == "/.rift\n")
        try fixture.write(".git/info/exclude", "existing")
        try GitIntegration.hideMarker(at: fixture.directory)
        try GitIntegration.hideMarker(at: fixture.directory)
        #expect(try fixture.read(".git/info/exclude") == "existing\n/.rift\n")
        try fixture.write(".git/info/exclude", "existing\n /.rift \n")
        try GitIntegration.hideMarker(at: fixture.directory)
        #expect(try fixture.read(".git/info/exclude") == "existing\n /.rift \n")
    }

    @Test func leavesUnbornHeadUnchanged() throws {
        let fixture = try GitFixture()
        try fixture.git(["init", "--initial-branch=main"])
        let head = try fixture.read(".git/HEAD")
        try GitIntegration.detachDestination(at: fixture.directory)
        #expect(try fixture.read(".git/HEAD") == head)
    }

    @Test func detachesCopiedRepositoryWhilePreservingDirtyState() throws {
        let fixture = try GitFixture()
        try fixture.initializeCommit()
        try fixture.write("tracked", "staged\n")
        try fixture.git(["add", "tracked"])
        try fixture.write("tracked", "unstaged\n")
        try fixture.write("untracked", "untracked\n")
        try fixture.write("ignored", "ignored\n")
        let sourceHead = try fixture.read(".git/HEAD")
        let index = try Data(contentsOf: fixture.url(".git/index"))
        let status = try fixture.git(["status", "--porcelain=v1", "--untracked-files=all"])
        let commit = try fixture.git(["rev-parse", "--verify", "HEAD^{commit}"]).trimmingCharacters(in: .whitespacesAndNewlines)
        // A sibling avoids copying a directory recursively into itself.
        let copy = fixture.directory.deletingLastPathComponent().appendingPathComponent("\(fixture.directory.lastPathComponent)-copy")
        defer { try? FileManager.default.removeItem(at: copy) }
        try FileManager.default.copyItem(at: fixture.directory, to: copy)
        try GitIntegration.detachDestination(at: copy)
        #expect(try String(contentsOf: copy.appendingPathComponent(".git/HEAD"), encoding: .utf8) == "\(commit)\n")
        #expect(try Data(contentsOf: copy.appendingPathComponent(".git/index")) == index)
        #expect(try fixture.read(".git/HEAD") == sourceHead)
        #expect(try GitFixture.git(at: copy, arguments: ["status", "--porcelain=v1", "--untracked-files=all"]) == status)
        #expect(try String(contentsOf: copy.appendingPathComponent("tracked"), encoding: .utf8) == "unstaged\n")
        #expect(try String(contentsOf: copy.appendingPathComponent("untracked"), encoding: .utf8) == "untracked\n")
        #expect(try String(contentsOf: copy.appendingPathComponent("ignored"), encoding: .utf8) == "ignored\n")
    }

    @Test func peelsAnnotatedTagHeadToCommit() throws {
        let fixture = try GitFixture()
        try fixture.initializeCommit()
        let commit = try fixture.git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try fixture.git(["tag", "--annotate", "snapshot", "--message", "snapshot"])
        try fixture.write(".git/HEAD", "ref: refs/tags/snapshot\n")
        try GitIntegration.detachDestination(at: fixture.directory)
        #expect(try fixture.read(".git/HEAD") == "\(commit)\n")
    }
}

private final class GitFixture {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("rift-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func url(_ path: String) -> URL { directory.appendingPathComponent(path) }
    func write(_ path: String, _ contents: String) throws { try Data(contents.utf8).write(to: url(path)) }
    func read(_ path: String) throws -> String { try String(contentsOf: url(path), encoding: .utf8) }
    func makeDirectory(_ path: String) throws { try FileManager.default.createDirectory(at: url(path), withIntermediateDirectories: true) }

    func initializeCommit() throws {
        try git(["init", "--initial-branch=main"])
        try git(["config", "user.email", "rift-tests@example.invalid"])
        try git(["config", "user.name", "Rift tests"])
        try write("tracked", "committed\n")
        try write(".gitignore", "ignored\n")
        try git(["add", "tracked", ".gitignore"])
        try git(["commit", "--message", "fixture", "--no-gpg-sign"])
    }

    @discardableResult func git(_ arguments: [String]) throws -> String {
        try Self.git(at: directory, arguments: arguments)
    }

    @discardableResult static func git(at directory: URL, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitFixtureError.command(arguments, process.terminationStatus)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

private enum GitFixtureError: Error {
    case command([String], Int32)
}
