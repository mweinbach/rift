import Dispatch
import Foundation
import Testing
@testable import Rift

struct FilesystemExecutorTests {
    @Test func actorJobsRunOnTheDedicatedDispatchQueue() async {
        let queue = DispatchQueue(label: "rift.executor-test")
        let probe = FilesystemExecutorProbe(queue: queue)
        #expect(await probe.runsOffMainThread())
    }

    @Test @MainActor
    func openingFromMainActorAndConstructingAnotherManagerInProgress() async throws {
        let fixture = try RiftFixture()
        let databaseURL = fixture.databaseURL
        let source = fixture.source
        let manager = try await RiftManager.open(databaseURL: databaseURL)

        let outcome = try await manager.initialize(at: source) { _ in
            #expect(!Thread.isMainThread)
            do {
                let nested = try RiftManager(databaseURL: databaseURL)
                #expect(nested.databaseURL == databaseURL)
            } catch {
                Issue.record("Opening another manager from progress failed: \(error)")
            }
        }
        #expect(outcome == .registered)

        let reopened = try await RiftManager.open(databaseURL: databaseURL)
        #expect(try await reopened.workspace(at: source) == source)
    }
}

private actor FilesystemExecutorProbe {
    private nonisolated let executor: FilesystemExecutor
    private let queue: DispatchQueue

    init(queue: DispatchQueue) {
        self.queue = queue
        executor = FilesystemExecutor(queue: queue)
    }

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    func runsOffMainThread() -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return !Thread.isMainThread
    }
}
