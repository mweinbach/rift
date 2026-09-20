import Foundation
import Darwin

/// Failures with enough context for a caller to identify the affected workspace.
public enum RiftError: Error, Equatable, Sendable, LocalizedError {
    case io(operation: String, path: URL, code: Int32)
    case database(String)
    case invalidPath(String)
    case copyOnWriteUnavailable(String)
    case workspaceNotInitialized(URL)
    case missingMarker(URL)
    case unsupportedEntry(URL)
    case unsafeGit(String)
    /// Another Git process holds a short-lived lock; the operation can be retried.
    case gitBusy(String)
    case notManaged(URL)
    case markerMismatch(URL)
    case unknownMarker(URL)
    case alreadyExists(URL)
    case namesExhausted(URL)
    case missingRift(URL)
    case insideSource(URL)
    case overlappingWorkspace(path: URL, other: URL)
    case rollbackFailed(operation: String, message: String)
    case invalidConfiguration(path: URL, message: String)
    case hookFailed(hook: String, path: URL, command: String, message: String)

    public var errorDescription: String? {
        switch self {
        case let .io(operation, path, code):
            return "\(operation) failed for \(path.path): \(String(cString: strerror(code)))"
        case let .database(message): return "Rift database: \(message)"
        case let .invalidPath(message): return "Invalid path: \(message)"
        case let .copyOnWriteUnavailable(message): return "Copy-on-write cloning unavailable: \(message)"
        case let .workspaceNotInitialized(path): return "Workspace is not initialized: \(path.path). Call initialize(at:) on its root first."
        case let .missingMarker(path): return "Rift marker is missing: \(path.path). Call initialize(at:) to restore it."
        case let .unsupportedEntry(path): return "Unsupported filesystem entry: \(path.path)"
        case let .unsafeGit(message): return "Unsafe Git source: \(message)"
        case let .gitBusy(message): return "Git source is busy: \(message)"
        case let .notManaged(path): return "Directory is not managed by Rift: \(path.path)"
        case let .markerMismatch(path): return "Rift marker does not match the registry at: \(path.path)"
        case let .unknownMarker(path): return "Rift marker belongs to an unknown registry entry at: \(path.path)"
        case let .alreadyExists(path): return "Rift directory already exists: \(path.path)"
        case let .namesExhausted(path): return "Every generated Rift name is already in use under: \(path.path)"
        case let .missingRift(path): return "Cannot remove subtree while a recorded Rift path is missing: \(path.path)"
        case let .insideSource(path): return "Cannot copy a workspace into itself: \(path.path)"
        case let .overlappingWorkspace(path, other): return "Managed workspace paths overlap: \(path.path) and \(other.path)"
        case let .rollbackFailed(operation, message): return "\(operation) failed and could not be fully rolled back: \(message)"
        case let .invalidConfiguration(path, message): return "Invalid Rift config at \(path.path): \(message)"
        case let .hookFailed(hook, path, command, message): return "\(hook) hook failed at \(path.path): `\(command)` \(message)"
        }
    }
}
