import Foundation

/// Locates repo-level fixtures (e.g. `Sprites/salli`) relative to this source file.
enum Fixtures {
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MotiveSpriteTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
    }

    static var salli: URL {
        repoRoot.appendingPathComponent("Sprites/salli", isDirectory: true)
    }
}
