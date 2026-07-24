import XCTest
@testable import MotiveCore

final class ScriptPlayerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

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

    // MARK: pure player

    func testPlayEmitsStartedAndFirstStep() {
        var player = ScriptPlayer()
        let run = ScriptRun(id: "s1", steps: [.say(text: "hi", holdMS: 2000)])
        let effects = player.play(run, now: t0)
        XCTAssertEqual(effects, [
            .emit(.started(id: "s1", stepCount: 1)),
            .emit(.stepChanged(id: "s1", index: 0)),
            .perform(.say(text: "hi", ttl: 2)),
        ])
        XCTAssertTrue(player.isRunning)
    }

    func testTickBeforeDeadlineIsQuiet() {
        var player = ScriptPlayer()
        _ = player.play(ScriptRun(id: "s1", steps: [
            .say(text: "hi", holdMS: 2000),
            .say(text: "bye", holdMS: 1000),
        ]), now: t0)
        XCTAssertEqual(player.tick(now: t0.addingTimeInterval(1.9)), [])
    }

    func testTickAtDeadlineAdvancesAndFinishes() {
        var player = ScriptPlayer()
        _ = player.play(ScriptRun(id: "s1", steps: [
            .say(text: "hi", holdMS: 2000),
            .say(text: "bye", holdMS: 1000),
        ]), now: t0)

        let second = player.tick(now: t0.addingTimeInterval(2))
        XCTAssertEqual(second, [
            .emit(.stepChanged(id: "s1", index: 1)),
            .perform(.say(text: "bye", ttl: 1)),
        ])

        let finish = player.tick(now: t0.addingTimeInterval(3))
        XCTAssertEqual(finish, [.emit(.finished(id: "s1"))])
        XCTAssertFalse(player.isRunning)
        XCTAssertEqual(player.tick(now: t0.addingTimeInterval(4)), [])
    }

    func testZeroDurationStepsAdvanceInOneCall() {
        var player = ScriptPlayer()
        let effects = player.play(ScriptRun(id: "s1", steps: [
            .setState(name: "running", holdMS: nil),
            .trigger(name: "wave"),
            .pause(ms: 500),
        ]), now: t0)
        // Both zero-duration steps run immediately; the pause holds.
        XCTAssertEqual(effects, [
            .emit(.started(id: "s1", stepCount: 3)),
            .emit(.stepChanged(id: "s1", index: 0)),
            .perform(.setState(name: "running")),
            .emit(.stepChanged(id: "s1", index: 1)),
            .perform(.trigger(name: "wave")),
            .emit(.stepChanged(id: "s1", index: 2)),
        ])
        XCTAssertTrue(player.isRunning)
        XCTAssertEqual(player.tick(now: t0.addingTimeInterval(0.5)), [.emit(.finished(id: "s1"))])
    }

    func testAllZeroDurationScriptFinishesImmediately() {
        var player = ScriptPlayer()
        let effects = player.play(ScriptRun(id: "s1", steps: [
            .setState(name: "running", holdMS: nil),
        ]), now: t0)
        XCTAssertEqual(effects.last, .emit(.finished(id: "s1")))
        XCTAssertFalse(player.isRunning)
    }

    func testCancelSemantics() {
        var player = ScriptPlayer()
        XCTAssertEqual(player.cancel(now: t0), []) // idle cancel is quiet
        _ = player.play(ScriptRun(id: "s1", steps: [.pause(ms: 5000)]), now: t0)
        XCTAssertEqual(player.cancel(now: t0.addingTimeInterval(1)), [.emit(.cancelled(id: "s1"))])
        XCTAssertFalse(player.isRunning)
        XCTAssertEqual(player.tick(now: t0.addingTimeInterval(10)), [])
    }

    func testPlayOverPlayIsLatestWins() {
        var player = ScriptPlayer()
        _ = player.play(ScriptRun(id: "s1", steps: [.pause(ms: 5000)]), now: t0)
        let effects = player.play(ScriptRun(id: "s2", steps: [.pause(ms: 1000)]), now: t0.addingTimeInterval(1))
        XCTAssertEqual(effects.first, .emit(.cancelled(id: "s1")))
        XCTAssertEqual(player.currentRunID, "s2")
    }

    func testHoldsClampToMax() {
        var player = ScriptPlayer()
        _ = player.play(ScriptRun(id: "s1", steps: [.pause(ms: 10_000_000)]), now: t0)
        XCTAssertEqual(player.tick(now: t0.addingTimeInterval(ScriptPlayer.maxHold - 1)), [])
        XCTAssertEqual(
            player.tick(now: t0.addingTimeInterval(ScriptPlayer.maxHold)),
            [.emit(.finished(id: "s1"))]
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
