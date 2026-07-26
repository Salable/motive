import XCTest
@testable import MotiveSprite

/// The starter kit is documentation people copy rather than read, so it is
/// pinned like documentation with teeth: both packages must load clean, and
/// both must implement the vocabulary `docs/reference/STATE-PROFILES.md`
/// promises — including the aliases an agent that has never seen them will use.
final class StarterKitTests: XCTestCase {
    /// The spine of `docs/reference/STATE-PROFILES.md`, plus the two states
    /// behind the standard gestures.
    private let requiredStates = [
        "idle", "thinking", "working", "waiting", "review", "failed",
        "waving", "jumping", "sleeping",
    ]

    private let requiredAliases = ["running", "busy", "done", "error", "blocked", "asleep"]

    func testStarterPackagesLoadWithoutFindings() throws {
        // Discovered, not listed — so assert the kit is actually there before
        // the loops below pass by finding nothing.
        XCTAssertEqual(
            Fixtures.starterPackages.map(\.lastPathComponent), ["pip", "template"]
        )
        for package in Fixtures.starterPackages {
            let findings = MotiveRunner().validate(package)
            XCTAssertTrue(
                findings.isEmpty,
                "\(package.lastPathComponent): \(findings.map(\.message).joined(separator: "; "))"
            )
            XCTAssertNoThrow(try MotiveRunner().load(package), package.lastPathComponent)
        }
    }

    func testStarterPackagesCoverTheDocumentedVocabulary() throws {
        for package in Fixtures.starterPackages {
            let definition = try MotiveRunner().load(package)
            let name = package.lastPathComponent
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

    /// `purpose` is surfaced verbatim in `/v1/schema`, so a starter package
    /// shipping a state without one teaches the wrong habit.
    func testEveryStarterStateExplainsItself() throws {
        for package in Fixtures.starterPackages {
            let definition = try MotiveRunner().load(package)
            for (name, state) in definition.states {
                XCTAssertFalse(
                    (state.purpose ?? "").isEmpty,
                    "\(package.lastPathComponent) state '\(name)' has no purpose string"
                )
            }
        }
    }

    /// Both packages share one atlas geometry on purpose: the template is
    /// tracing paper for the character, and art traced on a different grid
    /// would not line up.
    func testBothStarterPackagesShareTheSameGrid() throws {
        let geometries = try Fixtures.starterPackages.map { package -> [Int] in
            let atlas = try XCTUnwrap(MotiveRunner().load(package).atlases["sprite"])
            return [atlas.pixelWidth, atlas.pixelHeight]
        }
        XCTAssertEqual(Set(geometries.map { $0 }).count, 1, "starter atlases disagree: \(geometries)")
        XCTAssertEqual(geometries.first, [1024, 1152])
    }
}
