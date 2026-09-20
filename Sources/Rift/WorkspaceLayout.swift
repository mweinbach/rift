import Foundation

/// Registry ancestry cannot safely describe directories that contain one another.
/// Validate the physical layout before registration or destructive filesystem work.
internal struct WorkspaceLayout {
    let active: [PathRecord]
    let trash: [PathRecord]

    init(registry: Registry) throws {
        active = try registry.activePaths()
        trash = try registry.trashedPaths()
    }

    func validateNewWorkspace(at path: URL) throws {
        try validate(path, against: active)
        try validate(path, against: trash)
    }

    func validateStorage(at path: URL) throws {
        for other in active + trash where WorkspacePaths.contains(other.path, path) {
            throw RiftError.overlappingWorkspace(path: path, other: other.path)
        }
    }

    func validateRemoval(of record: PathRecord) throws {
        try validate(record.path, against: active, excluding: record)
        try validate(record.path, against: trash)
    }

    func validateCollection(of record: PathRecord) throws {
        try validate(record.path, against: active)
        try validate(record.path, against: trash, excluding: record)
    }

    private func validate(_ path: URL, against records: [PathRecord], excluding: PathRecord? = nil) throws {
        for other in records {
            if let excluding, excluding.id == other.id, excluding.path.path == other.path.path { continue }
            if WorkspacePaths.contains(path, other.path) || WorkspacePaths.contains(other.path, path) {
                throw RiftError.overlappingWorkspace(path: path, other: other.path)
            }
        }
    }
}
