import Foundation
import TOMLDecoder

struct HookConfiguration {
    let precreate: [String]
    let postcreate: [String]
    let preremove: [String]
    let postremove: [String]

    init() {
        precreate = []
        postcreate = []
        preremove = []
        postremove = []
    }

    private init(raw: RawConfiguration, path: URL) throws {
        guard raw.version >= 0, raw.version <= Int64(UInt32.max) else {
            throw RiftError.invalidConfiguration(path: path, message: "version must be an unsigned 32-bit integer")
        }
        guard raw.version == 1 else {
            throw RiftError.invalidConfiguration(path: path, message: "unsupported config version \(raw.version)")
        }
        func commands(_ name: String, _ steps: [RawHook]) throws -> [String] {
            try steps.map { step in
                let run = step.run.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !run.isEmpty else {
                    throw RiftError.invalidConfiguration(path: path, message: "\(name) run cannot be empty")
                }
                return run
            }
        }
        precreate = try commands("precreate", raw.hooks.precreate)
        postcreate = try commands("postcreate", raw.hooks.postcreate)
        preremove = try commands("preremove", raw.hooks.preremove)
        postremove = try commands("postremove", raw.hooks.postremove)
    }

    static func load(workspace: URL) throws -> HookConfiguration {
        let path = workspace.appendingPathComponent(".rift.toml")
        guard FileManager.default.fileExists(atPath: path.path) else { return HookConfiguration() }
        let contents = try Data(contentsOf: path)
        do {
            let raw = try TOMLDecoder(isLenient: false).decode(RawConfiguration.self, from: contents)
            return try HookConfiguration(raw: raw, path: path)
        } catch let error as RiftError {
            throw error
        } catch {
            throw RiftError.invalidConfiguration(path: path, message: String(describing: error))
        }
    }
}

private struct RawConfiguration: Decodable {
    let version: Int64
    let hooks: RawHooks

    init(from decoder: any Decoder) throws {
        let container = try checkedContainer(decoder, allowed: ["version", "hooks"])
        version = try container.decode(Int64.self, forKey: ConfigurationKey("version"))
        hooks = try container.decodeIfPresent(RawHooks.self, forKey: ConfigurationKey("hooks")) ?? RawHooks()
    }
}

private struct RawHooks: Decodable {
    let precreate: [RawHook]
    let postcreate: [RawHook]
    let preremove: [RawHook]
    let postremove: [RawHook]

    init() {
        precreate = []
        postcreate = []
        preremove = []
        postremove = []
    }

    init(from decoder: any Decoder) throws {
        let container = try checkedContainer(decoder, allowed: ["precreate", "postcreate", "preremove", "postremove"])
        precreate = try container.decodeIfPresent([RawHook].self, forKey: ConfigurationKey("precreate")) ?? []
        postcreate = try container.decodeIfPresent([RawHook].self, forKey: ConfigurationKey("postcreate")) ?? []
        preremove = try container.decodeIfPresent([RawHook].self, forKey: ConfigurationKey("preremove")) ?? []
        postremove = try container.decodeIfPresent([RawHook].self, forKey: ConfigurationKey("postremove")) ?? []
    }
}

private struct RawHook: Decodable {
    let run: String

    init(from decoder: any Decoder) throws {
        let container = try checkedContainer(decoder, allowed: ["run"])
        run = try container.decode(String.self, forKey: ConfigurationKey("run"))
    }
}

private struct ConfigurationKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func checkedContainer(
    _ decoder: any Decoder,
    allowed: Set<String>
) throws -> KeyedDecodingContainer<ConfigurationKey> {
    let container = try decoder.container(keyedBy: ConfigurationKey.self)
    if let unknown = container.allKeys.map(\.stringValue).sorted().first(where: { !allowed.contains($0) }) {
        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: "unknown field '\(unknown)'"
        ))
    }
    return container
}
