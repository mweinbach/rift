import Foundation
import Testing
@testable import Rift

struct HookConfigurationTests {
    @Test func absentConfigurationDisablesHooks() throws {
        let fixture = try HookFixture()
        let config = try HookConfiguration.load(workspace: fixture.directory)
        #expect(config.precreate.isEmpty && config.postcreate.isEmpty)
        #expect(config.preremove.isEmpty && config.postremove.isEmpty)
    }

    @Test func parsesOrderedLifecycleHooks() throws {
        let fixture = try HookFixture()
        try fixture.config("""
        version = 1
        [[hooks.precreate]]
        run = " echo before "
        [[hooks.postcreate]]
        run = "echo one"
        [[hooks.postcreate]]
        run = "echo two"
        [[hooks.preremove]]
        run = "echo remove"
        [[hooks.postremove]]
        run = "echo removed"
        """)
        let config = try HookConfiguration.load(workspace: fixture.directory)
        #expect(config.precreate == ["echo before"])
        #expect(config.postcreate == ["echo one", "echo two"])
        #expect(config.preremove == ["echo remove"])
        #expect(config.postremove == ["echo removed"])
    }

    @Test func parsesFullTomlStringsQuotedKeysAndInlineTables() throws {
        let fixture = try HookFixture()
        try fixture.config(#"""
        "version" = 0x1
        "hooks".precreate = [{ "run" = ' echo literal # unchanged ' }]
        "hooks".postcreate = [{ run = "echo escaped\nsecond line" }]
        [[hooks.preremove]]
        run = """
        echo first
        echo second
        """
        [[hooks.postremove]]
        run = '''echo "literal quotes"'''
        """#)
        let config = try HookConfiguration.load(workspace: fixture.directory)
        #expect(config.precreate == ["echo literal # unchanged"])
        #expect(config.postcreate == ["echo escaped\nsecond line"])
        #expect(config.preremove == ["echo first\necho second"])
        #expect(config.postremove == ["echo \"literal quotes\""])
    }

    @Test(arguments: [
        "version = 2",
        "version = -1",
        "version = 4294967296",
        "version = 1.0",
        "version = '1'",
        "[hooks]",
        "version = 1\nextra = 42",
        "version = 1\n[hooks]\nunknown = []",
        "version = 1\n[[hooks.postcreate]]\nrun = 'echo ok'\nshell = 'sh'",
        "version = 1\n[[hooks.postcreate]]\nrun = '   '",
        "version = 1\n[[hooks.postcreate]]\nother = 'echo ok'",
        "version = 1\n[hooks]\npostcreate = ['echo ok']",
        "version = 1\n[[hooks.postcreate]]\nrun = 42",
        "version = 1\nversion = 1",
        "version = 1\n[[hooks.postcreate]]\nrun = 'echo ok'\nrun = 'echo again'",
        "version = 1\n[[hooks.postcreate]]\nrun = \"unterminated",
    ])
    func rejectsInvalidConfiguration(_ contents: String) throws {
        let fixture = try HookFixture()
        try fixture.config(contents)
        do {
            _ = try HookConfiguration.load(workspace: fixture.directory)
            Issue.record("Accepted invalid configuration: \(contents)")
        } catch RiftError.invalidConfiguration(let path, let message) {
            #expect(path == fixture.directory.appendingPathComponent(".rift.toml"))
            #expect(!message.isEmpty)
        }
    }

    @Test func hooksInheritEnvironmentAndRunInOrderInSelectedDirectory() throws {
        let fixture = try HookFixture()
        let source = fixture.directory.appendingPathComponent("source with spaces")
        let destination = fixture.directory.appendingPathComponent("destination with spaces")
        try HookRunner.run(
            name: "postcreate",
            steps: [
                "printf '%s\\n' \"$RIFT_SOURCE\" \"$RIFT_DESTINATION\" \"$RIFT_ID\" \"$RIFT_PARENT_ID\" > environment",
                "test -n \"$PATH\" && test -f environment && printf 'second\\n' >> environment",
            ],
            currentDirectory: fixture.directory, source: source, destination: destination,
            id: "child-id", parentID: "parent-id"
        )
        #expect(try fixture.read("environment") == "\(source.path)\n\(destination.path)\nchild-id\nparent-id\nsecond\n")
    }

    @Test func failedHookStopsRemainingStepsAndIncludesContext() throws {
        let fixture = try HookFixture()
        do {
            try HookRunner.run(
                name: "precreate", steps: ["exit 23", "touch should-not-exist"],
                currentDirectory: fixture.directory, source: fixture.directory, destination: fixture.directory,
                id: "child-id", parentID: "parent-id"
            )
            Issue.record("Expected the hook to fail")
        } catch RiftError.hookFailed(let hook, let path, let command, let message) {
            #expect(hook == "precreate")
            #expect(path == fixture.directory)
            #expect(command == "exit 23")
            #expect(message.contains("23"))
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("should-not-exist").path))
    }
}

private final class HookFixture {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("rift-hooks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
    func config(_ contents: String) throws { try Data(contents.utf8).write(to: directory.appendingPathComponent(".rift.toml")) }
    func read(_ path: String) throws -> String { try String(contentsOf: directory.appendingPathComponent(path), encoding: .utf8) }
}
