import Foundation

/// Manages macOS copy-on-write workspaces and their persistent ancestry.
///
/// Operations are serialized within this actor and coordinated with other Swift
/// managers using the same database. Filesystem work is synchronous within each
/// operation; call from a task when integrating into an application.
public actor RiftManager {
    public nonisolated let databaseURL: URL
    private let registry: Registry
    private let cloner = APFSCloner()
    private let operationLock: OperationLock

    public init(databaseURL: URL? = nil) throws {
        let requested = databaseURL ?? Self.defaultDatabaseURL
        try WorkspacePaths.validate(requested)
        let parent = try WorkspacePaths.prospectiveDirectory(requested.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let resolvedParent = try WorkspacePaths.existingDirectory(parent)
        let candidate = resolvedParent.appendingPathComponent(requested.lastPathComponent)
        let resolved = try WorkspacePaths.exists(candidate)
            ? WorkspacePaths.canonicalPath(candidate)
            : WorkspacePaths.prospectiveDirectory(candidate)
        let database = URL(fileURLWithPath: resolved.path, isDirectory: false)
        let lock = try OperationLock(databaseURL: database)
        self.databaseURL = database
        operationLock = lock
        registry = try lock.withLock { try Registry(path: database) }
    }

    /// The same macOS database location used by the original Rift implementation.
    public nonisolated static var defaultDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/rift", isDirectory: true)
            .appendingPathComponent("rift.sqlite")
    }

    /// Registers exactly `at`, or restores its missing identity marker.
    public func initialize(
        at: URL,
        progress: (@Sendable (InitializationProgress) -> Void)? = nil
    ) throws -> InitializationOutcome {
        try operationLock.withLock {
            let path = try WorkspacePaths.existingDirectory(at)
            let isGit = try GitIntegration.checkSource(at: path)
            if let record = try registry.record(at: path) {
                if try WorkspaceIdentity.read(at: path) == nil {
                    progress?(.restoringMarker)
                    try WorkspaceIdentity.write(at: path, id: record.id)
                } else {
                    try WorkspaceIdentity.verify(at: path, id: record.id)
                }
                if isGit { try GitIntegration.hideMarker(at: path) }
                return .alreadyInitialized
            }
            guard try WorkspaceIdentity.read(at: path) == nil else {
                throw RiftError.markerMismatch(path)
            }
            progress?(.registeringWorkspace)
            let id = WorkspaceIdentity.generate()
            do {
                try WorkspaceIdentity.write(at: path, id: id)
                if isGit { try GitIntegration.hideMarker(at: path) }
                try registry.insertRoot(id: id, path: path)
                return .registered
            } catch {
                try? FileManager.default.removeItem(at: WorkspaceIdentity.marker(at: path))
                throw error
            }
        }
    }

    /// Clones the nearest managed workspace above `from` and records its immediate parent.
    public func create(
        from: URL,
        name: String? = nil,
        into: URL? = nil,
        options: CreateOptions = CreateOptions()
    ) throws -> URL {
        try operationLock.withLock {
            let source = try workspaceRecord(at: from)
            _ = try GitIntegration.checkSource(at: source.path)
            let root = try rootRecord(of: source)
            let storage = try into ?? WorkspacePaths.defaultStorage(root: root.path)
            let prospective = try WorkspacePaths.prospectiveDirectory(storage)
            guard !WorkspacePaths.contains(source.path, prospective) else {
                throw RiftError.insideSource(prospective)
            }
            if let name { try WorkspaceNames.validate(name) }
            try FileManager.default.createDirectory(at: prospective, withIntermediateDirectories: true)
            let parent = try WorkspacePaths.existingDirectory(prospective)
            guard !WorkspacePaths.contains(source.path, parent) else { throw RiftError.insideSource(parent) }
            let chosenName: String
            if let name {
                chosenName = name
            } else {
                guard let generated = WorkspaceNames.generated().first(where: {
                    !WorkspacePaths.exists(parent.appendingPathComponent($0))
                }) else { throw RiftError.namesExhausted(parent) }
                chosenName = generated
            }
            let destination = parent.appendingPathComponent(chosenName, isDirectory: true)
            guard !WorkspacePaths.exists(destination) else { throw RiftError.alreadyExists(destination) }
            let id = WorkspaceIdentity.generate()
            let config = try configuration(at: source.path, hooks: options.hooks)
            try runHooks(
                name: "precreate", steps: config.precreate, currentDirectory: source.path,
                source: source.path, destination: destination, id: id, parentID: source.id
            )
            // A precreate hook can change the source, Git state, or destination.
            try revalidate(record: source)
            let isGit = try GitIntegration.checkSource(at: source.path)
            guard try WorkspacePaths.existingDirectory(parent).path == parent.path else {
                throw RiftError.markerMismatch(parent)
            }
            // Prepare privately, then publish without overwriting another creator's workspace.
            let staging = parent.appendingPathComponent(".rift-staging-\(id)", isDirectory: true)
            guard !WorkspacePaths.exists(staging) else { throw RiftError.alreadyExists(staging) }
            var published = false
            do {
                try cloner.copyDirectory(from: source.path, to: staging, mode: options.copyMode)
                try WorkspaceIdentity.write(at: staging, id: id)
                if isGit {
                    try GitIntegration.hideMarker(at: staging)
                    try GitIntegration.detachDestination(at: staging)
                    try GitIntegration.hideMarker(at: source.path)
                }
                try WorkspacePaths.moveExclusively(from: staging, to: destination)
                published = true
                try registry.insertChild(id: id, parentID: source.id, path: destination)
            } catch {
                let cleanup = published ? destination : staging
                let refusedExisting: Bool
                if case let RiftError.alreadyExists(path) = error {
                    refusedExisting = !published && path.path == staging.path
                } else {
                    refusedExisting = false
                }
                if !refusedExisting, WorkspacePaths.exists(cleanup) { try? cloner.removeDirectory(at: cleanup) }
                throw error
            }
            try runHooks(
                name: "postcreate", steps: config.postcreate, currentDirectory: destination,
                source: source.path, destination: destination, id: id, parentID: source.id
            )
            return destination
        }
    }

    /// Trashes a created subtree, or unregisters a source root while preserving its directory.
    public func remove(at: URL, options: RemoveOptions = RemoveOptions()) throws {
        try operationLock.withLock {
            let record = try workspaceRecord(at: at)
            try WorkspaceIdentity.verify(at: record.path, id: record.id)
            let config = try configuration(at: record.path, hooks: options.hooks)
            let parentID = record.parentID ?? record.id
            try runRemoveHook("preremove", steps: config.preremove, record: record, destination: record.path, parentID: parentID)
            try revalidate(record: record)
            let destination: URL
            if record.parentID == nil {
                let rows = try registry.subtree(id: record.id, scope: .descendantsOnly)
                try trash(rows: rows.filter { WorkspacePaths.exists($0.path) })
                try FileManager.default.removeItem(at: WorkspaceIdentity.marker(at: record.path))
                try registry.deleteActive(id: record.id)
                destination = record.path
            } else {
                try trash(rows: registry.subtree(id: record.id, scope: .includingRoot))
                destination = try WorkspacePaths.trash(id: record.id, path: record.path)
            }
            try runRemoveHook("postremove", steps: config.postremove, record: record, destination: destination, parentID: parentID)
        }
    }

    /// Trashes every descendant while preserving the selected managed workspace.
    public func removeAll(at: URL, options: RemoveOptions = RemoveOptions()) throws -> [URL] {
        try operationLock.withLock {
            let record = try workspaceRecord(at: at)
            try WorkspaceIdentity.verify(at: record.path, id: record.id)
            let config = try configuration(at: record.path, hooks: options.hooks)
            let parentID = record.parentID ?? record.id
            try runRemoveHook("preremove", steps: config.preremove, record: record, destination: record.path, parentID: parentID)
            try revalidate(record: record)
            let rows = try registry.subtree(id: record.id, scope: .descendantsOnly)
            try trash(rows: rows)
            try runRemoveHook("postremove", steps: config.postremove, record: record, destination: record.path, parentID: parentID)
            return rows.map(\.path)
        }
    }

    /// Direct active children, ordered by creation time and identity.
    public func list(of: URL) throws -> [URL] {
        try operationLock.withLock { try registry.childPaths(parentID: workspaceRecord(at: of).id) }
    }

    /// The immediate parent through to the original source root.
    public func ancestors(of: URL) throws -> [URL] {
        try operationLock.withLock {
            let record = try workspaceRecord(at: of)
            var parentID = record.parentID
            var paths: [URL] = []
            var visited: Set<String> = [record.id]
            while let id = parentID {
                guard visited.insert(id).inserted, let parent = try registry.record(id: id) else {
                    throw RiftError.notManaged(record.path)
                }
                paths.append(parent.path)
                parentID = parent.parentID
            }
            return paths
        }
    }

    public func workspace(at: URL) throws -> URL {
        try operationLock.withLock { try workspaceRecord(at: at).path }
    }

    /// Deletes owned trash and prunes missing active records without orphaning existing descendants.
    public func garbageCollect() throws -> [URL] {
        try operationLock.withLock {
            var removed: [URL] = []
            for row in try registry.trashedPaths() {
                if WorkspacePaths.exists(row.path) {
                    try WorkspaceIdentity.verify(at: row.path, id: row.id)
                    try cloner.removeDirectory(at: row.path)
                }
                try registry.deleteTrash(id: row.id)
                removed.append(row.path)
            }
            var missing: [PathRecord] = []
            for row in try registry.activePaths() where !WorkspacePaths.exists(row.path) {
                let descendants = try registry.subtree(id: row.id, scope: .descendantsOnly)
                if !descendants.contains(where: { WorkspacePaths.exists($0.path) }) { missing.append(row) }
            }
            try registry.deleteActiveRecords(missing)
            return removed + missing.map(\.path)
        }
    }

    private func configuration(at: URL, hooks: HookMode) throws -> HookConfiguration {
        switch hooks {
        case .run: return try HookConfiguration.load(workspace: at)
        case .skip: return HookConfiguration()
        }
    }

    private func workspaceRecord(at: URL) throws -> Record {
        let requested = try WorkspacePaths.existingDirectory(at)
        var directory = requested
        while true {
            if let id = try WorkspaceIdentity.read(at: directory) {
                guard let record = try registry.record(id: id) else { throw RiftError.unknownMarker(directory) }
                guard record.path.path == directory.path else { throw RiftError.markerMismatch(directory) }
                return record
            }
            if try registry.record(at: directory) != nil { throw RiftError.missingMarker(directory) }
            if directory.path == "/" { break }
            directory.deleteLastPathComponent()
        }
        throw RiftError.workspaceNotInitialized(requested)
    }

    private func rootRecord(of record: Record) throws -> Record {
        var current = record
        var visited: Set<String> = [record.id]
        while let id = current.parentID {
            guard visited.insert(id).inserted, let parent = try registry.record(id: id) else {
                throw RiftError.notManaged(record.path)
            }
            current = parent
        }
        return current
    }

    private func runRemoveHook(_ name: String, steps: [String], record: Record, destination: URL, parentID: String) throws {
        try runHooks(
            name: name, steps: steps, currentDirectory: name == "preremove" ? record.path : destination,
            source: record.path, destination: destination, id: record.id, parentID: parentID
        )
    }

    private func runHooks(name: String, steps: [String], currentDirectory: URL, source: URL, destination: URL, id: String, parentID: String) throws {
        guard !steps.isEmpty else { return }
        try operationLock.withoutFileLock {
            try HookRunner.run(
                name: name, steps: steps, currentDirectory: currentDirectory,
                source: source, destination: destination, id: id, parentID: parentID
            )
        }
    }

    private func revalidate(record: Record) throws {
        try WorkspaceIdentity.verify(at: record.path, id: record.id)
        guard let current = try registry.record(id: record.id), current.path.path == record.path.path,
              current.parentID == record.parentID else { throw RiftError.notManaged(record.path) }
    }

    private func trash(rows: [PathRecord]) throws {
        // Check the entire subtree before the first move.
        let targets = try rows.map { row -> MovedRecord in
            guard WorkspacePaths.exists(row.path) else { throw RiftError.missingRift(row.path) }
            try WorkspaceIdentity.verify(at: row.path, id: row.id)
            let target = try WorkspacePaths.trash(id: row.id, path: row.path)
            guard !WorkspacePaths.exists(target) else { throw RiftError.alreadyExists(target) }
            let parent = target.deletingLastPathComponent()
            let resolvedParent = try WorkspacePaths.prospectiveDirectory(parent)
            guard resolvedParent.path == parent.path else { throw RiftError.markerMismatch(parent) }
            return MovedRecord(id: row.id, originalPath: row.path, trashPath: target)
        }
        var moved: [MovedRecord] = []
        do {
            for target in targets {
                try FileManager.default.createDirectory(at: target.trashPath.deletingLastPathComponent(), withIntermediateDirectories: true)
                try WorkspacePaths.moveExclusively(from: target.originalPath, to: target.trashPath)
                moved.append(target)
            }
            try registry.trashMoved(moved)
        } catch {
            // Moves and SQL publication form one operation; restore paths on failure.
            for target in moved.reversed() {
                try? WorkspacePaths.moveExclusively(from: target.trashPath, to: target.originalPath)
            }
            throw error
        }
    }
}
