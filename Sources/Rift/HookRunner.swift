import Foundation

enum HookRunner {
    static func run(
        name: String,
        steps: [String],
        currentDirectory: URL,
        source: URL,
        destination: URL,
        id: String,
        parentID: String
    ) throws {
        for command in steps {
            // Foundation raises an Objective-C exception for NUL arguments, which
            // Swift's error handling cannot catch.
            guard !command.utf8.contains(0) else {
                throw RiftError.hookFailed(
                    hook: name, path: currentDirectory, command: command,
                    message: "command cannot contain null bytes"
                )
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.currentDirectoryURL = currentDirectory
            var environment = ProcessInfo.processInfo.environment
            environment["RIFT_SOURCE"] = source.path
            environment["RIFT_DESTINATION"] = destination.path
            environment["RIFT_ID"] = id
            environment["RIFT_PARENT_ID"] = parentID
            process.environment = environment
            process.standardInput = FileHandle.standardInput
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError
            do {
                try process.run()
            } catch {
                throw RiftError.hookFailed(
                    hook: name, path: currentDirectory, command: command,
                    message: "failed to start: \(error)"
                )
            }
            process.waitUntilExit()
            guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                let message = process.terminationReason == .exit
                    ? "exited with status \(process.terminationStatus)"
                    : "terminated by signal \(process.terminationStatus)"
                throw RiftError.hookFailed(hook: name, path: currentDirectory, command: command, message: message)
            }
        }
    }
}
