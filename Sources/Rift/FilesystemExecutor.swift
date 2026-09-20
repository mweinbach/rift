import Dispatch

/// Keeps blocking filesystem, registry-lock, and child-process work off Swift's
/// cooperative executor while preserving each manager's serial actor isolation.
final class FilesystemExecutor: SerialExecutor {
    private let queue: DispatchQueue

    init(queue: DispatchQueue = DispatchQueue(label: "rift.filesystem", qos: .utility)) {
        self.queue = queue
    }

    // UnownedJob supports macOS 13; ExecutorJob requires macOS 14.
    func enqueue(_ job: UnownedJob) {
        queue.async { [self] in
            job.runSynchronously(on: asUnownedSerialExecutor())
        }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }
}
