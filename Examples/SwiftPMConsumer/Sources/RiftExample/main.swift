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

        let manager = try RiftManager(databaseURL: database)
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
        print("Created and verified: \(workspace.path)")

        try await manager.remove(at: workspace, options: RemoveOptions(hooks: .skip))
        _ = try await manager.garbageCollect()
    }

    private enum ExampleError: Error {
        case unexpectedContents
        case unexpectedChildren
    }
}
