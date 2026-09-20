import Darwin
import Foundation

enum GitIntegration {
    static func checkSource(at path: URL) throws -> Bool {
        guard let git = try checkedGitDirectory(at: path) else { return false }

        for state in [
            "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG",
            "rebase-merge", "rebase-apply", "sequencer", "index.lock", "HEAD.lock",
        ] {
            if try status(at: git.appendingPathComponent(state)) != nil {
                throw RiftError.unsafeGit("Git state in progress: \(state)")
            }
        }
        if try status(at: git.appendingPathComponent("commondir")) != nil {
            throw RiftError.unsafeGit("shared Git metadata is not supported")
        }
        if try status(at: git.appendingPathComponent("worktrees")) != nil {
            throw RiftError.unsafeGit("repositories with linked worktree metadata are not supported")
        }
        for file in ["HEAD", "config", "config.worktree", "index", "packed-refs", "shallow"] {
            try requireRegularFileIfPresent(git.appendingPathComponent(file))
        }
        for directory in ["info", "objects", "refs", "logs"] {
            try requireSafeStorageIfPresent(git.appendingPathComponent(directory, isDirectory: true))
        }
        for file in ["alternates", "http-alternates"] {
            let alternates = git.appendingPathComponent("objects/info/\(file)")
            if try status(at: alternates) != nil,
               !(try Data(contentsOf: alternates)).allSatisfy({ [9, 10, 13, 32].contains($0) }) {
                throw RiftError.unsafeGit("external Git object storage is not supported: \(file)")
            }
        }
        try checkConfiguration(at: path, git: git)
        return true
    }

    static func hideMarker(at path: URL) throws {
        // Only these paths are touched here; callers validate the complete Git
        // layout separately before registering or copying a workspace.
        guard let git = try checkedGitDirectory(at: path) else { return }
        try requireRegularFileIfPresent(git.appendingPathComponent("HEAD"))
        let info = git.appendingPathComponent("info", isDirectory: true)
        if let metadata = try status(at: info), !isDirectory(metadata) {
            throw RiftError.unsafeGit("Git info must be a directory, without symbolic links")
        }
        try requireRegularFileIfPresent(info.appendingPathComponent("exclude"))
        try FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)
        let exclude = info.appendingPathComponent("exclude")
        let existing = try status(at: exclude) == nil ? "" : String(contentsOf: exclude, encoding: .utf8)
        if existing.split(separator: "\n", omittingEmptySubsequences: false).contains(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == "/.rift"
        }) {
            return
        }
        let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        try Data("\(existing)\(separator)/.rift\n".utf8).write(to: exclude, options: .atomic)
    }

    static func detachDestination(at path: URL) throws {
        guard try checkSource(at: path) else { return }
        let git = path.appendingPathComponent(".git", isDirectory: true)
        let result = try runGit(at: path, arguments: ["rev-parse", "--verify", "HEAD^{commit}"])
        if result.status != 0 {
            // Only a symbolic branch with no ref is unborn. Missing objects,
            // malformed metadata and other Git failures must abort creation.
            let symbolic = try runGit(at: path, arguments: ["symbolic-ref", "--quiet", "HEAD"])
            let reference = symbolic.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if symbolic.status == 0, reference.hasPrefix("refs/heads/") {
                let exists = try runGit(at: path, arguments: ["show-ref", "--verify", "--quiet", reference])
                if exists.status == 1 { return }
            }
            throw RiftError.unsafeGit("HEAD does not resolve to a commit (Git exited with status \(result.status))")
        }
        let commit = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (commit.utf8.count == 40 || commit.utf8.count == 64),
              commit.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) })
        else {
            throw RiftError.unsafeGit("Git returned an invalid HEAD commit")
        }
        // Replacing HEAD avoids changing either the index or the working tree.
        // checkConfiguration rejects ref backends that ignore a loose HEAD file.
        try Data("\(commit)\n".utf8).write(to: git.appendingPathComponent("HEAD"), options: .atomic)
    }

    private static func checkConfiguration(at path: URL, git: URL) throws {
        let config = git.appendingPathComponent("config")
        if try status(at: config) != nil {
            // Reading the file explicitly also checks extensions that would
            // otherwise make Git ignore this repository's configuration.
            try validateConfiguration(
                runGit(at: path, arguments: ["config", "--file", config.path, "--includes", "--null", "--list"])
            )
        }
        if try status(at: git.appendingPathComponent("HEAD")) != nil {
            // Includes, conditional includes, global settings and worktree
            // settings are evaluated by Git rather than a partial config parser.
            try validateConfiguration(runGit(at: path, arguments: ["config", "--includes", "--null", "--list"]))
        }
    }

    private static func validateConfiguration(_ result: GitResult) throws {
        guard result.status == 0 else {
            throw RiftError.unsafeGit("Git configuration could not be read (status \(result.status))")
        }
        var values: [String: String] = [:]
        for entry in result.output.split(separator: "\0") {
            let parts = entry.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            values[String(parts[0])] = parts.count == 2 ? String(parts[1]) : "true"
        }
        if values["core.worktree"] != nil {
            throw RiftError.unsafeGit("explicit core.worktree configuration cannot be copied independently")
        }
        if let storage = values["extensions.refstorage"], storage.lowercased() != "files" {
            throw RiftError.unsafeGit("unsupported Git ref storage: \(storage)")
        }
        if let bare = values["core.bare"], !["false", "no", "off", "0", ""].contains(bare.lowercased()) {
            throw RiftError.unsafeGit("bare Git metadata is not supported inside a workspace")
        }
    }

    private struct GitResult {
        let status: Int32
        let output: String
    }

    private static func runGit(at path: URL, arguments: [String]) throws -> GitResult {
        let git = path.appendingPathComponent(".git", isDirectory: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "--no-optional-locks", "--git-dir=\(git.path)", "--work-tree=\(path.path)",
        ] + arguments
        process.currentDirectoryURL = path
        // Git environment overrides can redirect even an explicit repository path.
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        let output = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit else {
            throw RiftError.unsafeGit("Git terminated by signal \(process.terminationStatus)")
        }
        return GitResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    private static func checkedGitDirectory(at path: URL) throws -> URL? {
        let git = path.appendingPathComponent(".git", isDirectory: true)
        guard let metadata = try status(at: git) else { return nil }
        guard isDirectory(metadata) else {
            throw RiftError.unsafeGit("linked Git worktree sources and symbolic .git directories are not supported")
        }
        return git
    }

    private static func requireSafeStorageIfPresent(_ path: URL) throws {
        guard let metadata = try status(at: path) else { return }
        guard isDirectory(metadata) else {
            throw RiftError.unsafeGit("Git storage must be a directory, without symbolic links: \(path.path)")
        }
        var directories = [path]
        while let directory = directories.popLast() {
            for entry in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                guard let metadata = try status(at: entry) else {
                    throw RiftError.unsafeGit("Git storage changed during validation: \(entry.path)")
                }
                if isDirectory(metadata) {
                    directories.append(entry)
                } else if (metadata.st_mode & S_IFMT) != S_IFREG {
                    throw RiftError.unsafeGit("Git storage must not contain symbolic links or special entries: \(entry.path)")
                }
            }
        }
    }

    private static func requireRegularFileIfPresent(_ path: URL) throws {
        if let metadata = try status(at: path), (metadata.st_mode & S_IFMT) != S_IFREG {
            throw RiftError.unsafeGit("Git metadata must be a regular file, without symbolic links: \(path.lastPathComponent)")
        }
    }

    private static func isDirectory(_ metadata: stat) -> Bool {
        (metadata.st_mode & S_IFMT) == S_IFDIR
    }

    private static func status(at path: URL) throws -> stat? {
        var metadata = stat()
        let result = path.withUnsafeFileSystemRepresentation { representation in
            guard let representation else { return Int32(-1) }
            return lstat(representation, &metadata)
        }
        if result == 0 { return metadata }
        let code = errno
        if code == ENOENT { return nil }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path.path])
    }
}
