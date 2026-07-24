import XCTest
@testable import MotiveSprite

final class CodexRunnerTests: XCTestCase {
    // MARK: Salli (the bundled happy-path sprite)

    func testLoadsSalli() throws {
        // Direct: Salli also carries motive.json, which the registry prefers.
        let definition = try CodexRunner().load(Fixtures.salli)
        XCTAssertEqual(definition.format, "codex/1")
        XCTAssertEqual(definition.metadata.id, "salli")
        XCTAssertEqual(definition.metadata.displayName, "Salli")

        let atlas = try XCTUnwrap(definition.atlases["sprite"])
        XCTAssertEqual(atlas.pixelWidth, 4800)
        XCTAssertEqual(atlas.pixelHeight, 1872)

        // All 9 states, each a clean full 25-frame row.
        XCTAssertEqual(definition.states.count, 9)
        let idle = try XCTUnwrap(definition.states["idle"])
        XCTAssertEqual(idle.frames.count, 25)
        XCTAssertEqual(idle.frames[0].rect, FrameRect(x: 0, y: 0, width: 192, height: 208))
        XCTAssertEqual(idle.frames[1].rect.x, 192)
        XCTAssertTrue(idle.loop)

        // Codex vocabulary defaults are synthesized.
        XCTAssertEqual(definition.aliases["working"], "running")
        XCTAssertEqual(definition.triggers["wave"]?.state, "waving")
        XCTAssertEqual(definition.triggers["jump"]?.state, "jumping")
    }

    func testSalliValidatesClean() {
        let findings = CodexRunner().validate(Fixtures.salli)
        XCTAssertTrue(findings.isEmpty, "unexpected findings: \(findings)")
    }

    func testSalliBehaviorDefinitionFeedsStateMachine() throws {
        let definition = try SpriteRunnerRegistry.standard.load(Fixtures.salli)
        let t0 = Date(timeIntervalSince1970: 0)
        var machine = ActorStateMachine(definition: definition.behaviorDefinition, now: t0)
        XCTAssertEqual(machine.currentStateName, "idle")
        guard case .changed = machine.requestState("working", now: t0) else {
            return XCTFail("expected alias 'working' to resolve")
        }
        XCTAssertEqual(machine.currentStateName, "running")
    }

    // MARK: synthetic packages

    private func makePackage(_ manifest: String, includeSheet: Bool = true, file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("motive-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try manifest.data(using: .utf8)!.write(to: dir.appendingPathComponent("pet.json"))
        if includeSheet {
            try Data([0x89]).write(to: dir.appendingPathComponent("spritesheet.png"))
        }
        return dir
    }

    func testPartialRowWithFromOffset() throws {
        // Squirl-style irregular states: sub-ranges of a row.
        let package = try makePackage("""
        {
          "id": "sq", "displayName": "Sq",
          "atlases": { "sprite": { "path": "spritesheet.png", "cell": [192, 208], "grid": [25, 9] } },
          "states": {
            "idle": { "atlas": "sprite", "row": 0, "frames": 17, "from": 4, "ms": \(Array(repeating: 100, count: 17)), "loop": true },
            "running": { "atlas": "sprite", "row": 1, "frames": 12, "from": 13, "ms": \(Array(repeating: 70, count: 12)), "loop": true }
          }
        }
        """)
        let definition = try SpriteRunnerRegistry.standard.load(package)
        let idle = try XCTUnwrap(definition.states["idle"])
        XCTAssertEqual(idle.frames.count, 17)
        XCTAssertEqual(idle.frames[0].rect.x, 4 * 192)
        let running = try XCTUnwrap(definition.states["running"])
        XCTAssertEqual(running.frames[0].rect.x, 13 * 192)
        XCTAssertEqual(running.frames.last?.rect.x, 24 * 192)
    }

    func testBareCodexManifestResolvesDefaultContract() throws {
        let package = try makePackage("""
        { "id": "bare", "displayName": "Bare", "spritesheetPath": "spritesheet.png" }
        """)
        let definition = try SpriteRunnerRegistry.standard.load(package)
        XCTAssertEqual(definition.states.count, 9)
        let idle = try XCTUnwrap(definition.states["idle"])
        XCTAssertEqual(idle.frames.count, 6)
        XCTAssertEqual(idle.frames[0].rect, FrameRect(x: 0, y: 0, width: 192, height: 208))
        XCTAssertEqual(definition.states["review"]?.frames.first?.rect.y, 8 * 208)
    }

    func testUnknownKeysAreTolerated() throws {
        let package = try makePackage("""
        {
          "id": "x", "displayName": "X", "spritesheetPath": "spritesheet.png",
          "someFutureField": {"nested": true}
        }
        """)
        XCTAssertNoThrow(try SpriteRunnerRegistry.standard.load(package))
    }

    func testRowOutOfBoundsIsLoudError() throws {
        let package = try makePackage("""
        {
          "id": "x", "displayName": "X",
          "atlases": { "sprite": { "path": "spritesheet.png", "cell": [192, 208], "grid": [25, 9] } },
          "states": { "idle": { "atlas": "sprite", "row": 9, "frames": 5 } }
        }
        """)
        XCTAssertThrowsError(try SpriteRunnerRegistry.standard.load(package)) { error in
            XCTAssertTrue("\(error)".contains("row"), "unhelpful error: \(error)")
        }
    }

    func testFramesOverflowingColumnsIsLoudError() throws {
        let package = try makePackage("""
        {
          "id": "x", "displayName": "X",
          "atlases": { "sprite": { "path": "spritesheet.png", "cell": [192, 208], "grid": [25, 9] } },
          "states": { "idle": { "atlas": "sprite", "row": 0, "frames": 20, "from": 10 } }
        }
        """)
        XCTAssertThrowsError(try SpriteRunnerRegistry.standard.load(package))
    }

    func testMsCountMismatchIsLoudError() throws {
        let package = try makePackage("""
        {
          "id": "x", "displayName": "X",
          "atlases": { "sprite": { "path": "spritesheet.png", "cell": [192, 208], "grid": [25, 9] } },
          "states": { "idle": { "atlas": "sprite", "row": 0, "frames": 5, "ms": [100, 100] } }
        }
        """)
        XCTAssertThrowsError(try SpriteRunnerRegistry.standard.load(package))
    }

    func testMissingAtlasImageIsError() throws {
        let package = try makePackage("""
        { "id": "x", "displayName": "X", "spritesheetPath": "spritesheet.png" }
        """, includeSheet: false)
        let findings = CodexRunner().validate(package)
        XCTAssertTrue(findings.contains { $0.code == "atlas-file-missing" && $0.severity == .error })
    }

    func testPathEscapeIsRejected() throws {
        let package = try makePackage("""
        { "id": "x", "displayName": "X", "spritesheetPath": "../../etc/passwd" }
        """)
        let findings = CodexRunner().validate(package)
        XCTAssertTrue(findings.contains { $0.code == "atlas-path-escapes" })
    }

    func testMissingManifestMeansRunnerDoesNotClaim() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("motive-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(CodexRunner.claims(dir))
        XCTAssertThrowsError(try SpriteRunnerRegistry.standard.load(dir)) { error in
            guard case SpriteLoadError.manifestNotFound = error else {
                return XCTFail("expected manifestNotFound, got \(error)")
            }
        }
    }
}
