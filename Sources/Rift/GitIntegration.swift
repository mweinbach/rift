import Darwin
import Foundation

enum GitIntegration {
    static func checkSource(at path: URL) throws -> Bool {
        let git = path.appendingPathComponent(".git", isDirectory: true)
        guard let metadata = try status(at: git) else { return false }
        guard isDirectory(metadata) else {
            throw RiftError.unsafeGit("linked Git worktree sources and symbolic .git directories are not supported")
        }

        for state in [
            "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG",
            "rebase-merge", "rebase-apply", "index.lock", "HEAD.lock",
        ] {
            if try status(at: git.appendingPathComponent(state)) != nil {
                throw RiftError.unsafeGit("Git state in progress: \(state)")
            }
        }
        if try status(at: git.appendingPathComponent("commondir")) != nil {
            throw RiftError.unsafeGit("shared Git metadata is not supported")
        }
        try requireRegularFileIfPresent(git.appendingPathComponent("HEAD"))
        let info = git.appendingPathComponent("info", isDirectory: true)
        if let metadata = try status(at: info), !isDirectory(metadata) {
            throw RiftError.unsafeGit("Git info must be a directory, without symbolic links")
        }
        try requireRegularFileIfPresent(info.appendingPathComponent("exclude"))
        return true
    }

    static func hideMarker(at path: URL) throws {
        guard try checkSource(at: path) else { return }
        let info = path.appendingPathComponent(".git/info", isDirectory: true)
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "--no-optional-locks", "--git-dir=\(git.path)", "--work-tree=\(path.path)",
            "rev-parse", "--verify", "HEAD^{commit}",
        ]
        process.currentDirectoryURL = path
        // Git environment overrides can redirect even an explicit repository path.
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // An unborn repository has no commit to detach, matching the Rust implementation.
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return }
        let commit = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard (commit.utf8.count == 40 || commit.utf8.count == 64),
              commit.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) })
        else {
            throw RiftError.unsafeGit("Git returned an invalid HEAD commit")
        }
        // Replacing HEAD avoids changing either the index or the working tree.
        try Data("\(commit)\n".utf8).write(to: git.appendingPathComponent("HEAD"), options: .atomic)
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
