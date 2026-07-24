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
}
