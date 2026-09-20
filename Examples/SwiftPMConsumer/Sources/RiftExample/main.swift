import Foundation
import Rift

@main
struct RiftExample {
    static func main() async throws {
        let fileManager = FileManager.default
        let fixture = fileManager.temporaryDirectory
            .appendingPathComponent("rift-swift-example-\(UUID().uuidString)", isDirectory: true)
        let source = fixture.appendingPathComponent("source", isDirectory: true)
        let storage = fixture.appendingPathComponent("workspaces", isDirectory: true)
        let database = fixture.appendingPathComponent("registry.sqlite")

        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: fixture) }

        let contents = Data("Hello from Rift's SwiftPM consumer.\n".utf8)
        try contents.write(to: source.appendingPathComponent("hello.txt"))
        let artifacts = source.appendingPathComponent(".build", isDirectory: true)
        try fileManager.createDirectory(at: artifacts, withIntermediateDirectories: true)
        try Data("Regenerable SwiftPM build state".utf8).write(to: artifacts.appendingPathComponent("cache"))

        let manager = try await RiftManager.open(databaseURL: database)
        _ = try await manager.initialize(at: source)
        let workspace = try await manager.create(
            from: source,
            name: "example",
            into: storage,
            options: CreateOptions(hooks: .skip)
        )

        guard try Data(contentsOf: workspace.appendingPathComponent("hello.txt")) == contents else {
            throw ExampleError.unexpectedContents
        }
        guard try await manager.list(of: source) == [workspace] else {
            throw ExampleError.unexpectedChildren
        }
        guard !fileManager.fileExists(atPath: workspace.appendingPathComponent(".build").path) else {
            throw ExampleError.unexpectedArtifacts
        }
        let changed = Data("Changed only in the clone.\n".utf8)
        try changed.write(to: workspace.appendingPathComponent("hello.txt"))
        guard try Data(contentsOf: source.appendingPathComponent("hello.txt")) == contents else {
            throw ExampleError.sharedContents
        }

        try await manager.remove(at: workspace, options: RemoveOptions(hooks: .skip))
        guard !fileManager.fileExists(atPath: workspace.path),
              (try await manager.list(of: source)).isEmpty else {
            throw ExampleError.incompleteRemoval
        }
        let collected = try await manager.garbageCollect()
        guard collected.count == 1,
              collected.allSatisfy({ !fileManager.fileExists(atPath: $0.path) }),
              try Data(contentsOf: source.appendingPathComponent("hello.txt")) == contents else {
            throw ExampleError.incompleteCollection
        }
        print("Verified cloning, artifact filtering, mutation isolation, removal, and garbage collection.")
    }

    private enum ExampleError: Error {
        case unexpectedContents
        case unexpectedChildren
        case unexpectedArtifacts
        case sharedContents
        case incompleteRemoval
        case incompleteCollection
    }
}
