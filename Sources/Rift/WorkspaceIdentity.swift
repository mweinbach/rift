import Foundation
import Darwin

internal enum WorkspaceIdentity {
    static func generate() -> String {
        // ULID: 48-bit timestamp followed by 80 random bits, encoded in Crockford base32.
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        var bytes = (0..<6).reversed().map { UInt8(truncatingIfNeeded: timestamp >> ($0 * 8)) }
        var random = SystemRandomNumberGenerator()
        bytes += (0..<10).map { _ in UInt8.random(in: .min ... .max, using: &random) }
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        return String((0..<26).map { group in
            var value = 0
            for offset in 0..<5 {
                let bit = group * 5 + offset - 2
                value <<= 1
                if bit >= 0 { value |= Int((bytes[bit / 8] >> (7 - bit % 8)) & 1) }
            }
            return alphabet[value]
        })
    }

    static func marker(at workspace: URL) -> URL { workspace.appendingPathComponent(".rift") }

    static func read(at workspace: URL) throws -> String? {
        let path = marker(at: workspace)
        var info = stat()
        guard lstat(path.path, &info) == 0 else {
            let code = errno
            if code == ENOENT { return nil }
            throw RiftError.io(operation: "read marker", path: path, code: code)
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw RiftError.markerMismatch(workspace) }
        return try String(contentsOf: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func write(at workspace: URL, id: String) throws {
        let path = marker(at: workspace)
        // Atomic replacement also breaks any cloned hard link to the source marker.
        try Data("\(id)\n".utf8).write(to: path, options: .atomic)
    }

    static func verify(at workspace: URL, id: String) throws {
        var info = stat()
        guard lstat(workspace.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              try WorkspacePaths.canonicalPath(workspace).path == workspace.path,
              try read(at: workspace) == id else {
            throw RiftError.markerMismatch(workspace)
        }
    }
}

internal enum WorkspaceNames {
    private static let adjectives = [
        "amber", "bold", "brisk", "calm", "cedar", "clear", "cobalt", "coral", "dawn", "ember",
        "gentle", "golden", "jade", "lively", "lunar", "mellow", "misty", "noble", "quiet", "rapid",
        "river", "silver", "solar", "spruce", "steady", "swift", "tidal", "verdant", "violet", "warm",
        "wild", "winter"
    ]
    private static let nouns = [
        "badger", "brook", "canyon", "cedar", "comet", "dune", "falcon", "field", "forest", "harbor",
        "heron", "island", "lantern", "maple", "meadow", "mesa", "otter", "peak", "pine", "reef",
        "ridge", "robin", "sparrow", "summit", "thicket", "trail", "valley", "willow", "wren",
        "yarrow", "zephyr", "fox"
    ]

    static func validate(_ name: String) throws {
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.utf8.contains(0) else {
            throw RiftError.invalidPath("Invalid Rift name: \(name)")
        }
    }

    static func generated() -> [String] {
        adjectives.flatMap { adjective in nouns.map { "\(adjective)-\($0)" } }.shuffled()
    }
}
