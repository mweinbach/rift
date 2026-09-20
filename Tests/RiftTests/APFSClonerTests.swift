import CRiftFilesystem
import Darwin
import Foundation
import Testing
@testable import Rift

@Suite("APFS clone backend")
struct APFSClonerTests {
    @Test(arguments: [CopyMode.all, .filtered])
    func cloneUsesIndependentNativeStorage(mode: CopyMode) throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("source")
            let destination = root.appendingPathComponent("destination")
            try mkdir(source)
            let original = source.appendingPathComponent("file")
            try Data(repeating: 0x41, count: 1_048_576).write(to: original)
            try APFSCloner().copyDirectory(from: source, to: destination, mode: mode)
            let copied = destination.appendingPathComponent("file")

            // Different inodes distinguish clones from hardlinks. Matching
            // nonzero native clone IDs prove shared APFS clone ancestry.
            #expect(try metadata(original).st_ino != metadata(copied).st_ino)
            let originalCloneID = try cloneID(original)
            let copiedCloneID = try cloneID(copied)
            if let originalCloneID, let copiedCloneID {
                #expect(originalCloneID != 0)
                #expect(copiedCloneID == originalCloneID)
            } else if ProcessInfo.processInfo.environment["RIFT_REQUIRE_CLONE_ID"] != nil {
                Issue.record("This environment must expose native APFS clone identifiers")
            }

            let copyHandle = try FileHandle(forWritingTo: copied)
            try copyHandle.write(contentsOf: Data("copy".utf8))
            try copyHandle.close()
            #expect(try Data(contentsOf: original).prefix(4) == Data("AAAA".utf8))
            let sourceHandle = try FileHandle(forWritingTo: original)
            try sourceHandle.seek(toOffset: 8)
            try sourceHandle.write(contentsOf: Data("source".utf8))
            try sourceHandle.close()
            #expect(try Data(contentsOf: copied).prefix(4) == Data("copy".utf8))
            #expect(try Data(contentsOf: copied)[8..<14] == Data("AAAAAA".utf8))
            try APFSCloner().removeDirectory(at: destination)
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }

    @Test
    func filteredCopyPreservesReadOnlyObjectsAndDirectoryMetadata() throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("source")
            let destination = root.appendingPathComponent("destination")
            let objects = source.appendingPathComponent(".git/objects/0d")
            try FileManager.default.createDirectory(at: objects, withIntermediateDirectories: true)
            let object = objects.appendingPathComponent("8a474f")
            try Data("object".utf8).write(to: object)
            try writeXattr(object, name: "com.rift.test", value: Data("marked".utf8))
            try setMode(object, 0o444)
            try writeXattr(objects, name: "com.rift.test", value: Data("directory".utf8))
            try setTimes(objects, seconds: 1_650_000_000, nanoseconds: 123_456_789)
            try setMode(objects, 0o555)
            try setFlags(objects, UInt32(UF_HIDDEN))
            try setMode(source, 0o750)
            let originalDirectoryMetadata = try metadata(objects)

            try APFSCloner().copyDirectory(from: source, to: destination, mode: .filtered)

            let copiedObject = destination.appendingPathComponent(".git/objects/0d/8a474f")
            let copiedDirectory = copiedObject.deletingLastPathComponent()
            let copiedMetadata = try metadata(copiedDirectory)
            #expect(try Data(contentsOf: copiedObject) == Data("object".utf8))
            #expect(try metadata(copiedObject).st_mode & 0o7777 == 0o444)
            #expect(try readXattr(copiedObject, name: "com.rift.test") == Data("marked".utf8))
            #expect(try readXattr(copiedDirectory, name: "com.rift.test") == Data("directory".utf8))
            #expect(copiedMetadata.st_mode & 0o7777 == 0o555)
            #expect(copiedMetadata.st_flags == originalDirectoryMetadata.st_flags)
            #expect(copiedMetadata.st_mtimespec.tv_sec == originalDirectoryMetadata.st_mtimespec.tv_sec)
            #expect(copiedMetadata.st_mtimespec.tv_nsec == originalDirectoryMetadata.st_mtimespec.tv_nsec)
            #expect(copiedMetadata.st_birthtimespec.tv_sec == originalDirectoryMetadata.st_birthtimespec.tv_sec)
            #expect(copiedMetadata.st_birthtimespec.tv_nsec == originalDirectoryMetadata.st_birthtimespec.tv_nsec)
            #expect(try metadata(destination).st_mode & 0o7777 == 0o750)
        }
    }

    @Test
    func filteredCopyPreservesHardLinksSpecialPermissionsAndSymlinks() throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("source")
            let destination = root.appendingPathComponent("destination")
            try mkdir(source)
            let original = source.appendingPathComponent("file")
            try Data("hello".utf8).write(to: original)
            let linked = source.appendingPathComponent("hard")
            try check(original.withUnsafeFileSystemRepresentation { first in
                linked.withUnsafeFileSystemRepresentation { second in link(first!, second!) }
            })
            try setMode(original, 0o6555)
            let relative = source.appendingPathComponent("relative")
            let dangling = source.appendingPathComponent("dangling")
            let absolute = source.appendingPathComponent("absolute")
            try FileManager.default.createSymbolicLink(atPath: relative.path, withDestinationPath: "file")
            try FileManager.default.createSymbolicLink(atPath: dangling.path, withDestinationPath: "absent")
            try FileManager.default.createSymbolicLink(atPath: absolute.path, withDestinationPath: original.path)
            try setTimes(dangling, seconds: 1_640_000_000, nanoseconds: 987_654_321)
            let sourceSymlinkMetadata = try metadata(dangling)

            try APFSCloner().copyDirectory(from: source, to: destination, mode: .filtered)

            let copy = destination.appendingPathComponent("file")
            #expect(try metadata(copy).st_ino == metadata(destination.appendingPathComponent("hard")).st_ino)
            #expect(try metadata(copy).st_ino != metadata(original).st_ino)
            #expect(try metadata(copy).st_mode & 0o7777 == 0o6555)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("relative").path) == "file")
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("dangling").path) == "absent")
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("absolute").path) == original.path)
            let copiedSymlinkMetadata = try metadata(destination.appendingPathComponent("dangling"))
            #expect(copiedSymlinkMetadata.st_mtimespec.tv_sec == sourceSymlinkMetadata.st_mtimespec.tv_sec)
            #expect(copiedSymlinkMetadata.st_mtimespec.tv_nsec == sourceSymlinkMetadata.st_mtimespec.tv_nsec)
        }
    }

    @Test
    func filteredCopyPrunesExactArtifactsAtEveryDepth() throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("source")
            let destination = root.appendingPathComponent("destination")
            for path in ["packages/app/node_modules/pkg", ".yarn/cache", ".yarn/releases", "Build", "builder", ".git"] {
                let directory = source.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data("included or excluded".utf8).write(to: directory.appendingPathComponent("file"))
            }
            try Data().write(to: source.appendingPathComponent(".yarn/install-state.gz"))
            try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("target").path, withDestinationPath: "builder")

            try APFSCloner().copyDirectory(from: source, to: destination, mode: .filtered)

            for path in ["packages/app/node_modules", ".yarn/cache", ".yarn/install-state.gz", "target"] {
                #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent(path).path))
            }
            for path in [".yarn/releases/file", "Build/file", "builder/file", ".git/file"] {
                #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent(path).path))
            }
            let filter = CopyFilter()
            #expect(filter.excludes(components: ["nested", ".yarn", "unplugged", "file"]))
            #expect(filter.excludes(components: ["nested", ".yarn", "build-state.yml"]))
            #expect(!filter.excludes(components: ["nested", "yarn", "cache"]))
            #expect(!filter.excludes(components: ["nested", "package-lock.json"]))
        }
    }

    @Test(arguments: [CopyMode.filtered, .all])
    func swiftBuildArtifactsAreFilteredWithoutDroppingPackageMetadata(mode: CopyMode) throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("source")
            let destination = root.appendingPathComponent("destination")
            for relative in [".build/checkouts/dependency", "packages/app/.build/debug", "Build", ".swiftpm/configuration"] {
                let directory = source.appendingPathComponent(relative)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data("artifact or metadata".utf8).write(to: directory.appendingPathComponent("file"))
            }
            for name in ["Package.swift", "Package.resolved"] {
                try Data("package metadata".utf8).write(to: source.appendingPathComponent(name))
            }

            try APFSCloner().copyDirectory(from: source, to: destination, mode: mode)

            for relative in [".build", "packages/app/.build"] {
                #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent(relative).path) == (mode == .all))
            }
            for relative in ["Build/file", ".swiftpm/configuration/file", "Package.swift", "Package.resolved"] {
                #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent(relative).path))
            }
        }
    }

    @Test
    func deletionDoesNotFollowSymbolicLinksOrModifyTheirTargets() throws {
        try withTemporaryDirectory { root in
            let outside = root.appendingPathComponent("outside")
            let file = outside.appendingPathComponent("file")
            let tree = root.appendingPathComponent("tree")
            try mkdir(outside)
            try mkdir(tree)
            try Data("keep".utf8).write(to: file)
            try setMode(outside, 0o555)
            try setFlags(file, UInt32(UF_IMMUTABLE))
            try FileManager.default.createSymbolicLink(atPath: tree.appendingPathComponent("link").path, withDestinationPath: "../outside")
            let rootLink = root.appendingPathComponent("root-link")
            try FileManager.default.createSymbolicLink(atPath: rootLink.path, withDestinationPath: outside.path)

            try APFSCloner().removeDirectory(at: tree)
            try APFSCloner().removeDirectory(at: rootLink)

            #expect(!FileManager.default.fileExists(atPath: tree.path))
            #expect(!FileManager.default.fileExists(atPath: rootLink.path))
            #expect(try Data(contentsOf: file) == Data("keep".utf8))
            #expect(try metadata(outside).st_mode & 0o7777 == 0o555)
            #expect(try metadata(file).st_flags & UInt32(UF_IMMUTABLE) != 0)
        }
    }

    @Test
    func filteredCopyPreservesImmutableHardLinks() throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("source")
            let destination = root.appendingPathComponent("destination")
            try mkdir(source)
            let original = source.appendingPathComponent("file")
            let linked = source.appendingPathComponent("hard")
            try Data("immutable".utf8).write(to: original)
            try check(original.withUnsafeFileSystemRepresentation { first in
                linked.withUnsafeFileSystemRepresentation { second in link(first!, second!) }
            })
            try setFlags(original, UInt32(UF_IMMUTABLE))

            try APFSCloner().copyDirectory(from: source, to: destination, mode: .filtered)

            let copied = try metadata(destination.appendingPathComponent("file"))
            let copiedLink = try metadata(destination.appendingPathComponent("hard"))
            #expect(copied.st_ino == copiedLink.st_ino)
            #expect(copied.st_flags & UInt32(UF_IMMUTABLE) != 0)
            #expect(copiedLink.st_flags & UInt32(UF_IMMUTABLE) != 0)
        }
    }

    @Test
    func filteredCopyToleratesForeignGroupOwnership() throws {
        // Entries beneath /private/tmp inherit wheel. This exercises the
        // best-effort lchown branch without privileged fixture setup.
        let sourceRoot = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("rift-apfs-foreign-group-\(UUID().uuidString)")
        try mkdir(sourceRoot)
        defer { try? FileManager.default.removeItem(at: sourceRoot) }
        let count = getgroups(0, nil)
        if count < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
        var groups = [gid_t](repeating: 0, count: Int(count))
        let read = groups.withUnsafeMutableBufferPointer { getgroups(count, $0.baseAddress) }
        if read < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
        groups.append(getegid())
        let foreignGroup = try metadata(sourceRoot).st_gid
        // The fixture cannot exercise EPERM when the caller belongs to wheel.
        if groups.contains(foreignGroup) || geteuid() == 0 { return }
        let nested = sourceRoot.appendingPathComponent("nested")
        try mkdir(nested)
        try Data("foreign group".utf8).write(to: nested.appendingPathComponent("file"))

        try withTemporaryDirectory { root in
            let destination = root.appendingPathComponent("destination")
            try APFSCloner().copyDirectory(from: sourceRoot, to: destination, mode: .filtered)
            #expect(try Data(contentsOf: destination.appendingPathComponent("nested/file")) == Data("foreign group".utf8))
        }
    }

    @Test(arguments: [CopyMode.all, .filtered])
    func nativeFullCloneAndFilteredSpecialEntryRulesPreserveExistingDestinations(mode: CopyMode) throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("source")
            let destination = root.appendingPathComponent("destination")
            try mkdir(source)
            let fifo = source.appendingPathComponent("fifo")
            try check(fifo.withUnsafeFileSystemRepresentation { mkfifo($0!, 0o600) })
            do {
                try APFSCloner().copyDirectory(from: source, to: destination, mode: mode)
                if mode == .all {
                    // The full fast path inherits native directory-clone
                    // semantics, which support FIFOs on current APFS.
                    let copiedType = try metadata(destination.appendingPathComponent("fifo")).st_mode & S_IFMT
                    #expect(copiedType == S_IFIFO)
                    #expect(copiedType == (try metadata(fifo).st_mode & S_IFMT))
                } else {
                    Issue.record("The filtered walker must reject FIFOs")
                }
            } catch RiftError.unsupportedEntry(let path) {
                #expect(mode == .filtered)
                #expect(path.standardizedFileURL == fifo.standardizedFileURL)
            } catch RiftError.copyOnWriteUnavailable {
                #expect(mode == .all)
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.removeItem(at: fifo)
            try FileManager.default.createSymbolicLink(atPath: destination.path, withDestinationPath: "absent")
            do {
                try APFSCloner().copyDirectory(from: source, to: destination, mode: mode)
                Issue.record("An existing dangling symlink must not be overwritten")
            } catch RiftError.alreadyExists(let path) {
                #expect(path == destination)
            }
        }
    }

    @Test(arguments: [false, true])
    func rejectsDestinationInsideSourceBeforeCreatingIt(useCaseAlias: Bool) throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("source")
            try mkdir(source)
            let selected = useCaseAlias ? root.appendingPathComponent("SOURCE") : source
            if useCaseAlias, !FileManager.default.fileExists(atPath: selected.path) { return }
            let destination = selected.appendingPathComponent("copy")
            do {
                try APFSCloner().copyDirectory(from: source, to: destination, mode: .filtered)
                Issue.record("A destination inside its source must be rejected")
            } catch RiftError.io(_, let path, let code) {
                #expect(path == destination)
                #expect(code == EINVAL)
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rift-apfs-\(UUID().uuidString)")
        try mkdir(root)
        defer {
            // Tests seed read-only directories and BSD flags deliberately.
            // Clear only test-fixture metadata, and never follow symlinks.
            if let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
                for case let entry as URL in entries {
                    _ = entry.withUnsafeFileSystemRepresentation { lchflags($0!, 0) }
                    if (try? metadata(entry).st_mode & S_IFMT) == S_IFDIR {
                        _ = entry.withUnsafeFileSystemRepresentation { chmod($0!, 0o700) }
                    }
                }
            }
            try? FileManager.default.removeItem(at: root)
        }
        try body(root)
    }

    private func mkdir(_ path: URL) throws {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
    }

    private func metadata(_ path: URL) throws -> stat {
        var value = stat()
        try check(path.withUnsafeFileSystemRepresentation { lstat($0!, &value) })
        return value
    }

    private func setMode(_ path: URL, _ mode: mode_t) throws {
        try check(path.withUnsafeFileSystemRepresentation { chmod($0!, mode) })
    }

    private func setFlags(_ path: URL, _ flags: UInt32) throws {
        try check(path.withUnsafeFileSystemRepresentation { lchflags($0!, flags) })
    }

    private func setTimes(_ path: URL, seconds: Int, nanoseconds: Int) throws {
        let times = [timespec(tv_sec: seconds, tv_nsec: nanoseconds), timespec(tv_sec: seconds, tv_nsec: nanoseconds)]
        try check(path.withUnsafeFileSystemRepresentation { pointer in
            times.withUnsafeBufferPointer { utimensat(AT_FDCWD, pointer!, $0.baseAddress!, AT_SYMLINK_NOFOLLOW) }
        })
    }

    private func writeXattr(_ path: URL, name: String, value: Data) throws {
        try check(path.withUnsafeFileSystemRepresentation { pointer in
            name.withCString { attribute in
                value.withUnsafeBytes { setxattr(pointer!, attribute, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
            }
        })
    }

    private func readXattr(_ path: URL, name: String) throws -> Data {
        try path.withUnsafeFileSystemRepresentation { pointer in
            try name.withCString { attribute in
                let size = getxattr(pointer!, attribute, nil, 0, 0, XATTR_NOFOLLOW)
                if size < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
                var data = Data(count: size)
                let count = data.withUnsafeMutableBytes { getxattr(pointer!, attribute, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
                if count < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
                data.count = count
                return data
            }
        }
    }

    private func cloneID(_ path: URL) throws -> UInt64? {
        var identifier: UInt64 = 0
        let code = path.withUnsafeFileSystemRepresentation { rift_clone_identifier($0!, &identifier) }
        if code == ENOTSUP || code == EINVAL { return nil }
        if code != 0 { throw POSIXError(POSIXErrorCode(rawValue: code)!) }
        return identifier
    }

    private func check(_ result: Int32) throws {
        if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
    }
}
