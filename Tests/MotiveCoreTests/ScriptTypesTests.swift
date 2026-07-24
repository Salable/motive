import XCTest
@testable import MotiveCore

/// Wire-format and validation tests for the ScriptStep/ScriptRun DTOs.
/// (The ScriptPlayer struct was replaced by ActionQueue — see
/// ActionQueueTests for sequencing behavior.)
final class ScriptTypesTests: XCTestCase {
    private func makeDefinition() -> BehaviorDefinition {
        BehaviorDefinition(
            states: [
                "idle": StateBehavior(name: "idle", frameDurations: [0.1]),
                "running": StateBehavior(name: "running", frameDurations: [0.1]),
                "waving": StateBehavior(name: "waving", frameDurations: [0.1]),
            ],
            triggers: ["wave": TriggerSpec(state: "waving")]
        )
    }

    // MARK: validation

    func testValidationCatchesUnknownVocabulary() {
        let definition = makeDefinition()
        XCTAssertNil(ScriptRun(steps: [.setState(name: "running", holdMS: nil)]).validate(against: definition))

        let badState = ScriptRun(steps: [.setState(name: "zooming", holdMS: nil)]).validate(against: definition)
        XCTAssertEqual(badState?.error, "unknown_state")
        XCTAssertEqual(badState?.valid?.contains("idle"), true)

        let badTrigger = ScriptRun(steps: [.trigger(name: "moonwalk")]).validate(against: definition)
        XCTAssertEqual(badTrigger?.error, "unknown_trigger")

        XCTAssertEqual(ScriptRun(steps: []).validate(against: definition)?.error, "empty_script")

        let long = ScriptRun(steps: Array(repeating: .pause(ms: 1), count: ScriptRun.maxSteps + 1))
        XCTAssertEqual(long.validate(against: definition)?.error, "script_too_long")
    }

    // MARK: Codable wire format

    func testStepsDecodeFromWireJSON() throws {
        let json = """
        {"steps": [
            {"type": "say", "text": "hi"},
            {"type": "say", "text": "long", "hold": 6000},
            {"type": "setState", "name": "running", "hold": 1500},
            {"type": "state", "name": "idle"},
            {"type": "trigger", "name": "wave"},
            {"type": "pause", "ms": 800}
        ]}
        """
        let run = try JSONDecoder().decode(ScriptRun.self, from: Data(json.utf8))
        XCTAssertEqual(run.steps, [
            .say(text: "hi", holdMS: ScriptStep.defaultSayHoldMS),
            .say(text: "long", holdMS: 6000),
            .setState(name: "running", holdMS: 1500),
            .setState(name: "idle", holdMS: nil),
            .trigger(name: "wave"),
            .pause(ms: 800),
        ])
    }

    func testStepsRoundTripThroughEncoding() throws {
        let original = ScriptRun(id: "r", steps: [
            .say(text: "a \"quoted\" bit", holdMS: 100),
            .setState(name: "running", holdMS: nil),
            .trigger(name: "wave"),
            .pause(ms: 5),
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ScriptRun.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testUnknownStepTypeFailsLoudly() {
        let json = #"{"steps": [{"type": "dance"}]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(ScriptRun.self, from: Data(json.utf8))) { error in
            XCTAssertTrue("\(error)".contains("dance"), "unhelpful error: \(error)")
        }
    }
}
