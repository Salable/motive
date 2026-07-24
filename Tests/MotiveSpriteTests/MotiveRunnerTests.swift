import XCTest
@testable import MotiveSprite

final class MotiveRunnerTests: XCTestCase {
    // MARK: Salli dual-format equivalence

    func testSalliMotiveAndCodexRunnersAgree() throws {
        let codex = try CodexRunner().load(Fixtures.salli)
        let motive = try MotiveRunner().load(Fixtures.salli)

        XCTAssertEqual(motive.format, "motive/1")
        XCTAssertEqual(Set(codex.states.keys), Set(motive.states.keys))
        for (name, codexState) in codex.states {
            let motiveState = try XCTUnwrap(motive.states[name], "missing state '\(name)'")
            // Geometry and behavior must match exactly; motive/1 may be richer
            // in prose (purpose) and metadata.
            XCTAssertEqual(codexState.frames, motiveState.frames, "frames differ for '\(name)'")
            XCTAssertEqual(codexState.loop, motiveState.loop, "loop differs for '\(name)'")
            XCTAssertEqual(codexState.interrupt, motiveState.interrupt, "interrupt differs for '\(name)'")
            XCTAssertEqual(codexState.then, motiveState.then, "then differs for '\(name)'")
        }
        XCTAssertEqual(codex.aliases, motive.aliases)
        XCTAssertEqual(Set(codex.triggers.keys), Set(motive.triggers.keys))
        for (name, codexTrigger) in codex.triggers {
            XCTAssertEqual(codexTrigger.state, motive.triggers[name]?.state)
            XCTAssertEqual(codexTrigger.once, motive.triggers[name]?.once)
        }
        XCTAssertEqual(codex.transitions, motive.transitions)
        XCTAssertEqual(codex.atlases, motive.atlases)
    }

    func testRegistryPrefersMotiveFormat() throws {
        // Salli has both manifests; motive/1 wins detection.
        let definition = try SpriteRunnerRegistry.standard.load(Fixtures.salli)
        XCTAssertEqual(definition.format, "motive/1")
        XCTAssertEqual(definition.metadata.license, "MIT")
    }

    func testSalliMotiveValidatesClean() {
        let findings = MotiveRunner().validate(Fixtures.salli)
        XCTAssertTrue(findings.isEmpty, "unexpected findings: \(findings)")
    }

    // MARK: synthetic packages

    private func makePackage(_ manifest: String, sheets: [String] = ["spritesheet.png"]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("motive-runner-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try manifest.data(using: .utf8)!.write(to: dir.appendingPathComponent("motive.json"))
        for sheet in sheets {
            try Data([0x89]).write(to: dir.appendingPathComponent(sheet))
        }
        return dir
    }

    private let header = #""format": "motive/1", "metadata": { "id": "t", "name": "T" }"#

    func testCellsLayoutSupportsNonContiguousFrames() throws {
        let package = try makePackage("""
        {
          \(header),
          "atlases": { "sprite": { "path": "spritesheet.png", "cell": [10, 10], "grid": [4, 4] } },
          "states": {
            "idle": { "frames": { "cells": [[0, 0], [3, 2], [1, 1]] }, "ms": [100, 200, 300] }
          }
        }
        """)
        let definition = try MotiveRunner().load(package)
        let idle = try XCTUnwrap(definition.states["idle"])
        XCTAssertEqual(idle.frames.map(\.rect), [
            FrameRect(x: 0, y: 0, width: 10, height: 10),
            FrameRect(x: 30, y: 20, width: 10, height: 10),
            FrameRect(x: 10, y: 10, width: 10, height: 10),
        ])
        XCTAssertEqual(idle.frames.map(\.duration), [0.1, 0.2, 0.3])
    }

    func testRectsLayoutSupportsMultipleAtlasesPerState() throws {
        let package = try makePackage("""
        {
          \(header),
          "atlases": {
            "sprite": { "path": "spritesheet.png", "cell": [10, 10], "grid": [2, 2] },
            "closeup": { "path": "closeup.png", "cell": [50, 50], "grid": [1, 1] }
          },
          "states": {
            "idle": {
              "frames": { "rects": [
                { "x": 0, "y": 0, "w": 10, "h": 10 },
                { "x": 0, "y": 0, "w": 50, "h": 50, "atlas": "closeup" }
              ] },
              "ms": 100
            }
          }
        }
        """, sheets: ["spritesheet.png", "closeup.png"])
        let definition = try MotiveRunner().load(package)
        let idle = try XCTUnwrap(definition.states["idle"])
        XCTAssertEqual(idle.frames[0].atlasKey, "sprite")
        XCTAssertEqual(idle.frames[1].atlasKey, "closeup")
        XCTAssertEqual(idle.frames[1].rect.width, 50)
    }

    func testUniformMsShorthandAndRowCountFromMsArray() throws {
        let package = try makePackage("""
        {
          \(header),
          "atlases": { "sprite": { "path": "spritesheet.png", "cell": [10, 10], "grid": [8, 2] } },
          "states": {
            "a": { "frames": { "row": 0, "count": 4 }, "ms": 90 },
            "b": { "frames": { "row": 1 }, "ms": [50, 60, 70] }
          }
        }
        """)
        let definition = try MotiveRunner().load(package)
        XCTAssertEqual(definition.states["a"]?.frames.map(\.duration), [0.09, 0.09, 0.09, 0.09])
        XCTAssertEqual(definition.states["b"]?.frames.count, 3)
    }

    func testMissingFormatFieldIsLoudError() throws {
        let package = try makePackage("""
        {
          "metadata": { "id": "t" },
          "atlases": { "sprite": { "path": "spritesheet.png", "cell": [10, 10], "grid": [2, 2] } },
          "states": { "idle": { "frames": { "row": 0, "count": 2 } } }
        }
        """)
        XCTAssertThrowsError(try MotiveRunner().load(package)) { error in
            XCTAssertTrue("\(error)".contains("format"), "unhelpful error: \(error)")
        }
    }

    func testAmbiguousFrameLayoutRejected() throws {
        let package = try makePackage("""
        {
          \(header),
          "atlases": { "sprite": { "path": "spritesheet.png", "cell": [10, 10], "grid": [4, 4] } },
          "states": { "idle": { "frames": { "row": 0, "count": 2, "cells": [[0, 0]] } } }
        }
        """)
        let findings = MotiveRunner().validate(package)
        XCTAssertTrue(findings.contains { $0.code == "state-frames-ambiguous" })
    }

    func testRectOutsideAtlasRejected() throws {
        let package = try makePackage("""
        {
          \(header),
          "atlases": { "sprite": { "path": "spritesheet.png", "cell": [10, 10], "grid": [2, 2] } },
          "states": { "idle": { "frames": { "rects": [{ "x": 15, "y": 0, "w": 10, "h": 10 }] } } }
        }
        """)
        let findings = MotiveRunner().validate(package)
        XCTAssertTrue(findings.contains { $0.code == "state-rect-invalid" })
    }

    func testThenChainAndTriggersValidated() throws {
        let package = try makePackage("""
        {
          \(header),
          "atlases": { "sprite": { "path": "spritesheet.png", "cell": [10, 10], "grid": [4, 2] } },
          "states": {
            "intro": { "frames": { "row": 0, "count": 2 }, "loop": false, "then": "nowhere" }
          },
          "triggers": { "boop": { "state": "missing" } }
        }
        """)
        let findings = MotiveRunner().validate(package)
        XCTAssertTrue(findings.contains { $0.code == "then-unknown-state" })
        XCTAssertTrue(findings.contains { $0.code == "trigger-unknown-state" })
    }

    func testUnknownKeysAreTolerated() throws {
        let package = try makePackage("""
        {
          \(header),
          "futureTopLevelThing": [1, 2, 3],
          "atlases": { "sprite": { "path": "spritesheet.png", "cell": [10, 10], "grid": [2, 2] } },
          "states": { "idle": { "frames": { "row": 0, "count": 2 }, "someday": true } }
        }
        """)
        XCTAssertNoThrow(try MotiveRunner().load(package))
    }
}
