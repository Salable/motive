import Foundation

/// Locates repo-level fixtures (e.g. `Sprites/winston`) relative to this source file.
enum Fixtures {
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MotiveSpriteTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
    }

    static var winston: URL {
        repoRoot.appendingPathComponent("Sprites/winston", isDirectory: true)
    }

    /// The starter kit — every package under `Sprites/starter/`, discovered
    /// rather than listed, so a new one is covered by the tests the day it
    /// lands.
    static var starterPackages: [URL] {
        let root = repoRoot.appendingPathComponent("Sprites/starter", isDirectory: true)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        return contents
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("motive.json").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
