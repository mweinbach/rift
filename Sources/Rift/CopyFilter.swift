/// Artifact filtering uses exact names, extending upstream with SwiftPM builds.
struct CopyFilter {
    private static let excludedComponents: Set<String> = [
        "node_modules", ".pnpm-store", "target", ".venv", "venv", ".tox", ".nox",
        "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".next",
        ".nuxt", ".svelte-kit", ".turbo", ".vite", ".parcel-cache", ".cache",
        "dist", "build", "coverage", ".build",
    ]
    private static let yarnArtifacts: Set<String> = [
        "cache", "unplugged", "install-state.gz", "build-state.yml",
    ]

    func excludes(components: [String]) -> Bool {
        if components.contains(where: Self.excludedComponents.contains) { return true }
        return zip(components, components.dropFirst()).contains { first, second in
            first == ".yarn" && Self.yarnArtifacts.contains(second)
        }
    }
}
