import XCTest
@testable import MotiveCore

final class MotiveEngineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func makeEngine() -> MotiveEngine {
        MotiveEngine(definition: BehaviorDefinition(
            states: [
                "idle": StateBehavior(name: "idle", frameDurations: [0.1, 0.1]),
                "running": StateBehavior(name: "running", frameDurations: [0.1, 0.1]),
            ]
        ))
    }

    func testEventsStreamStartsWithCurrentState() async {
        let engine = makeEngine()
        var iterator = await engine.events().makeAsyncIterator()
        guard case .stateChanged(let directive) = await iterator.next() else {
            return XCTFail("expected initial state event")
        }
        XCTAssertEqual(directive.stateName, "idle")
    }

    func testStateChangeBroadcasts() async {
        let engine = makeEngine()
        var iterator = await engine.events().makeAsyncIterator()
        _ = await iterator.next() // initial state
        await engine.requestState("running", now: t0)
        guard case .stateChanged(let directive) = await iterator.next() else {
            return XCTFail("expected state change event")
        }
        XCTAssertEqual(directive.stateName, "running")
    }

    func testSpeechPostAndTTLExpiry() async {
        let engine = makeEngine()
        let bubble = await engine.say("hello", ttl: 5, now: t0)
        XCTAssertEqual(bubble.text, "hello")
        let current = await engine.speech
        XCTAssertEqual(current?.id, bubble.id)

        await engine.tick(now: t0.addingTimeInterval(4))
        let stillUp = await engine.speech
        XCTAssertNotNil(stillUp)

        await engine.tick(now: t0.addingTimeInterval(5.1))
        let gone = await engine.speech
        XCTAssertNil(gone)
    }

    func testSpeechTruncatedToMaxLength() async {
        let engine = makeEngine()
        let bubble = await engine.say(String(repeating: "a", count: 10_000), now: t0)
        XCTAssertEqual(bubble.text.count, SpeechBubble.maxLength)
    }

    // MARK: scripts

    private func collectEvents(_ engine: MotiveEngine, count: Int) async -> Task<[MotiveEvent], Never> {
        let stream = await engine.events()
        return Task {
            var received: [MotiveEvent] = []
            for await event in stream {
                received.append(event)
                if received.count >= count { break }
            }
            return received
        }
    }

    func testScriptPlaysThroughOnTicks() async {
        let engine = makeEngine()
        await engine.playScript(ScriptRun(id: "s", steps: [
            .say(text: "step one", holdMS: 1000),
            .setState(name: "running", holdMS: nil),
        ]), now: t0)

        let speech = await engine.speech
        XCTAssertEqual(speech?.text, "step one")
        let running = await engine.isScriptRunning
        XCTAssertTrue(running)

        // Before the hold elapses: nothing moves.
        await engine.tick(now: t0.addingTimeInterval(0.5))
        let midState = await engine.machine.currentStateName
        XCTAssertEqual(midState, "idle")

        // At the hold boundary: bubble expires and the next step runs, in
        // the same tick, in that order.
        await engine.tick(now: t0.addingTimeInterval(1))
        let endState = await engine.machine.currentStateName
        XCTAssertEqual(endState, "running")
        let done = await engine.isScriptRunning
        XCTAssertFalse(done)
    }

    func testScriptDoesNotCancelItself() async {
        // Regression: script-originated say/setState must bypass the
        // cancel-on-mutation hook.
        let engine = makeEngine()
        await engine.playScript(ScriptRun(id: "s", steps: [
            .say(text: "a", holdMS: 1000),
            .say(text: "b", holdMS: 1000),
            .setState(name: "running", holdMS: 500),
            .say(text: "c", holdMS: 1000),
        ]), now: t0)

        await engine.tick(now: t0.addingTimeInterval(1))
        var stillRunning = await engine.isScriptRunning
        XCTAssertTrue(stillRunning, "second say-step cancelled the script")

        await engine.tick(now: t0.addingTimeInterval(2))
        await engine.tick(now: t0.addingTimeInterval(2.5))
        stillRunning = await engine.isScriptRunning
        XCTAssertTrue(stillRunning, "setState step cancelled the script")
        let speech = await engine.speech
        XCTAssertEqual(speech?.text, "c")
    }

    func testExternalCommandCancelsScript() async {
        let engine = makeEngine()
        await engine.playScript(ScriptRun(id: "s", steps: [
            .say(text: "onboarding...", holdMS: 10_000),
            .say(text: "never shown", holdMS: 1000),
        ]), now: t0)

        // User (or agent) speaks over it — script cancels, command wins.
        await engine.say("user message", ttl: 5, now: t0.addingTimeInterval(1))
        let running = await engine.isScriptRunning
        XCTAssertFalse(running)
        let speech = await engine.speech
        XCTAssertEqual(speech?.text, "user message")

        // The dead script's pending step never fires.
        await engine.tick(now: t0.addingTimeInterval(11))
        let after = await engine.speech
        XCTAssertNotEqual(after?.text, "never shown")
    }

    func testScriptEventsBroadcast() async {
        let engine = makeEngine()
        let collector = await collectEvents(engine, count: 6)
        // events() replays current state first (1). Script: started (2),
        // step 0 (3), speech (4), cancelled via external command (5) +
        // speech posted by that command (6).
        await engine.playScript(ScriptRun(id: "sx", steps: [.say(text: "hi", holdMS: 5000)]), now: t0)
        await engine.say("interrupt", now: t0.addingTimeInterval(1))

        let events = await collector.value
        XCTAssertEqual(events[1], .scriptStarted(id: "sx", stepCount: 1))
        XCTAssertEqual(events[2], .scriptStepChanged(id: "sx", index: 0))
        XCTAssertEqual(events[4], .scriptCancelled(id: "sx"))
    }

    func testReplayOverRunningScriptRestarts() async {
        let engine = makeEngine()
        await engine.playScript(ScriptRun(id: "first", steps: [.pause(ms: 10_000)]), now: t0)
        await engine.playScript(ScriptRun(id: "second", steps: [.say(text: "again", holdMS: 1000)]), now: t0.addingTimeInterval(1))
        let speech = await engine.speech
        XCTAssertEqual(speech?.text, "again")
        let running = await engine.isScriptRunning
        XCTAssertTrue(running)
    }

    func testDismissSpeechBroadcasts() async {
        let engine = makeEngine()
        let bubble = await engine.say("bye", now: t0)
        var iterator = await engine.events().makeAsyncIterator()
        _ = await iterator.next() // initial state
        _ = await iterator.next() // current speech replay
        await engine.dismissSpeech()
        guard case .speechDismissed(let id) = await iterator.next() else {
            return XCTFail("expected dismissal event")
        }
        XCTAssertEqual(id, bubble.id)
    }
}
