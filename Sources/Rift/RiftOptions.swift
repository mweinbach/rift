import Foundation

/// Whether a new workspace omits regenerable build and dependency artifacts.
public enum CopyMode: Sendable {
    case filtered
    case all
}

/// Whether operations load and execute the workspace's `.rift.toml` hooks.
public enum HookMode: Sendable {
    case run
    case skip
}

public struct CreateOptions: Sendable {
    public var copyMode: CopyMode
    public var hooks: HookMode

    public init(copyMode: CopyMode = .filtered, hooks: HookMode = .run) {
        self.copyMode = copyMode
        self.hooks = hooks
    }
}

public struct RemoveOptions: Sendable {
    public var hooks: HookMode

    public init(hooks: HookMode = .run) {
        self.hooks = hooks
    }
}

public enum InitializationOutcome: Sendable {
    case registered
    case alreadyInitialized
}

public enum InitializationProgress: Sendable {
    case restoringMarker
    case registeringWorkspace
}
