import Foundation
import Testing
import Rift

@Suite("macOS Rift manager integration")
struct RiftManagerTests {
    @Test("Initialization registers exactly the selected directory and survives reopening")
    func initializeAndReopen() async throws {
        let fixture = try RiftFixture()
        let nested = fixture.source.appendingPathComponent("packages/app")
        try fixture.mkdir(nested)
        let manager = try fixture.manager()

        let first = try await manager.initialize(at: nested)
        #expect(first == .registered)
        #expect(fixture.exists(nested.appendingPathComponent(".rift")))
        #expect(!fixture.exists(fixture.source.appendingPathComponent(".rift")))
        let initialChildren = try await manager.list(of: nested)
        #expect(initialChildren.isEmpty)

        let reopened = try fixture.manager()
        let second = try await reopened.initialize(at: nested)
        #expect(second == .alreadyInitialized)
        let resolved = try await reopened.workspace(at: nested)
        #expect(resolved.path == nested.path)
    }

    @Test("Production APFS copies preserve bytes and isolate subsequent mutations")
    func copyIsIndependent() async throws {
        let fixture = try RiftFixture()
        let manager = try fixture.manager()
        _ = try await manager.initialize(at: fixture.source)
        let first = try await manager.create(from: fixture.source, name: "first")

        #expect(first.path == fixture.child("first").path)
        #expect(try fixture.read(first.appendingPathComponent("file.txt")) == "hello")
        #expect(try fixture.marker(first) != fixture.marker(fixture.source))
        try fixture.write("child changed", to: first.appendingPathComponent("file.txt"))
        #expect(try fixture.read(fixture.source.appendingPathComponent("file.txt")) == "hello")
        try fixture.write("source changed", to: fixture.source.appendingPathComponent("file.txt"))
        #expect(try fixture.read(first.appendingPathComponent("file.txt")) == "child changed")
    }

    @Test("Direct children, ancestor order, and default storage follow the original root")
    func parentageAndNearestMarker() async throws {
        let fixture = try RiftFixture()
        let manager = try fixture.manager()
        let nested = fixture.source.appendingPathComponent("packages/app")
        try fixture.mkdir(nested)
        _ = try await manager.initialize(at: fixture.source)
        let first = try await manager.create(from: nested, name: "first")
        let second = try await manager.create(from: first, name: "second")
        let deep = second.appendingPathComponent("deep")
        try fixture.mkdir(deep)

        #expect(second.path == fixture.child("second").path)
        #expect(fixture.exists(first.appendingPathComponent("file.txt")))
        let rootChildren = try await manager.list(of: nested)
        let firstChildren = try await manager.list(of: first)
        let ancestors = try await manager.ancestors(of: deep)
        let workspace = try await manager.workspace(at: deep)
        #expect(rootChildren.map(\.path) == [first.path])
        #expect(firstChildren.map(\.path) == [second.path])
        #expect(ancestors.map(\.path) == [first.path, fixture.source.path])
        #expect(workspace.path == second.path)
        let collected = try await manager.garbageCollect()
        #expect(collected.isEmpty)
        #expect(fixture.exists(first) && fixture.exists(second))
    }

    @Test("Create requires explicit initialization")
    func uninitializedSource() async throws {
        let fixture = try RiftFixture()
        let manager = try fixture.manager()
        await expectRiftError(matching: {
            if case .workspaceNotInitialized(let path) = $0 { return path.path == fixture.source.path }
            return false
        }, performing: {
            try await manager.create(from: fixture.source, name: "unsafe")
        })
        #expect(!fixture.exists(fixture.source.appendingPathComponent(".rift")))
        #expect(!fixture.exists(fixture.child("unsafe")))
    }

    @Test("Initialization restores a missing marker without changing identity")
    func restoreMissingMarker() async throws {
        let fixture = try RiftFixture()
        let manager = try fixture.manager()
        let nested = fixture.source.appendingPathComponent("nested")
        try fixture.mkdir(nested)
        _ = try await manager.initialize(at: fixture.source)
        let original = try fixture.marker(fixture.source)
        try fixture.delete(fixture.source.appendingPathComponent(".rift"))

        await expectRiftError(matching: {
            if case .missingMarker(let path) = $0 { return path.path == fixture.source.path }
            return false
        }, performing: { try await manager.list(of: nested) })
        _ = try await manager.initialize(at: fixture.source)
        #expect(try fixture.marker(fixture.source) == original)
        let children = try await manager.list(of: nested)
        #expect(children.isEmpty)
    }

    @Test("Unknown and relocated marker identities fail without altering workspaces")
    func rejectUnknownAndMismatchedMarkers() async throws {
        let fixture = try RiftFixture()
        let manager = try fixture.manager()
        _ = try await manager.initialize(at: fixture.source)
        let original = try fixture.marker(fixture.source)
        try fixture.write("unknown\n", to: fixture.source.appendingPathComponent(".rift"))
        await expectRiftError(matching: {
            if case .unknownMarker(let path) = $0 { return path.path == fixture.source.path }
            return false
        }, performing: { try await manager.list(of: fixture.source) })
        try fixture.write(original + "\n", to: fixture.source.appendingPathComponent(".rift"))

        let other = fixture.path("other")
        try fixture.mkdir(other)
        try fixture.write(original + "\n", to: other.appendingPathComponent(".rift"))
        await expectRiftError(matching: {
            if case .markerMismatch(let path) = $0 { return path.path == other.path }
            return false
        }, performing: { try await manager.list(of: other) })
        await expectRiftError(matching: {
            if case .markerMismatch(let path) = $0 { return path.path == other.path }
            return false
        }, performing: { try await manager.initialize(at: other) })
        #expect(try fixture.read(fixture.source.appendingPathComponent("file.txt")) == "hello")
    }

    @Test("Filtered and exact copies differ only for regenerable artifacts")
    func filteredAndCopyAll() async throws {
        let fixture = try RiftFixture()
        let files = [
            "node_modules/pkg/index.js": "module",
            "target/debug/app": "binary",
            ".yarn/cache/pkg.zip": "cache",
            "dist/generated.js": "generated",
            "coverage/report.txt": "report",
            "package.json": "{}",
            "Cargo.lock": "lock",
            "src/main.swift": "print(42)",
        ]
        for (relative, contents) in files {
            try fixture.write(contents, to: fixture.source.appendingPathComponent(relative))
        }
        let manager = try fixture.manager()
        _ = try await manager.initialize(at: fixture.source)
        let filtered = try await manager.create(from: fixture.source, name: "filtered")
        let exact = try await manager.create(
            from: fixture.source, name: "exact", options: CreateOptions(copyMode: .all)
        )

        for relative in ["node_modules", "target", ".yarn/cache", "dist", "coverage"] {
            #expect(!fixture.exists(filtered.appendingPathComponent(relative)))
            #expect(fixture.exists(exact.appendingPathComponent(relative)))
        }
        for relative in ["package.json", "Cargo.lock", "src/main.swift"] {
            #expect(try fixture.read(filtered.appendingPathComponent(relative)) == files[relative])
            #expect(try fixture.read(exact.appendingPathComponent(relative)) == files[relative])
        }
    }

    @Test("Custom storage is canonical and duplicate destinations preserve existing data")
    func customStorageAndDuplicates() async throws {
        let fixture = try RiftFixture()
        let manager = try fixture.manager()
        _ = try await manager.initialize(at: fixture.source)
        let custom = fixture.path("custom")
        let child = try await manager.create(from: fixture.source, name: "task", into: custom)
        #expect(child.path == custom.appendingPathComponent("task").path)
        try fixture.write("keep", to: child.appendingPathComponent("file.txt"))
        await expectRiftError(matching: {
            if case .alreadyExists(let path) = $0 { return path.path == child.path }
            return false
        }, performing: { try await manager.create(from: fixture.source, name: "task", into: custom) })
        #expect(try fixture.read(child.appendingPathComponent("file.txt")) == "keep")
    }

    @Test("Recursive storage is rejected through both direct paths and symlinks")
    func rejectRecursiveStorage() async throws {
        let fixture = try RiftFixture()
        let manager = try fixture.manager()
        _ = try await manager.initialize(at: fixture.source)
        let direct = fixture.source.appendingPathComponent("nested")
        await expectRiftError(matching: {
            if case .insideSource = $0 { return true }
            return false
        }, performing: { try await manager.create(from: fixture.source, name: "inside", into: direct) })

        let link = fixture.path("source-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.source)
        await expectRiftError(matching: {
            if case .insideSource = $0 { return true }
            return false
        }, performing: { try await manager.create(from: fixture.source, name: "via-link", into: link) })
        #expect(!fixture.exists(fixture.source.appendingPathComponent("inside")))
        #expect(!fixture.exists(fixture.source.appendingPathComponent("via-link")))
        let children = try await manager.list(of: fixture.source)
        #expect(children.isEmpty)
    }

    @Test("Names are visible single path segments", arguments: ["", ".", "..", "/", "parent/child", "child/", ".trash", ".hidden"])
    func rejectInvalidName(_ name: String) async throws {
        let fixture = try RiftFixture()
        let manager = try fixture.manager()
        _ = try await manager.initialize(at: fixture.source)
        await expectRiftError(matching: {
            if case .invalidPath = $0 { return true }
            return false
        }, performing: { try await manager.create(from: fixture.source, name: name) })
        let children = try await manager.list(of: fixture.source)
        #expect(children.isEmpty)
    }

    @Test("Generated names are readable and distinct from workspace identities")
    func generatedNames() async throws {
        let fixture = try RiftFixture()
        let manager = try fixture.manager()
        _ = try await manager.initialize(at: fixture.source)
        let first = try await manager.create(from: fixture.source)
        let second = try await manager.create(from: fixture.source)
        #expect(first.path != second.path)
        for child in [first, second] {
            let parts = child.lastPathComponent.split(separator: "-")
            #expect(parts.count == 2)
            #expect(parts.allSatisfy { $0.allSatisfy { $0.isASCII && $0.isLowercase } })
            #expect(child.lastPathComponent != (try fixture.marker(child)))
        }
    }

    @Test("Generated names skip all existing directories and report exhaustion")
    func generatedNameCollisionsAndExhaustion() async throws {
        let fixture = try RiftFixture()
        let manager = try fixture.manager()
        _ = try await manager.initialize(at: fixture.source)
        // This fixed vocabulary is an upstream naming contract, independently enumerated here.
        let adjectives = "amber bold brisk calm cedar clear cobalt coral dawn ember gentle golden jade lively lunar mellow misty noble quiet rapid river silver solar spruce steady swift tidal verdant violet warm wild winter".split(separator: " ")
        let nouns = "badger brook canyon cedar comet dune falcon field forest harbor heron island lantern maple meadow mesa otter peak pine reef ridge robin sparrow summit thicket trail valley willow wren yarrow zephyr fox".split(separator: " ")
        let available = "amber-badger"
        for adjective in adjectives {
            for noun in nouns {
                let name = "\(adjective)-\(noun)"
                if name != available { try fixture.mkdir(fixture.child(name)) }
            }
        }
        let created = try await manager.create(from: fixture.source)
        #expect(created.path == fixture.child(available).path)
        await expectRiftError(matching: {
            if case .namesExhausted(let path) = $0 { return path.path == fixture.path(".rifts/app").path }
            return false
        }, performing: { try await manager.create(from: fixture.source) })
        #expect(try fixture.read(created.appendingPathComponent("file.txt")) == "hello")
    }

    @Test("Independent managers competing for one destination preserve the successful workspace")
    func concurrentManagersPreserveWinner() async throws {
        let fixture = try RiftFixture()
        let first = try fixture.manager()
        _ = try await first.initialize(at: fixture.source)
        let second = try fixture.manager()
        let source = fixture.source
        let storage = fixture.path("race-storage")
        async let one = creationAttempt(manager: first, source: source, storage: storage, name: "race")
        async let two = creationAttempt(manager: second, source: source, storage: storage, name: "race")
        let attempts = await [one, two]
        var successes: [URL] = []
        var collisions: [URL] = []
        for attempt in attempts {
            switch attempt {
            case .created(let path): successes.append(path)
            case .failed(.alreadyExists(let path)): collisions.append(path)
            case .failed(let error): Issue.record("Unexpected competing create error: \(error)")
            case .unexpectedFailure(let error): Issue.record("Unexpected competing create error: \(error)")
            }
        }
        let destination = storage.appendingPathComponent("race")
        #expect(successes.map(\.path) == [destination.path])
        #expect(collisions.map(\.path) == [destination.path])
        #expect(try fixture.read(destination.appendingPathComponent("file.txt")) == "hello")
        let children = try await first.list(of: source)
        #expect(children.map(\.path) == [destination.path])
        let ancestors = try await second.ancestors(of: destination)
        #expect(ancestors.map(\.path) == [source.path])
        let storageEntries = try FileManager.default.contentsOfDirectory(atPath: storage.path)
        #expect(storageEntries == ["race"])
    }

    @Test("Database symlink aliases resolve to the same canonical manager database")
    func canonicalDatabaseAliases() async throws {
        let fixture = try RiftFixture()
        let first = try fixture.manager()
        _ = try await first.initialize(at: fixture.source)
        let alias = fixture.path("registry-alias.sqlite")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.databaseURL)
        let second = try RiftManager(databaseURL: alias)
        #expect(first.databaseURL.path == second.databaseURL.path)
        #expect(second.databaseURL.path == fixture.databaseURL.path)
        let outcome = try await second.initialize(at: fixture.source)
        #expect(outcome == .alreadyInitialized)
        let child = try await second.create(from: fixture.source, name: "aliased")
        let children = try await first.list(of: fixture.source)
        #expect(children.map(\.path) == [child.path])
    }

    @Test("Marker symlinks are rejected without changing the linked file")
    func rejectSourceMarkerSymlink() async throws {
        let fixture = try RiftFixture()
        let external = fixture.path("external-marker.txt")
        try fixture.write("external sentinel\n", to: external)
        try FileManager.default.createSymbolicLink(
            at: fixture.source.appendingPathComponent(".rift"), withDestinationURL: external
        )
        let manager = try fixture.manager()
        await expectRiftError(matching: {
            if case .markerMismatch(let path) = $0 { return path.path == fixture.source.path }
            return false
        }, performing: { try await manager.initialize(at: fixture.source) })
        #expect(try fixture.read(external) == "external sentinel\n")
        #expect(try fixture.read(fixture.source.appendingPathComponent("file.txt")) == "hello")
    }

    @Test("Created marker replacement breaks cloned hard links without changing source identity", arguments: [CopyMode.filtered, .all])
    func markerHardlinkIsolation(_ mode: CopyMode) async throws {
        let fixture = try RiftFixture()
        let manager = try fixture.manager()
        _ = try await manager.initialize(at: fixture.source)
        let original = try fixture.read(fixture.source.appendingPathComponent(".rift"))
        let alias = fixture.source.appendingPathComponent("marker-alias.txt")
        try FileManager.default.linkItem(at: fixture.source.appendingPathComponent(".rift"), to: alias)
        let child = try await manager.create(from: fixture.source, name: "hardlink", options: CreateOptions(copyMode: mode))
        #expect(try fixture.read(fixture.source.appendingPathComponent(".rift")) == original)
        #expect(try fixture.read(alias) == original)
        #expect(try fixture.read(child.appendingPathComponent("marker-alias.txt")) == original)
        #expect(try fixture.marker(child) != fixture.marker(fixture.source))
    }

    @Test("Removing a child trashes the whole subtree, and GC deletes only that trash")
    func trashSubtreeAndCollect() async throws {
        let fixture = try RiftFixture()
        let manager = try fixture.manager()
        _ = try await manager.initialize(at: fixture.source)
        let first = try await manager.create(from: fixture.source, name: "first")
        let second = try await manager.create(from: first, name: "second")
        let sibling = try await manager.create(from: fixture.source, name: "sibling")
        let firstTrash = try fixture.trash(for: first)
        let secondTrash = try fixture.trash(for: second)

        try await manager.remove(at: first)
        #expect(!fixture.exists(first) && !fixture.exists(second))
        #expect(fixture.exists(firstTrash) && fixture.exists(secondTrash))
        let children = try await manager.list(of: fixture.source)
        #expect(children.map(\.path) == [sibling.path])
        let collected = try await manager.garbageCollect()
        #expect(Set(collected.map(\.path)) == Set([firstTrash.path, secondTrash.path]))
        #expect(!fixture.exists(firstTrash) && !fixture.exists(secondTrash))
        #expect(fixture.exists(sibling) && fixture.exists(fixture.source))
        let repeated = try await manager.garbageCollect()
        #expect(repeated.isEmpty)
    }

    @Test("Removing a source root preserves its files and tolerates missing descendants")
    func unregisterRootPreservesData() async throws {
        let fixture = try RiftFixture()
        let manager = try fixture.manager()
        _ = try await manager.initialize(at: fixture.source)
        let missing = try await manager.create(from: fixture.source, name: "missing")
        let existing = try await manager.create(from: missing, name: "existing")
        let existingTrash = try fixture.trash(for: existing)
        try fixture.delete(missing)

        try await manager.remove(at: fixture.source)
        #expect(try fixture.read(fixture.source.appendingPathComponent("file.txt")) == "hello")
        #expect(!fixture.exists(fixture.source.appendingPathComponent(".rift")))
        #expect(!fixture.exists(existing))
        #expect(fixture.exists(existingTrash))
        await expectRiftError(matching: {
            if case .workspaceNotInitialized = $0 { return true }
            return false
        }, performing: { try await manager.list(of: fixture.source) })
        let collected = try await manager.garbageCollect()
        #expect(collected.map(\.path) == [existingTrash.path])
        #expect(fixture.exists(fixture.source))
    }

    @Test("Remove all preserves the selected nested workspace and unrelated siblings")
    func removeAllPreservesSelection() async throws {
        let fixture = try RiftFixture()
        let manager = try fixture.manager()
        _ = try await manager.initialize(at: fixture.source)
        let selected = try await manager.create(from: fixture.source, name: "selected")
        let child = try await manager.create(from: selected, name: "child")
        let grandchild = try await manager.create(from: child, name: "grandchild")
        let sibling = try await manager.create(from: fixture.source, name: "sibling")
        let selectedMarker = try fixture.marker(selected)

        let removed = try await manager.removeAll(at: selected)
        #expect(removed.map(\.path) == [grandchild.path, child.path])
        #expect(fixture.exists(selected) && fixture.exists(sibling))
        #expect(try fixture.marker(selected) == selectedMarker)
        let selectedChildren = try await manager.list(of: selected)
        let rootChildren = try await manager.list(of: fixture.source)
        #expect(selectedChildren.isEmpty)
        #expect(Set(rootChildren.map(\.path)) == Set([selected.path, sibling.path]))
    }

    @Test("Subtree removal validates missing paths before moving any workspace")
    func missingDescendantBlocksRemoval() async throws {
        let fixture = try RiftFixture()
        let manager = try fixture.manager()
        _ = try await manager.initialize(at: fixture.source)
        let first = try await manager.create(from: fixture.source, name: "first")
        let second = try await manager.create(from: first, name: "second")
        let moved = fixture.path("moved")
        try fixture.move(second, to: moved)
        await expectRiftError(matching: {
            if case .missingRift(let path) = $0 { return path.path == second.path }
            return false
        }, performing: { try await manager.remove(at: first) })
        #expect(fixture.exists(first) && fixture.exists(moved))
        let children = try await manager.list(of: fixture.source)
        #expect(children.map(\.path) == [first.path])
    }

    @Test("Removal refuses forged markers and preexisting trash destinations")
    func removalValidatesIdentityAndTrash() async throws {
        let fixture = try RiftFixture()
        let manager = try fixture.manager()
        _ = try await manager.initialize(at: fixture.source)
        let child = try await manager.create(from: fixture.source, name: "child")
        let identity = try fixture.marker(child)
        let trash = try fixture.trash(for: child)
        try fixture.write((try fixture.marker(fixture.source)) + "\n", to: child.appendingPathComponent(".rift"))
        await expectRiftError(matching: {
            if case .markerMismatch(let path) = $0 { return path.path == child.path }
            return false
        }, performing: { try await manager.remove(at: child) })
        #expect(fixture.exists(child))
        try fixture.write(identity + "\n", to: child.appendingPathComponent(".rift"))
        try fixture.write("keep", to: trash.appendingPathComponent("sentinel.txt"))
        await expectRiftError(matching: {
            if case .alreadyExists(let path) = $0 { return path.path == trash.path }
            return false
        }, performing: { try await manager.remove(at: child) })
        #expect(fixture.exists(child))
        #expect(try fixture.read(trash.appendingPathComponent("sentinel.txt")) == "keep")
    }

    @Test("GC preserves missing active parents until their surviving descendants disappear")
    func collectProtectsOrphans() async throws {
        let fixture = try RiftFixture()
        let manager = try fixture.manager()
        _ = try await manager.initialize(at: fixture.source)
        let first = try await manager.create(from: fixture.source, name: "first")
        let second = try await manager.create(from: first, name: "second")
        try fixture.delete(first)

        let protected = try await manager.garbageCollect()
        let children = try await manager.list(of: fixture.source)
        let ancestors = try await manager.ancestors(of: second)
        #expect(protected.isEmpty)
        #expect(children.map(\.path) == [first.path])
        #expect(ancestors.map(\.path) == [first.path, fixture.source.path])

        try fixture.delete(second)
        let collected = try await manager.garbageCollect()
        #expect(Set(collected.map(\.path)) == Set([first.path, second.path]))
        let remaining = try await manager.list(of: fixture.source)
        #expect(remaining.isEmpty)
    }

    @Test("GC forgets trash already deleted outside Rift")
    func collectMissingTrash() async throws {
        let fixture = try RiftFixture()
        let manager = try fixture.manager()
        _ = try await manager.initialize(at: fixture.source)
        let child = try await manager.create(from: fixture.source, name: "child")
        let trash = try fixture.trash(for: child)
        try await manager.remove(at: child)
        try fixture.delete(trash)
        let collected = try await manager.garbageCollect()
        #expect(collected.map(\.path) == [trash.path])
        let repeated = try await manager.garbageCollect()
        #expect(repeated.isEmpty)
    }

    @Test("GC rejects substituted trash markers and retains the directory until repaired")
    func collectValidatesTrashIdentity() async throws {
        let fixture = try RiftFixture()
        let manager = try fixture.manager()
        _ = try await manager.initialize(at: fixture.source)
        let child = try await manager.create(from: fixture.source, name: "child")
        let identity = try fixture.marker(child)
        let trash = try fixture.trash(for: child)
        try await manager.remove(at: child)
        try fixture.write((try fixture.marker(fixture.source)) + "\n", to: trash.appendingPathComponent(".rift"))
        await expectRiftError(matching: {
            if case .markerMismatch(let path) = $0 { return path.path == trash.path }
            return false
        }, performing: { try await manager.garbageCollect() })
        #expect(try fixture.read(trash.appendingPathComponent("file.txt")) == "hello")
        #expect(fixture.exists(fixture.source))
        try fixture.write(identity + "\n", to: trash.appendingPathComponent(".rift"))
        let collected = try await manager.garbageCollect()
        #expect(collected.map(\.path) == [trash.path])
    }

    @Test("GC refuses a trash path replaced with a symlink to unrelated data")
    func collectRejectsTrashSymlink() async throws {
        let fixture = try RiftFixture()
        let manager = try fixture.manager()
        _ = try await manager.initialize(at: fixture.source)
        let child = try await manager.create(from: fixture.source, name: "child")
        let trash = try fixture.trash(for: child)
        try await manager.remove(at: child)
        let saved = fixture.path("saved-trash")
        try fixture.move(trash, to: saved)
        try FileManager.default.createSymbolicLink(at: trash, withDestinationURL: fixture.source)
        await expectRiftError(matching: {
            if case .markerMismatch(let path) = $0 { return path.path == trash.path }
            return false
        }, performing: { try await manager.garbageCollect() })
        #expect(try fixture.read(fixture.source.appendingPathComponent("file.txt")) == "hello")
        #expect(try fixture.read(saved.appendingPathComponent("file.txt")) == "hello")
        try fixture.delete(trash)
        try fixture.move(saved, to: trash)
        let collected = try await manager.garbageCollect()
        #expect(collected.map(\.path) == [trash.path])
    }

    @Test("GC refuses a symlinked trash ancestor even when the target has the expected marker")
    func collectRejectsTrashAncestorSymlink() async throws {
        let fixture = try RiftFixture()
        let manager = try fixture.manager()
        _ = try await manager.initialize(at: fixture.source)
        let child = try await manager.create(from: fixture.source, name: "child")
        let trash = try fixture.trash(for: child)
        try await manager.remove(at: child)
        let trashParent = trash.deletingLastPathComponent()
        let archive = fixture.path("archive-trash")
        try fixture.move(trashParent, to: archive)
        try FileManager.default.createSymbolicLink(at: trashParent, withDestinationURL: archive)
        await expectRiftError(matching: {
            if case .markerMismatch = $0 { return true }
            return false
        }, performing: { try await manager.garbageCollect() })
        let archivedChild = archive.appendingPathComponent(trash.lastPathComponent)
        #expect(try fixture.read(archivedChild.appendingPathComponent("file.txt")) == "hello")
        #expect(try fixture.marker(archivedChild) == fixture.marker(trash))
        try fixture.delete(trashParent)
        try fixture.move(archive, to: trashParent)
        let collected = try await manager.garbageCollect()
        #expect(collected.map(\.path) == [trash.path])
    }

    @Test("Create hooks execute in order, with correct directories and identities")
    func createHookLifecycleAndEnvironment() async throws {
        let fixture = try RiftFixture()
        try fixture.configure("""
        version = 1
        [[hooks.precreate]]
        run = 'printf "pre\\n" >> lifecycle.log'
        [[hooks.postcreate]]
        run = 'printf "first\\n" >> lifecycle.log'
        [[hooks.postcreate]]
        run = 'printf "%s\\n" "$PWD" "$RIFT_SOURCE" "$RIFT_DESTINATION" "$RIFT_ID" "$RIFT_PARENT_ID" > environment.log'
        [[hooks.postcreate]]
        run = 'printf "second\\n" >> lifecycle.log'
        """)
        let manager = try fixture.manager()
        _ = try await manager.initialize(at: fixture.source)
        let child = try await manager.create(from: fixture.source, name: "hooks")
        #expect(try fixture.read(fixture.source.appendingPathComponent("lifecycle.log")) == "pre\n")
        #expect(try fixture.read(child.appendingPathComponent("lifecycle.log")) == "pre\nfirst\nsecond\n")
        let environment = try fixture.read(child.appendingPathComponent("environment.log")).split(separator: "\n").map(String.init)
        #expect(environment == [child.path, fixture.source.path, child.path, try fixture.marker(child), try fixture.marker(fixture.source)])
    }

    @Test("Precreate failure prevents the copy and registry insertion")
    func precreateFailure() async throws {
        let fixture = try RiftFixture()
        try fixture.configure("version = 1\n[[hooks.precreate]]\nrun = 'exit 7'\n")
        let manager = try fixture.manager()
        _ = try await manager.initialize(at: fixture.source)
        await expectRiftError(matching: {
            if case .hookFailed(let hook, let path, let command, _) = $0 {
                return hook == "precreate" && path.path == fixture.source.path && command == "exit 7"
            }
            return false
        }, performing: { try await manager.create(from: fixture.source, name: "failed") })
        #expect(!fixture.exists(fixture.child("failed")))
        let children = try await manager.list(of: fixture.source)
        #expect(children.isEmpty)
    }

    @Test("Precreate staging collisions never delete a directory created by the hook", arguments: [CopyMode.filtered, .all])
    func precreateStagingCollision(_ mode: CopyMode) async throws {
        let fixture = try RiftFixture()
        try fixture.configure("""
        version = 1
        [[hooks.precreate]]
        run = 'staging="$(dirname "$RIFT_DESTINATION")/.rift-staging-$RIFT_ID"; mkdir "$staging"; printf "keep\\n" > "$staging/sentinel.txt"; printf "%s" "$RIFT_ID" > attempted-id.txt'
        """)
        let manager = try fixture.manager()
        _ = try await manager.initialize(at: fixture.source)
        await expectRiftError(matching: { _ in true }, performing: {
            try await manager.create(from: fixture.source, name: "collision", options: CreateOptions(copyMode: mode))
        })
        let id = try fixture.read(fixture.source.appendingPathComponent("attempted-id.txt"))
        let staging = fixture.path(".rifts/app/.rift-staging-\(id)")
        #expect(try fixture.read(staging.appendingPathComponent("sentinel.txt")) == "keep\n")
        #expect(!fixture.exists(fixture.child("collision")))
        let children = try await manager.list(of: fixture.source)
        #expect(children.isEmpty)
    }

    @Test("Postcreate failure keeps the registered child and stops later hooks")
    func postcreateFailure() async throws {
        let fixture = try RiftFixture()
        try fixture.configure("""
        version = 1
        [[hooks.postcreate]]
        run = 'echo before >> hook.log'
        [[hooks.postcreate]]
        run = 'exit 7'
        [[hooks.postcreate]]
        run = 'echo after >> hook.log'
        """)
        let manager = try fixture.manager()
        _ = try await manager.initialize(at: fixture.source)
        let child = fixture.child("failed")
        await expectRiftError(matching: {
            if case .hookFailed(let hook, let path, _, _) = $0 { return hook == "postcreate" && path.path == child.path }
            return false
        }, performing: { try await manager.create(from: fixture.source, name: "failed") })
        let children = try await manager.list(of: fixture.source)
        #expect(children.map(\.path) == [child.path])
        #expect(try fixture.read(child.appendingPathComponent("hook.log")) == "before\n")
    }

    @Test("Invalid configuration fails before copying, while skip bypasses parsing")
    func invalidConfigurationAndSkip() async throws {
        let fixture = try RiftFixture()
        try fixture.configure("version = 2\n")
        let manager = try fixture.manager()
        _ = try await manager.initialize(at: fixture.source)
        await expectRiftError(matching: {
            if case .invalidConfiguration(let path, _) = $0 { return path.path == fixture.source.appendingPathComponent(".rift.toml").path }
            return false
        }, performing: { try await manager.create(from: fixture.source, name: "invalid") })
        #expect(!fixture.exists(fixture.child("invalid")))
        let child = try await manager.create(from: fixture.source, name: "skipped", options: CreateOptions(hooks: .skip))
        #expect(try fixture.read(child.appendingPathComponent(".rift.toml")) == "version = 2\n")
        try await manager.remove(at: child, options: RemoveOptions(hooks: .skip))
        #expect(!fixture.exists(child))
    }

    @Test("Remove hooks span the move and expose original and trash destinations")
    func removeHookLifecycleAndEnvironment() async throws {
        let fixture = try RiftFixture()
        let manager = try fixture.manager()
        _ = try await manager.initialize(at: fixture.source)
        let child = try await manager.create(from: fixture.source, name: "hooks")
        let identity = try fixture.marker(child)
        let parentIdentity = try fixture.marker(fixture.source)
        let trash = try fixture.trash(for: child)
        try fixture.configure("""
        version = 1
        [[hooks.preremove]]
        run = 'echo pre >> lifecycle.log'
        [[hooks.postremove]]
        run = 'echo post >> lifecycle.log'
        [[hooks.postremove]]
        run = 'printf "%s\\n" "$PWD" "$RIFT_SOURCE" "$RIFT_DESTINATION" "$RIFT_ID" "$RIFT_PARENT_ID" > environment.log'
        """, at: child)

        try await manager.remove(at: child)
        #expect(!fixture.exists(child))
        #expect(try fixture.read(trash.appendingPathComponent("lifecycle.log")) == "pre\npost\n")
        let environment = try fixture.read(trash.appendingPathComponent("environment.log")).split(separator: "\n").map(String.init)
        #expect(environment == [trash.path, child.path, trash.path, identity, parentIdentity])
    }

    @Test("Preremove failure preserves the active child; postremove failure preserves trash")
    func removeHookFailures() async throws {
        let fixture = try RiftFixture()
        let manager = try fixture.manager()
        _ = try await manager.initialize(at: fixture.source)
        let child = try await manager.create(from: fixture.source, name: "failure")
        let trash = try fixture.trash(for: child)
        try fixture.configure("version = 1\n[[hooks.preremove]]\nrun = 'exit 9'\n", at: child)
        await expectRiftError(matching: {
            if case .hookFailed(let hook, let path, _, _) = $0 { return hook == "preremove" && path.path == child.path }
            return false
        }, performing: { try await manager.remove(at: child) })
        let activeChildren = try await manager.list(of: fixture.source)
        #expect(activeChildren.map(\.path) == [child.path])
        #expect(fixture.exists(child) && !fixture.exists(trash))

        try fixture.configure("version = 1\n[[hooks.postremove]]\nrun = 'exit 10'\n", at: child)
        await expectRiftError(matching: {
            if case .hookFailed(let hook, let path, _, _) = $0 { return hook == "postremove" && path.path == trash.path }
            return false
        }, performing: { try await manager.remove(at: child) })
        let remaining = try await manager.list(of: fixture.source)
        #expect(remaining.isEmpty)
        #expect(!fixture.exists(child) && fixture.exists(trash))
        let collected = try await manager.garbageCollect()
        #expect(collected.map(\.path) == [trash.path])
    }

    @Test("Git copies detach HEAD and retain staged, dirty, and untracked contents")
    func gitDirtyStateAndDetachedHead() async throws {
        let fixture = try RiftFixture()
        try fixture.commitInitialGitRepository()
        let originalCommit = try fixture.git(["rev-parse", "--verify", "HEAD^{commit}"]).output
        try fixture.write("staged", to: fixture.source.appendingPathComponent("file.txt"))
        try fixture.git(["add", "file.txt"])
        try fixture.write("dirty", to: fixture.source.appendingPathComponent("file.txt"))
        try fixture.write("untracked", to: fixture.source.appendingPathComponent("untracked.txt"))
        let manager = try fixture.manager()
        _ = try await manager.initialize(at: fixture.source)
        let child = try await manager.create(from: fixture.source, name: "git")

        let head = try fixture.git(["symbolic-ref", "-q", "HEAD"], at: child, allowFailure: true)
        #expect(head.status == 1)
        #expect(try fixture.read(child.appendingPathComponent(".git/HEAD")) == originalCommit)
        #expect(try fixture.git(["show", ":file.txt"], at: child).output == "staged")
        #expect(try fixture.read(child.appendingPathComponent("file.txt")) == "dirty")
        #expect(try fixture.read(child.appendingPathComponent("untracked.txt")) == "untracked")
        #expect(try fixture.git(["diff", "--cached", "--name-only"], at: child).output == "file.txt\n")
        #expect(try fixture.git(["diff", "--name-only"], at: child).output == "file.txt\n")
        #expect(try fixture.git(["status", "--porcelain", "--", ".rift"], at: child).output.isEmpty)
        #expect(try fixture.git(["symbolic-ref", "--short", "HEAD"]).output == "main\n")
    }

    @Test("Unsafe Git operation markers reject creation before copying", arguments: ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG", "rebase-merge", "rebase-apply"])
    func unsafeGitState(_ state: String) async throws {
        let fixture = try RiftFixture()
        try fixture.commitInitialGitRepository()
        let manager = try fixture.manager()
        _ = try await manager.initialize(at: fixture.source)
        let marker = fixture.source.appendingPathComponent(".git/\(state)")
        if state.hasPrefix("rebase-") {
            try fixture.mkdir(marker)
        } else {
            try fixture.write("commit", to: marker)
        }
        await expectRiftError(matching: {
            if case .unsafeGit(let message) = $0 { return message.contains(state) }
            return false
        }, performing: { try await manager.create(from: fixture.source, name: "unsafe") })
        #expect(!fixture.exists(fixture.child("unsafe")))
        let children = try await manager.list(of: fixture.source)
        #expect(children.isEmpty)
    }

    @Test("A Git writer's lock rejects creation as retryable", arguments: ["index.lock", "HEAD.lock", "gc.pid"])
    func busyGitSource(_ state: String) async throws {
        let fixture = try RiftFixture()
        try fixture.commitInitialGitRepository()
        let manager = try fixture.manager()
        _ = try await manager.initialize(at: fixture.source)
        let marker = fixture.source.appendingPathComponent(".git/\(state)")
        try fixture.write("writer", to: marker)
        await expectRiftError(matching: {
            if case .gitBusy(let message) = $0 { return message.contains(state) }
            return false
        }, performing: { try await manager.create(from: fixture.source, name: "busy") })
        #expect(!fixture.exists(fixture.child("busy")))
        try fixture.delete(marker)
        _ = try await manager.create(from: fixture.source, name: "busy")
        #expect(fixture.exists(fixture.child("busy")))
    }

    @Test("A source that owns linked worktrees copies without their metadata")
    func sourceOwningLinkedWorktrees() async throws {
        let fixture = try RiftFixture()
        try fixture.commitInitialGitRepository()
        let linked = fixture.path("linked")
        try fixture.git(["worktree", "add", "-b", "feature", linked.path])
        let manager = try fixture.manager()
        _ = try await manager.initialize(at: fixture.source)
        let child = try await manager.create(from: fixture.source, name: "copy")

        #expect(!fixture.exists(child.appendingPathComponent(".git/worktrees")))
        let copied = try fixture.git(["worktree", "list", "--porcelain"], at: child).output
        #expect(!copied.contains(linked.path))
        // The copy can take a branch the source still has checked out elsewhere.
        try fixture.git(["switch", "feature"], at: child)
        let original = try fixture.git(["worktree", "list", "--porcelain"]).output
        #expect(original.contains(linked.path))
        #expect(try fixture.git(["status", "--porcelain"], at: linked).output.isEmpty)
    }

    @Test("Linked Git worktrees are rejected before copying")
    func linkedGitWorktree() async throws {
        let fixture = try RiftFixture()
        try fixture.commitInitialGitRepository()
        let manager = try fixture.manager()
        _ = try await manager.initialize(at: fixture.source)
        try fixture.delete(fixture.source.appendingPathComponent(".git"))
        try fixture.write("gitdir: ../linked/.git\n", to: fixture.source.appendingPathComponent(".git"))
        await expectRiftError(matching: {
            if case .unsafeGit(let message) = $0 { return message.lowercased().contains("linked") }
            return false
        }, performing: { try await manager.create(from: fixture.source, name: "linked") })
        #expect(!fixture.exists(fixture.child("linked")))
    }
}
