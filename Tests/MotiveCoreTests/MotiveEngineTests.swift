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
        // Queue lifecycle events (itemStarted/finished/drained) surround the
        // state change; scan to it.
        for _ in 0..<4 {
            if case .stateChanged(let directive) = await iterator.next() {
                XCTAssertEqual(directive.stateName, "running")
                return
            }
        }
        XCTFail("expected a state change event")
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

    // MARK: queue

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

    func testQueuedFlowPlaysThroughOnTicks() async throws {
        let engine = makeEngine()
        let receipt = try await engine.enqueue([
            QueueItem(action: .say(text: "step one"), holdMS: 1000),
            QueueItem(action: .setState(name: "running", durationMS: nil)),
        ], now: t0).get()
        XCTAssertEqual(receipt.itemIDs.count, 2)

        let speech = await engine.speech
        XCTAssertEqual(speech?.text, "step one")

        // Before the hold elapses: nothing moves.
        await engine.tick(now: t0.addingTimeInterval(0.5))
        let midState = await engine.machine.currentStateName
        XCTAssertEqual(midState, "idle")

        // At the hold boundary: bubble expires and the next item runs in the
        // same tick.
        await engine.tick(now: t0.addingTimeInterval(1))
        let endState = await engine.machine.currentStateName
        XCTAssertEqual(endState, "running")
        let depth = await engine.queueDepth
        XCTAssertEqual(depth, 0)
    }

    func testDirectSayInterjectsAndFlowContinues() async throws {
        // The queue-first contract: a direct command plays next, and every
        // queued item still flows through — nothing is dropped.
        let engine = makeEngine()
        _ = try await engine.enqueue([
            QueueItem(action: .say(text: "tour part 1"), holdMS: 10_000),
            QueueItem(action: .say(text: "tour part 2"), holdMS: 1000),
        ], now: t0).get()

        // User speaks 1s in: interjection lands immediately.
        await engine.say("user message", ttl: 1, now: t0.addingTimeInterval(1))
        let speech = await engine.speech
        XCTAssertEqual(speech?.text, "user message")
        let depth = await engine.queueDepth
        XCTAssertEqual(depth, 2, "interjection is current; tour part 2 still pending")

        // After the interjection's hold, the tour resumes.
        await engine.tick(now: t0.addingTimeInterval(2))
        let resumed = await engine.speech
        XCTAssertEqual(resumed?.text, "tour part 2")
    }

    func testDirectStateChangeAppliesSynchronously() async {
        let engine = makeEngine()
        let outcome = await engine.requestState("running", now: t0)
        guard case .changed(let directive) = outcome else {
            return XCTFail("expected synchronous state change, got \(outcome)")
        }
        XCTAssertEqual(directive.stateName, "running")
        let state = await engine.machine.currentStateName
        XCTAssertEqual(state, "running")
    }

    func testDirectVerbsRejectUnknownVocabulary() async {
        let engine = makeEngine()
        guard case .rejected(let validStates) = await engine.requestState("zooming", now: t0) else {
            return XCTFail("expected rejection")
        }
        XCTAssertTrue(validStates.contains("idle"))
        guard case .rejected = await engine.fireTrigger("moonwalk", now: t0) else {
            return XCTFail("expected rejection")
        }
    }

    func testFlushDropsPendingAndReportsCount() async throws {
        let engine = makeEngine()
        _ = try await engine.enqueue([
            QueueItem(action: .say(text: "a"), holdMS: 5000),
            QueueItem(action: .say(text: "b"), holdMS: 5000),
            QueueItem(action: .say(text: "c"), holdMS: 5000),
        ], now: t0).get()
        let dropped = await engine.flushQueue(now: t0.addingTimeInterval(1))
        XCTAssertEqual(dropped, 2)
        let depth = await engine.queueDepth
        XCTAssertEqual(depth, 0)
        // The flushed items never play.
        await engine.tick(now: t0.addingTimeInterval(20))
        let speech = await engine.speech
        XCTAssertNotEqual(speech?.text, "b")
    }

    func testClearRevertsToDefaultState() async throws {
        let engine = makeEngine()
        // A scene sets a persistent state, then keeps talking; clearing it
        // mid-say must not leave the sprite stuck in "running".
        _ = try await engine.enqueue([
            QueueItem(action: .setState(name: "running", durationMS: nil)),
            QueueItem(action: .say(text: "narrating"), holdMS: 30_000),
            QueueItem(action: .say(text: "never plays"), holdMS: 1000),
        ], now: t0).get()
        let midState = await engine.machine.currentStateName
        XCTAssertEqual(midState, "running")

        await engine.flushQueue(now: t0.addingTimeInterval(1))
        let cleared = await engine.machine.currentStateName
        XCTAssertEqual(cleared, "idle", "clear returns to the default state")
        let depth = await engine.queueDepth
        XCTAssertEqual(depth, 0)
    }

    func testPlayScriptReplacesWithoutDefaultStateFlash() async throws {
        let engine = makeEngine()
        _ = try await engine.enqueue([
            QueueItem(action: .setState(name: "running", durationMS: nil)),
            QueueItem(action: .say(text: "old scene"), holdMS: 30_000),
        ], now: t0).get()

        // Replacement flushes without the revert: the incoming steps own the
        // state; "running" stands until they change it.
        await engine.playScript(ScriptRun(id: "r", steps: [
            .say(text: "new scene", holdMS: 1000),
        ]), now: t0.addingTimeInterval(1))
        let state = await engine.machine.currentStateName
        XCTAssertEqual(state, "running")
    }

    func testDefaultStateFollowsInitialState() async {
        let engine = MotiveEngine(definition: BehaviorDefinition(
            states: [
                "idle": StateBehavior(name: "idle", frameDurations: [0.1]),
                "perched": StateBehavior(name: "perched", frameDurations: [0.1]),
            ]
        ), initialState: "perched")
        let defaultState = await engine.defaultState
        XCTAssertEqual(defaultState, "perched")

        // Duration auto-revert targets the default state, not hardcoded idle.
        await engine.requestState("idle", duration: 1, now: t0)
        await engine.tick(now: t0.addingTimeInterval(1.1))
        let state = await engine.machine.currentStateName
        XCTAssertEqual(state, "perched")
    }

    func testSkipCurrentAdvancesAndPreservesPending() async throws {
        let engine = makeEngine()
        let receipt = try await engine.enqueue([
            QueueItem(action: .say(text: "a"), holdMS: 10_000),
            QueueItem(action: .say(text: "b"), holdMS: 1000),
        ], now: t0).get()

        let skipped = await engine.skipCurrent(now: t0.addingTimeInterval(1))
        XCTAssertEqual(skipped, receipt.itemIDs[0])
        let speech = await engine.speech
        XCTAssertEqual(speech?.text, "b", "the next item plays immediately")
        let depth = await engine.queueDepth
        XCTAssertEqual(depth, 1)
    }

    func testSkipCurrentDismissesSkippedSayBubble() async throws {
        let engine = makeEngine()
        let collector = await collectEvents(engine, count: 6)
        // events() replays current state (1). Then: itemStarted (2),
        // speechPosted (3); skip dismisses the bubble (4) BEFORE the item
        // finishes (5) and the queue drains (6).
        let receipt = try await engine.enqueue([
            QueueItem(action: .say(text: "solo"), holdMS: 10_000),
        ], now: t0).get()
        await engine.skipCurrent(now: t0.addingTimeInterval(1))

        let events = await collector.value
        guard case .speechDismissed = events[3] else {
            return XCTFail("expected the skipped say's bubble dismissed before itemFinished, got \(events[3])")
        }
        XCTAssertEqual(events[4], .queueItemFinished(id: receipt.itemIDs[0]))
        XCTAssertEqual(events[5], .queueDrained)
        let speech = await engine.speech
        XCTAssertNil(speech)
    }

    func testSkipCurrentWhenIdleIsNoOp() async {
        let engine = makeEngine()
        let skipped = await engine.skipCurrent(now: t0)
        XCTAssertNil(skipped)
        let depth = await engine.queueDepth
        XCTAssertEqual(depth, 0)
    }

    func testQueueEventsBroadcast() async throws {
        let engine = makeEngine()
        let collector = await collectEvents(engine, count: 6)
        // events() replays current state (1). Then: itemStarted (2),
        // speechPosted (3); the boundary tick expires the bubble (4) and
        // finishes + drains the queue (5, 6).
        let receipt = try await engine.enqueue([
            QueueItem(action: .say(text: "hi"), holdMS: 1000),
        ], now: t0).get()
        await engine.tick(now: t0.addingTimeInterval(1))

        let events = await collector.value
        let id = receipt.itemIDs[0]
        XCTAssertEqual(events[1], .queueItemStarted(id: id, remaining: 0))
        XCTAssertEqual(events[4], .queueItemFinished(id: id))
        XCTAssertEqual(events[5], .queueDrained)
    }

    func testPlayScriptReplacesQueue() async throws {
        let engine = makeEngine()
        _ = try await engine.enqueue([
            QueueItem(action: .say(text: "old flow"), holdMS: 10_000),
        ], now: t0).get()
        await engine.playScript(ScriptRun(id: "s", steps: [
            .say(text: "new flow", holdMS: 1000),
        ]), now: t0.addingTimeInterval(1))
        let speech = await engine.speech
        XCTAssertEqual(speech?.text, "new flow")
        let depth = await engine.queueDepth
        XCTAssertEqual(depth, 1)
    }

    func testPlayScriptSurfacesRejection() async throws {
        let engine = makeEngine()
        _ = try await engine.enqueue([
            QueueItem(action: .say(text: "old flow"), holdMS: 10_000),
        ], now: t0).get()

        let result = await engine.playScript(ScriptRun(id: "bad", steps: [
            .setState(name: "no-such-state", holdMS: nil),
        ]), now: t0.addingTimeInterval(1))

        guard case .failure(let failure) = result else {
            return XCTFail("an invalid script must be rejected, got \(result)")
        }
        XCTAssertEqual(failure.error, "unknown_state")
        XCTAssertEqual(failure.valid, ["idle", "running"])
        // The replace-flush already happened — exactly the silent-empty-stage
        // hazard the returned result exists to make visible.
        let depth = await engine.queueDepth
        XCTAssertEqual(depth, 0)
    }

    func testPlayScriptSuccessReturnsReceipt() async throws {
        let engine = makeEngine()
        let receipt = try await engine.playScript(ScriptRun(id: "ok", steps: [
            .say(text: "hello", holdMS: 1000),
            .setState(name: "running", holdMS: nil),
        ]), now: t0).get()
        XCTAssertEqual(receipt.itemIDs.count, 2)
        XCTAssertEqual(receipt.queueDepth, 2)
    }

    func testDismissSpeechDoesNotTouchQueue() async throws {
        let engine = makeEngine()
        _ = try await engine.enqueue([
            QueueItem(action: .say(text: "a"), holdMS: 5000),
            QueueItem(action: .say(text: "b"), holdMS: 5000),
        ], now: t0).get()
        await engine.dismissSpeech(now: t0.addingTimeInterval(1))
        let speech = await engine.speech
        XCTAssertNil(speech)
        let depth = await engine.queueDepth
        XCTAssertEqual(depth, 2, "dismiss is bubble control, not queue control")
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
