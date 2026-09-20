import Foundation
import Darwin
import Testing
import Rift

/// All registry, workspace, hook, Git, and trash writes stay inside this directory.
final class RiftFixture {
    let directory: URL
    let source: URL
    let databaseURL: URL

    init() throws {
        let requested = FileManager.default.temporaryDirectory
            .appendingPathComponent("rift-swift-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: true)
        guard let canonical = realpath(requested.path, nil) else {
            let code = errno
            try? FileManager.default.removeItem(at: requested)
            throw FixtureError.canonicalPath(path: requested, code: code)
        }
        directory = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
        free(canonical)
        source = directory.appendingPathComponent("app", isDirectory: true)
        databaseURL = directory.appendingPathComponent("registry.sqlite")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try write("hello", to: source.appendingPathComponent("file.txt"))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func manager() throws -> RiftManager {
        try RiftManager(databaseURL: databaseURL)
    }

    func path(_ relative: String) -> URL {
        directory.appendingPathComponent(relative)
    }

    func child(_ name: String) -> URL {
        path(".rifts/app/\(name)")
    }

    func mkdir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func write(_ contents: String, to url: URL) throws {
        try mkdir(url.deletingLastPathComponent())
        try Data(contents.utf8).write(to: url)
    }

    func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func delete(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    func move(_ from: URL, to: URL) throws {
        try FileManager.default.moveItem(at: from, to: to)
    }

    func marker(_ workspace: URL) throws -> String {
        try read(workspace.appendingPathComponent(".rift")).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func trash(for workspace: URL) throws -> URL {
        let id = try marker(workspace)
        return workspace.deletingLastPathComponent()
            .appendingPathComponent(".trash", isDirectory: true)
            .appendingPathComponent("\(id)-\(workspace.lastPathComponent)", isDirectory: true)
    }

    func configure(_ contents: String, at workspace: URL? = nil) throws {
        try write(contents, to: (workspace ?? source).appendingPathComponent(".rift.toml"))
    }

    /// Ignores user Git configuration and hooks, and never touches a remote.
    @discardableResult
    func git(_ arguments: [String], at workspace: URL? = nil, allowFailure: Bool = false) throws -> GitResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", (workspace ?? source).path, "-c", "core.hooksPath=/dev/null"] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errors = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let result = GitResult(
            status: process.terminationStatus,
            output: String(decoding: output, as: UTF8.self),
            errors: String(decoding: errors, as: UTF8.self)
        )
        guard allowFailure || result.status == 0 else {
            throw FixtureError.gitFailed(arguments: arguments, message: result.errors)
        }
        return result
    }

    func commitInitialGitRepository() throws {
        try git(["init", "--initial-branch=main"])
        try git(["config", "user.email", "rift-tests@example.invalid"])
        try git(["config", "user.name", "Rift Tests"])
        try git(["add", "file.txt"])
        try git(["commit", "-m", "initial"])
    }
}

struct GitResult {
    let status: Int32
    let output: String
    let errors: String
}

enum FixtureError: Error {
    case gitFailed(arguments: [String], message: String)
    case canonicalPath(path: URL, code: Int32)
}

func expectRiftError<T>(
    matching predicate: (RiftError) -> Bool,
    performing operation: () async throws -> T,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    do {
        _ = try await operation()
        Issue.record("Expected a RiftError, but the operation succeeded", sourceLocation: sourceLocation)
    } catch let error as RiftError {
        if !predicate(error) {
            Issue.record("Unexpected RiftError: \(error)", sourceLocation: sourceLocation)
        }
    } catch {
        Issue.record("Expected a RiftError, got \(error)", sourceLocation: sourceLocation)
    }
}

enum CreationAttempt: Sendable {
    case created(URL)
    case failed(RiftError)
    case unexpectedFailure(String)
}

func creationAttempt(manager: RiftManager, source: URL, storage: URL, name: String) async -> CreationAttempt {
    do {
        return .created(try await manager.create(from: source, name: name, into: storage))
    } catch let error as RiftError {
        return .failed(error)
    } catch {
        return .unexpectedFailure(String(describing: error))
    }
}
