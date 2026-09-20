import Foundation
import Darwin

/// Coordinates filesystem changes and registry updates across Swift manager instances.
internal final class OperationLock: @unchecked Sendable {
    private let descriptor: Int32
    private let path: URL
    private let localLock = NSLock()

    init(databaseURL: URL) throws {
        path = URL(fileURLWithPath: databaseURL.path + ".operations.lock")
        descriptor = Darwin.open(path.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else {
            throw RiftError.io(operation: "open operation lock", path: path, code: errno)
        }
    }

    deinit { Darwin.close(descriptor) }

    func withLock<T>(_ body: () throws -> T) throws -> T {
        localLock.lock()
        defer { localLock.unlock() }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno != EINTR {
                throw RiftError.io(operation: "lock registry operations", path: path, code: errno)
            }
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    /// Hook processes may use another manager against this database. Keep this
    /// instance serialized, but let those processes acquire the file lock.
    func withoutFileLock<T>(_ body: () throws -> T) throws -> T {
        guard flock(descriptor, LOCK_UN) == 0 else {
            throw RiftError.io(operation: "unlock for hooks", path: path, code: errno)
        }
        let result = Result(catching: body)
        while flock(descriptor, LOCK_EX) != 0 {
            if errno != EINTR {
                throw RiftError.io(operation: "relock after hooks", path: path, code: errno)
            }
        }
        return try result.get()
    }
}
