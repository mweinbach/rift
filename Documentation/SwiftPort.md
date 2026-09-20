# macOS Swift port

This fork's `main` and `rift-swift` branches package Rift's macOS workspace lifecycle as the importable `Rift` SwiftPM product. The root package uses Swift tools 6.0 and supports macOS 13 and later. Rust sources, CLI sources, JavaScript bindings, and existing release scripts remain available as upstream reference material; the Swift package does not build or load them.

## Public API

`RiftManager` is an actor that owns a SQLite registry. The asynchronous, throwing `open(databaseURL:)` factory performs filesystem and SQLite setup on a dispatch queue, avoiding blocking the caller. The synchronous, throwing initializer remains available. Calls to actor-isolated operations require `try await` from outside the actor and run on the manager's dedicated serial dispatch executor.

```swift
let manager = try await RiftManager.open(databaseURL: nil)

let outcome = try await manager.initialize(at: source)
let created = try await manager.create(
    from: source,
    name: "task",
    into: nil,
    options: CreateOptions(copyMode: .filtered, hooks: .run)
)
let workspace = try await manager.workspace(at: subdirectory)
let children = try await manager.list(of: source)
let parents = try await manager.ancestors(of: created)
try await manager.remove(at: created, options: RemoveOptions(hooks: .run))
let removed = try await manager.removeAll(at: source, options: RemoveOptions(hooks: .skip))
let collected = try await manager.garbageCollect()
```

| Operation | Result and behavior |
| --- | --- |
| `initialize(at:progress:)` | Registers exactly the selected directory; returns `InitializationOutcome.registered` or `.alreadyInitialized`. Repairs a missing marker when the path is already registered. |
| `create(from:name:into:options:)` | Finds the managed workspace containing `from`, clones it, and returns the new workspace URL. Records its immediate parent. |
| `workspace(at:)` | Returns the containing managed workspace's URL. |
| `list(of:)` | Returns direct active child workspace URLs. |
| `ancestors(of:)` | Returns parent workspace URLs, nearest first. |
| `remove(at:options:)` | Trashes a created workspace and its registered subtree, or unregisters a source root while preserving the source directory. |
| `removeAll(at:options:)` | Trashes descendants, preserves the selected workspace, and returns their original URLs. |
| `garbageCollect()` | Deletes registered trash, prunes missing active entries when they have no existing registered descendants, and returns the affected URLs. |

`CreateOptions` defaults to `copyMode: .filtered` and `hooks: .run`. `RemoveOptions` defaults to `hooks: .run`. Names and custom storage are optional; generated names are selected from available candidates. Initialization accepts an optional `@Sendable` progress callback with `.restoringMarker` and `.registeringWorkspace` events. Callbacks execute on the manager's executor while the operation lock is held; keep them nonblocking and dispatch UI updates to the main actor.

## Registry and markers

The default database is `~/Library/Application Support/rift/rift.sqlite`, matching the Rust implementation's macOS location. Each workspace contains a `.rift` marker with its identifier. The SQLite registry stores paths, parent relationships, and trash locations using the Rust registry's format.

Use `databaseURL:` for independent registries, including tests or tools that should maintain separate workspace graphs. A marker belongs to the registry in which it was created. Opening a directory with a different registry can produce an unknown-marker error; copying a marker manually to another directory can produce a marker-mismatch error. Marker validation rejects symbolic links and other nonregular marker entries.

Initialization targets exactly the supplied directory. It does not select a Git root or an existing ancestor workspace. Other operations canonicalize their supplied directory and search its ancestors for a marker. A registered ancestor with a missing marker is an error until initialization restores the marker at that ancestor.

Canonical paths use the kernel's stored filename spelling, so case aliases on case-insensitive APFS volumes preserve workspace identity and cannot bypass containment checks.

New managed roots and created workspaces must be physically disjoint from every active workspace and registered trash directory: neither path may contain the other. Initializing an already registered path can still restore its marker. A custom storage parent may contain managed directories when the selected destination is a disjoint sibling, but storage inside a managed or trash directory is rejected. Removal and collection also reject overlapping paths in older registries before changing those directories.

The actor serializes calls made through one manager instance. Its dedicated dispatch executor runs synchronous filesystem operations, lock waits, and hook processes without occupying Swift's cooperative executor threads. Swift managers sharing the resolved database path also coordinate operations through an advisory `<database>.operations.lock` file. The upstream Rust implementation does not participate in this Swift operation lock. Filesystem changes, database changes, and external hook processes are separate steps; they do not form one atomic transaction.

## APFS copying

The port uses macOS `clonefile` for copy-on-write cloning and has no ordinary-copy fallback. Cloning requires compatible source and destination locations on the same APFS volume. Cross-volume destinations and filesystems without cloning support cause an error. Initialization registers a directory in place; it does not convert its filesystem.

`.all` uses whole-tree cloning. `.filtered` clones included entries while excluding artifact components at any depth:

```text
.build  node_modules  .pnpm-store  target  .venv  venv  .tox  .nox
__pycache__  .pytest_cache  .mypy_cache  .ruff_cache
.next  .nuxt  .svelte-kit  .turbo  .vite  .parcel-cache  .cache
dist  build  coverage
```

Filtered mode also excludes `.yarn/cache`, `.yarn/unplugged`, `.yarn/install-state.gz`, and `.yarn/build-state.yml`. It preserves ordinary files, manifests, lockfiles, `.swiftpm` project configuration, and included symbolic links. Excluding `.build` is an intentional Swift-port extension to the upstream artifact filter, avoiding copies of SwiftPM checkouts and build caches. Filtered mode rejects special entries such as FIFOs; `.all` delegates the complete tree to native cloning, which can preserve those entries. `.all` is useful when artifact names are meaningful source content or a complete directory clone is required.

Metadata follows macOS cloning and destination ACL inheritance behavior. `.all` uses native `clonefile` permission handling, which clears setuid/setgid bits; `.filtered` restores full Unix mode bits on included regular files and directories.

Rift rejects a destination within the source workspace and an existing destination path. With `into: nil`, clones live in `<source-root-parent>/.rifts/<source-root-name>/<workspace-name>`. A custom `into:` replaces that storage parent. Creation prepares the clone in an adjacent private staging directory, then exclusively renames it into the final path before registry insertion. A failure during copying, preparation, publication, or registration attempts to remove the incomplete clone; a failed postcreate hook leaves a completed, registered workspace.

## Git workspaces

Git preparation uses `/usr/bin/git`. The new copy has detached `HEAD` and retains the source index and working-tree contents. Rift hides its marker through Git's local exclude configuration.

Rift checks Git layout before cloning. A source that is itself a linked worktree, and other Git layouts that reference state outside the source directory, cannot be treated as independent copies and are rejected. A source that owns linked worktrees is accepted: their `.git/worktrees` entries point at the original checkouts, so the staged copy drops them before it is published and the source's worktrees stay registered with the source alone. Git checks can also reject unsafe symlinked or external administrative paths, repository redirection, and unsupported reference storage. A malformed or unresolved `HEAD` is rejected; an unborn repository is allowed because it has no commit to detach. Initialization and creation can throw before filesystem copying when the Git layout is unsupported.

Supported repositories use the `files` reference backend and independent object storage. Rift rejects explicit `core.worktree` settings, nonempty object alternates, bare administrative metadata, reftable storage, and linked-worktree metadata that is not a directory inside the source. These restrictions prevent copied Git commands from reading or modifying the original workspace.

Directory cloning is not atomic, so a Git process writing the source can leave a copy without some objects. `index.lock`, `HEAD.lock`, `packed-refs.lock`, `gc.pid` and `objects/maintenance.lock` throw `RiftError.gitBusy` when they are present before the copy, inside the staged copy, or in the source afterwards; the staged copy is discarded. These states are short-lived, so callers can retry. Validating a live source tolerates loose objects and ref locks that vanish during the walk; the staged copy is validated again without that allowance. A stale lock left by a crashed Git process keeps reporting `gitBusy` until it is removed.

## Lifecycle hooks

The port reads version 1 `.rift.toml` configuration with the pure Swift `TOMLDecoder` dependency, pinned to version 0.4.5. The supported lifecycle arrays are `hooks.precreate`, `hooks.postcreate`, `hooks.preremove`, and `hooks.postremove`; each step supplies a nonempty `run` command. Unknown configuration fields, unsupported versions, and commands containing a NUL character are rejected. Steps execute in configuration order through `/bin/sh -c`, inheriting the process environment and standard streams.

```toml
version = 1

[[hooks.precreate]]
run = "swift build"

[[hooks.postcreate]]
run = "echo $RIFT_ID"
```

Each hook receives:

| Environment variable | Value |
| --- | --- |
| `RIFT_SOURCE` | Source workspace path for creation; original selected workspace path for removal. |
| `RIFT_DESTINATION` | Planned or created clone path; trash path for a trashed selected workspace; selected path when preserved. |
| `RIFT_ID` | Identifier of the new or selected workspace. |
| `RIFT_PARENT_ID` | Immediate parent identifier; the source root's own identifier when it has no parent. |

Precreate hooks run in the source before copying. After precreate hooks complete, Rift revalidates the source's identity and registry record, Git layout, and storage parent before cloning. Postcreate hooks run in the destination after its marker, Git preparation, and registry insertion complete. A failed precreate hook stops creation; a failed postcreate hook throws while leaving the new workspace registered.

Preremove hooks run in the selected workspace before removal, followed by revalidation of its identity and registry record. When removing a created workspace, postremove hooks run in its moved trash directory. When unregistering a source root or removing only descendants, postremove hooks run in the preserved selected directory. Hooks come from the selected workspace, not separately from every descendant. A failed preremove hook prevents removal; a failed postremove hook throws after removal has completed.

`hooks: .skip` skips configuration loading as well as hook execution. Hook commands can run any shell action available to the host process, so applications may use `.skip` when operating on directories whose configuration they do not intend to execute. Rift waits for each hook and does not provide a hook timeout or cancellation API. It temporarily releases the operation file lock during hooks so another Swift manager can operate on the same registry, while calls through the current manager remain serialized.

## Removal and garbage collection

Removing a created workspace verifies markers and real directory paths for its registered active subtree, then moves each workspace into adjacent `.trash/<id>-<name>` storage. Missing registered paths prevent subtree removal. A failed move or registry update attempts to roll back moves already performed.

Removing a source root preserves that directory, removes its marker, and trashes existing registered descendants. Missing descendant registry entries are removed as part of unregistering the root. If updating the registry fails, Rift attempts to restore the source marker and move descendants back. Unlike the Rust CLI, the Swift library has no force flag or interactive prompt: calling `remove(at:)` supplies the operation directly.

Root unregistration publishes descendant trash and root deletion in one SQLite transaction. A failed filesystem recovery throws `rollbackFailed` with the original and recovery errors rather than hiding the incomplete rollback.

`removeAll(at:)` preserves the selected workspace and removes only its descendants. `garbageCollect()` verifies each existing trash directory's marker before permanently deleting it, then prunes missing active entries when no existing registered descendants remain. Permission and other metadata-reading failures propagate rather than being treated as missing directories. Deletion makes owned directories writable and searchable and clears immutable flags as needed. It keeps the root marker until the remaining contents have been removed and attempts to restore it if final directory removal fails, preserving identity for a retry when possible. Collection can make partial progress before an error; callers can retry it.

## Errors and scope

All registry and workspace operations throw. Typed Rift failures use `RiftError`; some Foundation filesystem errors also propagate directly. Errors cover invalid paths and names, unavailable cloning, uninitialized workspaces, missing or mismatched markers, unknown registry entries, existing destinations, overlapping managed paths, unsafe Git layouts, Git sources that are busy, unsupported filesystem entries, invalid hook configuration, failing hooks, filesystem failures, and SQLite failures. Cyclic parent relationships in an invalid registry are rejected rather than traversed indefinitely. A post-hook error describes an operation whose primary change has already completed; query the registry before deciding to retry creation or removal.

The Swift port focuses on macOS library use. It does not expose the Rust CLI, shell integration, JavaScript/FFI binding, Linux btrfs or reflink strategies, Windows support, or Rust benchmark executables. Its initialization progress callback reports macOS registration and marker restoration rather than Linux conversion stages, and its initialization outcome has no Linux-only `converted` case.

Creation stages the clone before publishing its final path, Swift managers coordinate through an operation lock, and trash collection performs an additional marker check. These are Swift implementation changes from the upstream Rust flow. The registry and workspace lifecycle remain the compatibility boundary; matching core behavior does not imply identical internal sequencing or error messages.

This branch retains Rust files and release workflows for reference. Swift tests and the Swift CI workflow validate the Swift target; Rust release scripts and npm packages do not distribute the Swift product. The consuming application's own package manifest controls its dependency on the experimental branch.

## Verification and performance

Run the package and consumer checks on macOS:

```sh
swift test
swift build -c release
swift build --package-path Examples/SwiftPMConsumer
swift run --package-path Examples/SwiftPMConsumer RiftExample
```

The consumer smoke uses a newly created temporary directory and separate SQLite registry. It registers a source, clones it, verifies the cloned contents, parent listing, `.build` exclusion, and mutation isolation, removes the clone, verifies trash collection, and cleans up its fixture. It does not initialize or clone a user project.

Successful tests and builds validate the behaviors exercised by those checks. They do not establish parity across every filesystem, Git layout, hook script, concurrent process, or preexisting registry. Swift-port creation latency and storage behavior have not been benchmarked, and upstream Rust timing claims do not serve as Swift measurements.
