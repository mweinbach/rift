import CRiftFilesystem
import Darwin
import Foundation

/// Copies data exclusively through the native clonefile system call.
struct APFSCloner {
    private struct FileIdentity: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    private struct DirectoryPair {
        let source: URL
        let destination: URL
        let components: [String]
    }

    func copyDirectory(from source: URL, to destination: URL, mode: CopyMode) throws {
        try validateFileURL(source)
        try validateFileURL(destination)
        let rootInfo = try readInfo(at: source)
        guard rootInfo.type == Int32(RIFT_ENTRY_DIRECTORY.rawValue) else {
            throw RiftError.unsupportedEntry(source)
        }
        var existing = rift_file_info()
        let destinationCode = destination.withUnsafeFileSystemRepresentation { path in
            rift_read_file_info(path!, &existing)
        }
        if destinationCode == 0 { throw RiftError.alreadyExists(destination) }
        if destinationCode != ENOENT {
            throw RiftError.io(operation: "read metadata", path: destination, code: destinationCode)
        }
        // Prevent creating a directory that would become part of its own walk.
        let canonicalSource = try WorkspacePaths.existingDirectory(source)
        let canonicalDestination = try WorkspacePaths.prospectiveDirectory(destination)
        if WorkspacePaths.contains(canonicalSource, canonicalDestination) {
            throw RiftError.io(operation: "copy into source directory", path: destination, code: EINVAL)
        }

        switch mode {
        case .all:
            try clone(source, to: destination)
        case .filtered:
            try cloneFilteredDirectory(source, to: destination)
        }
    }

    func removeDirectory(at path: URL) throws {
        try validateFileURL(path)
        guard try readInfo(at: path).type == Int32(RIFT_ENTRY_DIRECTORY.rawValue) else {
            try removeEntry(at: path)
            return
        }
        try prepareRemoval(at: path)
        let marker = path.appendingPathComponent(".rift")
        // Collection must retain its identity when any descendant cannot be
        // deleted. Save regular marker contents for a failed final rmdir too.
        let markerContents: Data?
        var markerInfo = rift_file_info()
        let markerCode = marker.withUnsafeFileSystemRepresentation { rift_read_file_info($0!, &markerInfo) }
        if markerCode == 0 && markerInfo.type == Int32(RIFT_ENTRY_FILE.rawValue) {
            markerContents = try Data(contentsOf: marker)
        } else {
            if markerCode != 0 && markerCode != ENOENT {
                try check(markerCode, operation: "read marker metadata", path: marker)
            }
            markerContents = nil
        }
        for entry in try children(of: path) where entry.lastPathComponent != ".rift" {
            try removeEntry(at: entry)
        }
        if markerCode == 0 { try removeEntry(at: marker) }
        do {
            try removeEmptyDirectory(at: path)
        } catch {
            // Parent permissions, ACLs, or a newly added child may prevent the
            // final removal even though descendants were deleted successfully.
            if let markerContents {
                do { try markerContents.write(to: marker, options: .atomic) }
                catch let restorationError {
                    throw RiftError.rollbackFailed(
                        operation: "Collect workspace",
                        message: "\(error); restoring \(marker.path) failed: \(restorationError)"
                    )
                }
            }
            throw error
        }
    }

    private func removeEntry(at path: URL) throws {
        let info = try readInfo(at: path)
        try prepareRemoval(at: path)
        if info.type == Int32(RIFT_ENTRY_DIRECTORY.rawValue) {
            for entry in try children(of: path) { try removeEntry(at: entry) }
            try removeEmptyDirectory(at: path)
        } else {
            let code = path.withUnsafeFileSystemRepresentation { rift_remove_path($0!, 0) }
            try check(code, operation: "remove entry", path: path)
        }
    }

    private func prepareRemoval(at path: URL) throws {
        let code = path.withUnsafeFileSystemRepresentation { rift_prepare_removal($0!) }
        try check(code, operation: "prepare removal", path: path)
    }

    private func removeEmptyDirectory(at path: URL) throws {
        let code = path.withUnsafeFileSystemRepresentation { rift_remove_path($0!, 1) }
        try check(code, operation: "remove directory", path: path)
    }

    private func cloneFilteredDirectory(_ source: URL, to destination: URL) throws {
        try createDirectory(at: destination)
        let root = DirectoryPair(source: source, destination: destination, components: [])
        var pending = [root]
        var directories = [root]
        var hardLinks: [FileIdentity: URL] = [:]
        let filter = CopyFilter()

        while let directory = pending.popLast() {
            for entry in try children(of: directory.source) {
                let components = directory.components + [entry.lastPathComponent]
                if filter.excludes(components: components) { continue }
                let copied = directory.destination.appendingPathComponent(entry.lastPathComponent)
                let info = try readInfo(at: entry)
                switch info.type {
                case Int32(RIFT_ENTRY_DIRECTORY.rawValue):
                    try createDirectory(at: copied)
                    let pair = DirectoryPair(source: entry, destination: copied, components: components)
                    directories.append(pair)
                    pending.append(pair)
                case Int32(RIFT_ENTRY_FILE.rawValue):
                    let identity = FileIdentity(device: info.device, inode: info.inode)
                    if info.link_count > 1, let existing = hardLinks[identity] {
                        try perform("create hard link", source: existing, destination: copied, rift_create_hard_link)
                    } else {
                        try clone(entry, to: copied)
                        if info.link_count > 1 { hardLinks[identity] = copied }
                    }
                    let code = copied.withUnsafeFileSystemRepresentation { path in
                        rift_restore_cloned_file_mode(path!, info.mode)
                    }
                    try check(code, operation: "set permissions", path: copied)
                case Int32(RIFT_ENTRY_SYMLINK.rawValue):
                    try perform("copy symbolic link", source: entry, destination: copied, rift_copy_symlink)
                    try copyMetadata(from: entry, to: copied)
                default:
                    throw RiftError.unsupportedEntry(entry)
                }
            }
        }
        // Parent permissions, timestamps, and flags are applied after children.
        for directory in directories.reversed() {
            try copyMetadata(from: directory.source, to: directory.destination)
        }
    }

    private func children(of directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }

    private func readInfo(at path: URL) throws -> rift_file_info {
        var info = rift_file_info()
        let code = path.withUnsafeFileSystemRepresentation { representation in
            rift_read_file_info(representation!, &info)
        }
        try check(code, operation: "read metadata", path: path)
        return info
    }

    private func createDirectory(at path: URL) throws {
        let code = path.withUnsafeFileSystemRepresentation { rift_create_directory($0!) }
        if code == EEXIST { throw RiftError.alreadyExists(path) }
        try check(code, operation: "create directory", path: path)
    }

    private func clone(_ source: URL, to destination: URL) throws {
        let code = source.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in
                rift_clone_path(from!, to!)
            }
        }
        if code == EEXIST { throw RiftError.alreadyExists(destination) }
        if code != 0 {
            throw RiftError.copyOnWriteUnavailable("failed to clone \(source.path): \(String(cString: strerror(code)))")
        }
    }

    private func copyMetadata(from source: URL, to destination: URL) throws {
        let error = source.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in
                rift_copy_metadata(from!, to!)
            }
        }
        if error.code != 0 {
            throw RiftError.io(
                operation: error.operation.map { String(cString: $0) } ?? "copy metadata",
                path: error.source_path == 0 ? destination : source,
                code: error.code
            )
        }
    }

    private func perform(
        _ operation: String, source: URL, destination: URL,
        _ body: (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
    ) throws {
        let code = source.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in body(from, to) }
        }
        if code == EEXIST { throw RiftError.alreadyExists(destination) }
        try check(code, operation: operation, path: destination)
    }

    private func check(_ code: Int32, operation: String, path: URL) throws {
        if code != 0 { throw RiftError.io(operation: operation, path: path, code: code) }
    }

    private func validateFileURL(_ url: URL) throws {
        if !url.isFileURL || url.path.utf8.contains(0) {
            throw RiftError.io(operation: "resolve filesystem path", path: url, code: EINVAL)
        }
    }
}
