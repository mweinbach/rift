# Rift for Swift

Rift creates independent working copies of a directory using macOS APFS copy-on-write clones. This fork's `main` branch provides this functionality as a Swift Package Manager library, with workspace registration, parent tracking, lifecycle hooks, deferred removal, and garbage collection. The `rift-swift` branch also contains the Swift port.

This port is experimental. Its API and implementation may change, and Swift-port performance has not been benchmarked. The original Rust implementation remains in `crates/` as an upstream reference.

## Requirements

- macOS 13 or later and Swift 6.0 or later.
- Source and destination directories on the same APFS volume for `clonefile`.
- `/usr/bin/git` available when managing a Git repository.

The package exports the `Rift` library. It uses native macOS cloning and SQLite, with a pure Swift TOML decoder for hook configuration. It does not require a Rust build, a JavaScript runtime, or the Rift CLI.

## Add the package

Add the dependency on `main` and library product to your `Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyTool",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/mweinbach/rift.git", branch: "main")
    ],
    targets: [
        .executableTarget(
            name: "MyTool",
            dependencies: [.product(name: "Rift", package: "rift")]
        )
    ]
)
```

## Use Rift

`RiftManager` is an actor. Open its registry asynchronously and call its operations with `try await` from outside the actor:

```swift
import Foundation
import Rift

let manager = try await RiftManager.open()
let source = URL(fileURLWithPath: "/Users/me/code/app", isDirectory: true)

let outcome = try await manager.initialize(at: source)
let workspace = try await manager.create(from: source, name: "parser-fix")
print(workspace.path)

let children = try await manager.list(of: source)
let parents = try await manager.ancestors(of: workspace)

// Move the created workspace and its descendants into Rift's trash.
try await manager.remove(at: workspace)

// Physically delete registered trash and prune missing registry entries.
let collected = try await manager.garbageCollect()
```

`initialize(at:)` registers exactly the supplied directory and returns `.registered` or `.alreadyInitialized`. Other workspace operations accept a directory inside a managed workspace and search upward for its `.rift` marker. Initialization restores a missing marker for a directory already present in the selected registry.

The default registry is `~/Library/Application Support/rift/rift.sqlite`. Pass `databaseURL:` to `RiftManager` to use an isolated registry:

```swift
let manager = try await RiftManager.open(databaseURL: customDatabaseURL)
let workspace = try await manager.create(
    from: source,
    name: "full-copy",
    into: storageDirectory,
    options: CreateOptions(copyMode: .all, hooks: .skip)
)
```

Creation defaults to `.filtered`, excluding regenerable dependency and build artifacts such as SwiftPM `.build`, `node_modules`, `target`, virtualenvs, `dist`, `build`, and `coverage`. Manifests, lockfiles, and `.swiftpm` project configuration remain included. `.all` clones the complete tree. Git copies detach `HEAD` while retaining the index and working-tree contents.

Managed directories must be disjoint: Rift rejects nested managed roots and workspace storage inside an existing managed or trash directory. The actor uses a dedicated serial dispatch queue for blocking filesystem and hook work. The synchronous `RiftManager(databaseURL:)` initializer remains available, but filesystem and SQLite setup can block its caller; prefer `open()` in applications.

Default created-workspace storage is adjacent to the registered source root:

```text
~/code/app/                         source workspace
~/code/.rifts/app/parser-fix/       created workspace
~/code/.rifts/app/.trash/            removed workspace storage
```

`remove(at:)` on a source root unregisters it, removes its `.rift` marker, and trashes its registered descendants; the source directory remains. `removeAll(at:)` trashes descendants while preserving the selected workspace. Removal is deferred until `garbageCollect()` deletes the trash.

## Hooks

Create and remove operations run `.rift.toml` hooks by default. Configure version 1 hooks in the managed workspace:

```toml
version = 1

[[hooks.precreate]]
run = "swift build"

[[hooks.postcreate]]
run = "echo created $RIFT_DESTINATION"

[[hooks.preremove]]
run = "echo removing $RIFT_SOURCE"

[[hooks.postremove]]
run = "echo removed $RIFT_SOURCE"
```

Precreate hooks run in the source; postcreate hooks run in the newly registered workspace. A precreate failure prevents cloning. A postcreate failure throws after creation, leaving the workspace registered. Remove hooks follow the same pre/post ordering; a postremove failure leaves removal completed. Pass `hooks: .skip` through `CreateOptions` or `RemoveOptions` to skip loading and running hooks.

See [the Swift port documentation](Documentation/SwiftPort.md) for operation semantics, filesystem and Git constraints, error behavior, and differences from the Rust distribution.

## Development

```sh
swift test
swift build -c release
swift run --package-path Examples/SwiftPMConsumer RiftExample
```

The consumer example registers and clones its own temporary fixture with a separate SQLite registry, then cleans it up. CI runs package tests, a release build, and the consumer smoke on macOS. Those checks verify the exercised behavior; they do not establish Swift-port performance or parity on every workload.

## License

MIT
