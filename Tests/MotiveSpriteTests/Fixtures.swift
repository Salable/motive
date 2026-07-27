import Foundation

/// Locates repo-level fixtures (e.g. `Sprites/winston`, `Kit/`) relative to
/// this source file.
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

    static var kit: URL {
        repoRoot.appendingPathComponent("Kit", isDirectory: true)
    }

    /// Every sprite package anywhere under `Kit/` — discovered rather than
    /// listed, so a new pack is covered by the tests the day it lands.
    static var kitSpritePackages: [URL] {
        guard let walker = FileManager.default.enumerator(
            at: kit, includingPropertiesForKeys: nil
        ) else { return [] }
        return walker
            .compactMap { $0 as? URL }
            .filter { $0.lastPathComponent == "motive.json" }
            .map { $0.deletingLastPathComponent() }
            .sorted { label($0) < label($1) }
    }

    /// A `Kit/packs/<id>/pack.json`, decoded. Nothing in `Sources/` reads these
    /// — the tests are what keep them honest.
    struct Pack: Decodable {
        let id: String
        let title: String
        let blurb: String
        let purpose: String
        let sprite: String
        let profile: String
        let drives: [String]
        let greeting: String

        /// The directory holding `pack.json`; set after decoding.
        var directory: URL = URL(fileURLWithPath: "/")

        private enum CodingKeys: String, CodingKey {
            case id, title, blurb, purpose, sprite, profile, drives, greeting
        }
    }

    static var packs: [Pack] {
        let root = kit.appendingPathComponent("packs", isDirectory: true)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        return contents.compactMap { directory -> Pack? in
            let manifest = directory.appendingPathComponent("pack.json")
            guard let data = try? Data(contentsOf: manifest),
                  var pack = try? JSONDecoder().decode(Pack.self, from: data) else { return nil }
            pack.directory = directory
            return pack
        }.sorted { $0.id < $1.id }
    }

    /// A repo-relative path, so a failure message names something greppable.
    static func label(_ url: URL) -> String {
        url.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
    }

    /// GitHub's heading-anchor rules, enough of them to match a `## Heading`
    /// against a `pack.json` `profile` slug.
    static func slug(_ heading: String) -> String {
        let stripped = heading.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" }
        return stripped.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "-")
    }
}
