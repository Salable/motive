import XCTest
@testable import MotiveSprite

/// `Kit/` is material people copy rather than read, and `pack.json` is prose
/// nothing in `Sources/` parses — so these tests are the only thing standing
/// between a pack and a promise it cannot keep. They pin each pack against the
/// art beside it and against the profiles `docs/reference/STATE-PROFILES.md`
/// defines.
final class KitTests: XCTestCase {
    /// The kit's shared vocabulary: the union of every profile in
    /// STATE-PROFILES.md, plus the two states behind the standard gestures.
    private let requiredStates = [
        "idle", "thinking", "working", "waiting", "review", "failed",
        "waving", "jumping", "sleeping",
    ]

    private let requiredAliases = ["running", "busy", "done", "error", "blocked", "asleep"]

    func testKitSpritePackagesLoadWithoutFindings() throws {
        // Discovered, not listed — so assert the kit is actually there before
        // the loops below pass by finding nothing.
        XCTAssertEqual(
            Fixtures.kitSpritePackages.map { Fixtures.label($0) },
            ["Kit/components/sprites/grid-template",
             "Kit/packs/caret/sprite",
             "Kit/packs/pip/sprite"]
        )
        for package in Fixtures.kitSpritePackages {
            let findings = MotiveRunner().validate(package)
            XCTAssertTrue(
                findings.isEmpty,
                "\(Fixtures.label(package)): \(findings.map(\.message).joined(separator: "; "))"
            )
            XCTAssertNoThrow(try MotiveRunner().load(package), Fixtures.label(package))
        }
    }

    func testKitSpritePackagesCoverTheSharedVocabulary() throws {
        for package in Fixtures.kitSpritePackages {
            let definition = try MotiveRunner().load(package)
            let name = Fixtures.label(package)
            for state in requiredStates {
                XCTAssertNotNil(definition.states[state], "\(name) is missing state '\(state)'")
            }
            for alias in requiredAliases {
                let target = definition.aliases[alias]
                XCTAssertNotNil(target, "\(name) is missing alias '\(alias)'")
                XCTAssertNotNil(
                    target.flatMap { definition.states[$0] },
                    "\(name) alias '\(alias)' resolves to nothing"
                )
            }
            for trigger in ["wave", "jump"] {
                XCTAssertNotNil(definition.triggers[trigger], "\(name) is missing trigger '\(trigger)'")
            }
        }
    }

    /// `purpose` is surfaced verbatim in `/v1/schema`, so a kit package
    /// shipping a state without one teaches the wrong habit.
    func testEveryKitStateExplainsItself() throws {
        for package in Fixtures.kitSpritePackages {
            let definition = try MotiveRunner().load(package)
            for (name, state) in definition.states {
                XCTAssertFalse(
                    (state.purpose ?? "").isEmpty,
                    "\(Fixtures.label(package)) state '\(name)' has no purpose string"
                )
            }
        }
    }

    /// Every package draws on one grid on purpose: the tracing template is
    /// useless against a different lattice, and swapping packs in an assembled
    /// app is only a directory copy while the geometry agrees.
    func testEveryKitPackageSharesTheSameGrid() throws {
        let geometries = try Fixtures.kitSpritePackages.map { package -> [Int] in
            let atlas = try XCTUnwrap(MotiveRunner().load(package).atlases["sprite"])
            return [atlas.pixelWidth, atlas.pixelHeight]
        }
        XCTAssertEqual(Set(geometries).count, 1, "kit atlases disagree: \(geometries)")
        XCTAssertEqual(geometries.first, [1024, 1152])
    }

    // MARK: pack manifests

    func testPacksAreDiscoverable() {
        XCTAssertEqual(Fixtures.packs.map(\.id), ["caret", "pip"])
    }

    /// A pack's `drives` list is its promise to an assembled app: these are the
    /// states the app will set. Every one has to resolve in the art it ships.
    func testEveryPackDrivesStatesItsSpriteHas() throws {
        for pack in Fixtures.packs {
            let spriteURL = pack.directory.appendingPathComponent(pack.sprite, isDirectory: true)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: spriteURL.appendingPathComponent("motive.json").path),
                "pack '\(pack.id)' sprite '\(pack.sprite)' is not a sprite package"
            )
            let definition = try MotiveRunner().load(spriteURL)
            XCTAssertFalse(pack.drives.isEmpty, "pack '\(pack.id)' drives nothing")
            for state in pack.drives {
                let resolved = definition.aliases[state] ?? state
                XCTAssertNotNil(
                    definition.states[resolved],
                    "pack '\(pack.id)' drives '\(state)', which its sprite does not declare"
                )
            }
        }
    }

    /// `profile` points at a section of the state-profiles page. A pack naming
    /// a profile the docs do not define sends its reader nowhere, and nothing
    /// else would notice, because it is a field rather than a link.
    func testEveryPackNamesAProfileTheDocsDefine() throws {
        let page = Fixtures.repoRoot.appendingPathComponent("docs/reference/STATE-PROFILES.md")
        let markdown = try String(contentsOf: page, encoding: .utf8)
        let slugs = Set(markdown
            .components(separatedBy: .newlines)
            .filter { $0.hasPrefix("## ") }
            .map { Fixtures.slug(String($0.dropFirst(3))) })

        for pack in Fixtures.packs {
            XCTAssertTrue(
                slugs.contains(pack.profile),
                "pack '\(pack.id)' claims profile '\(pack.profile)'; the page defines \(slugs.sorted())"
            )
        }
    }

    /// The prose is why a pack is material rather than a directory of PNGs:
    /// without it nobody can tell what the companion is *for*.
    func testEveryPackSaysWhatItIsFor() {
        for pack in Fixtures.packs {
            XCTAssertFalse(pack.title.isEmpty, "pack '\(pack.id)' has no title")
            XCTAssertFalse(pack.blurb.isEmpty, "pack '\(pack.id)' has no blurb")
            XCTAssertFalse(pack.purpose.isEmpty, "pack '\(pack.id)' has no purpose")
            XCTAssertFalse(pack.greeting.isEmpty, "pack '\(pack.id)' has no greeting")
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: pack.directory.appendingPathComponent("README.md").path),
                "pack '\(pack.id)' has no README"
            )
        }
    }
}
