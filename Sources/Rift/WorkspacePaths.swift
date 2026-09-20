import Foundation
import Darwin

internal enum WorkspacePaths {
    static func validate(_ url: URL) throws {
        guard url.isFileURL, !url.path.utf8.contains(0) else {
            throw RiftError.invalidPath("Expected a file URL without null bytes: \(url)")
        }
    }

    static func existingDirectory(_ url: URL) throws -> URL {
        try validate(url)
        let canonical = try canonicalPath(url)
        var info = stat()
        guard lstat(canonical.path, &info) == 0 else {
            throw RiftError.io(operation: "read directory", path: canonical, code: errno)
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            throw RiftError.invalidPath("Not a directory: \(canonical.path)")
        }
        return URL(fileURLWithPath: canonical.path, isDirectory: true)
    }

    static func canonicalPath(_ url: URL) throws -> URL {
        try validate(url)
        guard let pointer = realpath(url.path, nil) else {
            throw RiftError.io(operation: "resolve path", path: url, code: errno)
        }
        defer { free(pointer) }
        return URL(fileURLWithPath: String(cString: pointer))
    }

    /// Resolve existing ancestors before creating storage, including symlinked parents.
    static func prospectiveDirectory(_ url: URL) throws -> URL {
        try validate(url)
        var current = url
        var remaining: [String] = []
        while true {
            if let pointer = realpath(current.path, nil) {
                defer { free(pointer) }
                var resolved = URL(fileURLWithPath: String(cString: pointer))
                for component in remaining.reversed() {
                    if component == "." { continue }
                    if component == ".." {
                        resolved.deleteLastPathComponent()
                        continue
                    }
                    resolved.appendPathComponent(component, isDirectory: true)
                }
                // Foundation standardization rewrites /private/var to /var on
                // macOS; retain the kernel's canonical path for registry identity.
                return resolved
            }
            let code = errno
            guard code == ENOENT, current.path != "/" else {
                throw RiftError.io(operation: "resolve storage", path: current, code: code)
            }
            remaining.append(current.lastPathComponent)
            current.deleteLastPathComponent()
        }
    }

    static func exists(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        let code = errno
        if code == ENOENT || code == ENOTDIR { return false }
        throw RiftError.io(operation: "check path", path: url, code: code)
    }

    static func contains(_ directory: URL, _ candidate: URL) -> Bool {
        let prefix = directory.path == "/" ? "/" : directory.path + "/"
        return candidate.path == directory.path || candidate.path.hasPrefix(prefix)
    }

    static func defaultStorage(root: URL) throws -> URL {
        guard root.path != "/", !root.lastPathComponent.isEmpty else {
            throw RiftError.invalidPath("Workspace has no parent or name: \(root.path)")
        }
        return root.deletingLastPathComponent()
            .appendingPathComponent(".rifts", isDirectory: true)
            .appendingPathComponent(root.lastPathComponent, isDirectory: true)
    }

    static func trash(id: String, path: URL) throws -> URL {
        guard !id.isEmpty, !id.contains("/"), !id.utf8.contains(0) else {
            throw RiftError.database("Unsafe workspace identifier in trash path")
        }
        guard path.path != "/", !path.lastPathComponent.isEmpty else {
            throw RiftError.invalidPath("Workspace has no parent or name: \(path.path)")
        }
        return path.deletingLastPathComponent()
            .appendingPathComponent(".trash", isDirectory: true)
            .appendingPathComponent("\(id)-\(path.lastPathComponent)", isDirectory: true)
    }

    static func moveExclusively(from: URL, to: URL) throws {
        guard renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            if code == EEXIST { throw RiftError.alreadyExists(to) }
            throw RiftError.io(operation: "move workspace", path: to, code: code)
        }
    }
}
