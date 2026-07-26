import XCTest
@testable import MotiveSprite

final class MotiveRunnerTests: XCTestCase {
    // MARK: Winston (the bundled happy-path sprite)

    func testLoadsWinston() throws {
        let definition = try MotiveRunner().load(Fixtures.winston)
        XCTAssertEqual(definition.format, "motive/1")
        XCTAssertEqual(definition.metadata.id, "winston")
        XCTAssertEqual(definition.metadata.displayName, "Winston")

        let atlas = try XCTUnwrap(definition.atlases["sprite"])
        XCTAssertEqual(atlas.pixelWidth, 4800)
        XCTAssertEqual(atlas.pixelHeight, 1872)

        // All 9 states, each a clean full 25-frame row.
        XCTAssertEqual(definition.states.count, 9)
        let idle = try XCTUnwrap(definition.states["idle"])
        XCTAssertEqual(idle.frames.count, 25)
        XCTAssertEqual(idle.frames[0].rect, FrameRect(x: 0, y: 0, width: 192, height: 208))
        XCTAssertEqual(idle.frames[1].rect.x, 192)
        XCTAssertEqual(idle.frames[0].duration, 0.1)
        XCTAssertTrue(idle.loop)
        XCTAssertEqual(definition.states["waving"]?.interrupt, .afterLoop)

        // Winston declares his full vocabulary, incl. the dash gestures.
        XCTAssertEqual(definition.aliases["working"], "running")
        XCTAssertEqual(definition.triggers["wave"]?.state, "waving")
        XCTAssertEqual(definition.triggers["jump"]?.state, "jumping")
        XCTAssertEqual(definition.triggers["dash-left"]?.state, "running-left")
        XCTAssertEqual(definition.triggers["dash-right"]?.state, "running-right")
        XCTAssertEqual(definition.triggers["dash-left"]?.once, true)
    }

    func testRegistryLoadsWinstonAsMotiveFormat() throws {
        let definition = try SpriteRunnerRegistry.standard.load(Fixtures.winston)
        XCTAssertEqual(definition.format, "motive/1")
        XCTAssertEqual(definition.metadata.license, "MIT")
    }

    func testWinstonMotiveValidatesClean() {
        let findings = MotiveRunner().validate(Fixtures.winston)
        XCTAssertTrue(findings.isEmpty, "unexpected findings: \(findings)")
    }

    func testWinstonBehaviorDefinitionFeedsStateMachine() throws {
        let definition = try SpriteRunnerRegistry.standard.load(Fixtures.winston)
        let t0 = Date(timeIntervalSince1970: 0)
        var machine = ActorStateMachine(definition: definition.behaviorDefinition, now: t0)
        XCTAssertEqual(machine.currentStateName, "idle")
        guard case .changed = machine.requestState("working", now: t0) else {
            return XCTFail("expected alias 'working' to resolve")
        }
        XCTAssertEqual(machine.currentStateName, "running")
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

    func testRowOutOfBoundsIsLoudError() throws {
        let package = try makePackage("""
        {
          \(header),
          "atlases": { "sprite": { "path": "spritesheet.png", "cell": [192, 208], "grid": [25, 9] } },
          "states": { "idle": { "frames": { "row": 9, "count": 5 } } }
        }
        """)
        XCTAssertThrowsError(try SpriteRunnerRegistry.standard.load(package)) { error in
            XCTAssertTrue("\(error)".contains("row"), "unhelpful error: \(error)")
        }
    }

    func testFramesOverflowingColumnsIsLoudError() throws {
        let package = try makePackage("""
        {
          \(header),
          "atlases": { "sprite": { "path": "spritesheet.png", "cell": [192, 208], "grid": [25, 9] } },
          "states": { "idle": { "frames": { "row": 0, "count": 20, "from": 10 } } }
        }
        """)
        XCTAssertThrowsError(try SpriteRunnerRegistry.standard.load(package))
    }

    func testMsCountMismatchIsLoudError() throws {
        let package = try makePackage("""
        {
          \(header),
          "atlases": { "sprite": { "path": "spritesheet.png", "cell": [192, 208], "grid": [25, 9] } },
          "states": { "idle": { "frames": { "row": 0, "count": 5 }, "ms": [100, 100] } }
        }
        """)
        XCTAssertThrowsError(try SpriteRunnerRegistry.standard.load(package))
    }

    func testMissingAtlasImageIsError() throws {
        let package = try makePackage("""
        {
          \(header),
          "atlases": { "sprite": { "path": "spritesheet.png", "cell": [10, 10], "grid": [2, 2] } },
          "states": { "idle": { "frames": { "row": 0, "count": 2 } } }
        }
        """, sheets: [])
        let findings = MotiveRunner().validate(package)
        XCTAssertTrue(findings.contains { $0.code == "atlas-file-missing" && $0.severity == .error })
    }

    func testPathEscapeIsRejected() throws {
        let package = try makePackage("""
        {
          \(header),
          "atlases": { "sprite": { "path": "../../etc/passwd", "cell": [10, 10], "grid": [2, 2] } },
          "states": { "idle": { "frames": { "row": 0, "count": 2 } } }
        }
        """)
        let findings = MotiveRunner().validate(package)
        XCTAssertTrue(findings.contains { $0.code == "atlas-path-escapes" })
    }

    func testMissingManifestMeansRunnerDoesNotClaim() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("motive-runner-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(MotiveRunner.claims(dir))
        XCTAssertThrowsError(try SpriteRunnerRegistry.standard.load(dir)) { error in
            guard case SpriteLoadError.manifestNotFound = error else {
                return XCTFail("expected manifestNotFound, got \(error)")
            }
        }
    }
}
