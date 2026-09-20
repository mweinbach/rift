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
    case notManaged(URL)
    case markerMismatch(URL)
    case unknownMarker(URL)
    case alreadyExists(URL)
    case namesExhausted(URL)
    case missingRift(URL)
    case insideSource(URL)
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
        case let .notManaged(path): return "Directory is not managed by Rift: \(path.path)"
        case let .markerMismatch(path): return "Rift marker does not match the registry at: \(path.path)"
        case let .unknownMarker(path): return "Rift marker belongs to an unknown registry entry at: \(path.path)"
        case let .alreadyExists(path): return "Rift directory already exists: \(path.path)"
        case let .namesExhausted(path): return "Every generated Rift name is already in use under: \(path.path)"
        case let .missingRift(path): return "Cannot remove subtree while a recorded Rift path is missing: \(path.path)"
        case let .insideSource(path): return "Cannot copy a workspace into itself: \(path.path)"
        case let .invalidConfiguration(path, message): return "Invalid Rift config at \(path.path): \(message)"
        case let .hookFailed(hook, path, command, message): return "\(hook) hook failed at \(path.path): `\(command)` \(message)"
        }
    }
}
