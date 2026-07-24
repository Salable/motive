import XCTest
@testable import MotiveCore

final class ActionQueueTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func makeDefinition() -> BehaviorDefinition {
        BehaviorDefinition(
            states: [
                "idle": StateBehavior(name: "idle", frameDurations: [0.1]),
                "running": StateBehavior(name: "running", frameDurations: [0.1]),
                // waving loops in 0.5s — the trigger default hold.
                "waving": StateBehavior(name: "waving", frameDurations: [0.25, 0.25]),
            ],
            triggers: ["wave": TriggerSpec(state: "waving")]
        )
    }

    private func makeQueue() -> ActionQueue {
        ActionQueue(definition: makeDefinition())
    }

    private func ids(_ effects: [ActionQueue.Effect]) -> [String] {
        effects.compactMap {
            if case .emit(.itemStarted(let id, _)) = $0 { return id }
            return nil
        }
    }

    // MARK: starting + ordering

    func testEnqueueOnIdleStartsImmediately() throws {
        var queue = makeQueue()
        let item = QueueItem(action: .say(text: "hi"), holdMS: 2000)
        let effects = try queue.enqueue([item], now: t0).get()
        XCTAssertEqual(effects, [
            .emit(.itemStarted(id: item.id, remaining: 0)),
            .perform(.say(text: "hi", ttl: 2)),
        ])
        XCTAssertTrue(queue.isActive)
        XCTAssertEqual(queue.depth, 1)
    }

    func testTailAppendWhileRunningPreservesOrder() throws {
        var queue = makeQueue()
        let first = QueueItem(action: .say(text: "one"), holdMS: 1000)
        let second = QueueItem(action: .say(text: "two"), holdMS: 1000)
        _ = try queue.enqueue([first], now: t0).get()
        let appendEffects = try queue.enqueue([second], now: t0.addingTimeInterval(0.1)).get()
        XCTAssertEqual(appendEffects, [], "appending behind a running item performs nothing yet")
        XCTAssertEqual(queue.depth, 2)

        let advance = queue.tick(now: t0.addingTimeInterval(1))
        XCTAssertEqual(advance, [
            .emit(.itemFinished(id: first.id)),
            .emit(.itemStarted(id: second.id, remaining: 0)),
            .perform(.say(text: "two", ttl: 1)),
        ])
    }

    func testHeadInsertionCutsCurrentHoldAndPreservesRest() throws {
        var queue = makeQueue()
        let tour1 = QueueItem(action: .say(text: "tour step 1"), holdMS: 10_000)
        let tour2 = QueueItem(action: .say(text: "tour step 2"), holdMS: 1000)
        _ = try queue.enqueue([tour1, tour2], now: t0).get()

        // User interjects 1s in: plays immediately, tour2 still follows.
        let interjection = QueueItem(action: .say(text: "hello!"), holdMS: 1000)
        let effects = try queue.enqueue([interjection], at: .head, now: t0.addingTimeInterval(1)).get()
        XCTAssertEqual(effects, [
            .emit(.itemFinished(id: tour1.id)),
            .emit(.itemStarted(id: interjection.id, remaining: 1)),
            .perform(.say(text: "hello!", ttl: 1)),
        ])

        // Tour resumes after the interjection's hold.
        let resume = queue.tick(now: t0.addingTimeInterval(2))
        XCTAssertEqual(ids(resume), [tour2.id])
        XCTAssertEqual(queue.tick(now: t0.addingTimeInterval(3)), [
            .emit(.itemFinished(id: tour2.id)),
            .emit(.drained),
        ])
        XCTAssertFalse(queue.isActive)
    }

    // MARK: holds

    func testDefaultHolds() throws {
        var queue = makeQueue()
        let say = QueueItem(action: .say(text: "hi"))
        _ = try queue.enqueue([say], now: t0).get()
        // Default say hold is 4000ms: not due at 3.9, due at 4.
        XCTAssertEqual(queue.tick(now: t0.addingTimeInterval(3.9)), [])
        XCTAssertEqual(queue.tick(now: t0.addingTimeInterval(4)).first, .emit(.itemFinished(id: say.id)))
    }

    func testTriggerDefaultsToGestureLoopDuration() throws {
        var queue = makeQueue()
        let wave = QueueItem(action: .trigger(name: "wave"))
        let after = QueueItem(action: .say(text: "done"), holdMS: 1000)
        _ = try queue.enqueue([wave, after], now: t0).get()
        // waving loop is 0.5s — the queue occupies exactly that long.
        XCTAssertEqual(queue.tick(now: t0.addingTimeInterval(0.4)), [])
        let advance = queue.tick(now: t0.addingTimeInterval(0.5))
        XCTAssertEqual(advance.first, .emit(.itemFinished(id: wave.id)))
        XCTAssertEqual(ids(advance), [after.id])
    }

    func testZeroHoldChainingExecutesInOneCall() throws {
        var queue = makeQueue()
        let state = QueueItem(action: .setState(name: "running", durationMS: nil))
        let say = QueueItem(action: .say(text: "working"), holdMS: 1000)
        let effects = try queue.enqueue([state, say], now: t0).get()
        // setState (hold 0) and say land together — visually simultaneous.
        XCTAssertEqual(effects, [
            .emit(.itemStarted(id: state.id, remaining: 1)),
            .perform(.setState(name: "running", duration: nil)),
            .emit(.itemFinished(id: state.id)),
            .emit(.itemStarted(id: say.id, remaining: 0)),
            .perform(.say(text: "working", ttl: 1)),
        ])
    }

    func testAllZeroHoldBatchDrainsInOneCall() throws {
        var queue = makeQueue()
        let a = QueueItem(action: .setState(name: "running", durationMS: nil))
        let b = QueueItem(action: .setState(name: "idle", durationMS: nil))
        let effects = try queue.enqueue([a, b], now: t0).get()
        XCTAssertEqual(effects.last, .emit(.drained))
        XCTAssertFalse(queue.isActive)
        XCTAssertEqual(queue.depth, 0)
    }

    func testHoldsClampToMax() throws {
        var queue = makeQueue()
        let long = QueueItem(action: .pause, holdMS: 10_000_000)
        _ = try queue.enqueue([long], now: t0).get()
        XCTAssertEqual(queue.tick(now: t0.addingTimeInterval(ActionQueue.maxHold - 1)), [])
        XCTAssertEqual(queue.tick(now: t0.addingTimeInterval(ActionQueue.maxHold)), [
            .emit(.itemFinished(id: long.id)),
            .emit(.drained),
        ])
    }

    // MARK: validation + caps

    func testInvalidItemRejectsWholeBatch() {
        var queue = makeQueue()
        let good = QueueItem(action: .say(text: "fine"))
        let bad = QueueItem(action: .setState(name: "zooming", durationMS: nil))
        let result = queue.enqueue([good, bad], now: t0)
        guard case .failure(let failure) = result else {
            return XCTFail("expected rejection")
        }
        XCTAssertEqual(failure.error, "unknown_state")
        XCTAssertEqual(failure.valid?.contains("idle"), true)
        XCTAssertEqual(queue.depth, 0, "queue must be untouched after a rejected batch")
    }

    func testUnknownTriggerAndInvalidPauseRejected() {
        var queue = makeQueue()
        guard case .failure(let trigger) = queue.enqueue([QueueItem(action: .trigger(name: "moonwalk"))], now: t0) else {
            return XCTFail("expected rejection")
        }
        XCTAssertEqual(trigger.error, "unknown_trigger")
        guard case .failure(let pause) = queue.enqueue([QueueItem(action: .pause)], now: t0) else {
            return XCTFail("expected rejection")
        }
        XCTAssertEqual(pause.error, "invalid_items")
    }

    func testEmptyBatchRejected() {
        var queue = makeQueue()
        guard case .failure(let failure) = queue.enqueue([], now: t0) else {
            return XCTFail("expected rejection")
        }
        XCTAssertEqual(failure.error, "empty_queue_request")
    }

    func testDepthCapIsAllOrNothing() throws {
        var queue = makeQueue()
        let fill = (0..<ActionQueue.maxDepth).map { _ in QueueItem(action: .pause, holdMS: 1000) }
        _ = try queue.enqueue(fill, now: t0).get()
        XCTAssertEqual(queue.depth, ActionQueue.maxDepth)

        guard case .failure(let failure) = queue.enqueue([QueueItem(action: .say(text: "one too many"))], now: t0) else {
            return XCTFail("expected queue_full")
        }
        XCTAssertEqual(failure.error, "queue_full")
        XCTAssertEqual(queue.depth, ActionQueue.maxDepth)
    }

    // MARK: flush + snapshot

    func testFlushMidHoldDropsPendingAndStopsWaiting() throws {
        var queue = makeQueue()
        let a = QueueItem(action: .say(text: "a"), holdMS: 5000)
        let b = QueueItem(action: .say(text: "b"), holdMS: 5000)
        let c = QueueItem(action: .say(text: "c"), holdMS: 5000)
        _ = try queue.enqueue([a, b, c], now: t0).get()

        let effects = queue.flush(now: t0.addingTimeInterval(1))
        XCTAssertEqual(effects, [
            .emit(.itemFinished(id: a.id)),
            .emit(.flushed(dropped: 2)),
        ])
        XCTAssertEqual(queue.depth, 0)
        XCTAssertEqual(queue.tick(now: t0.addingTimeInterval(10)), [])
    }

    func testFlushWhenIdleIsQuiet() {
        var queue = makeQueue()
        XCTAssertEqual(queue.flush(now: t0), [])
    }

    func testSnapshotShowsCurrentRemainingAndPending() throws {
        var queue = makeQueue()
        let a = QueueItem(action: .say(text: "a"), holdMS: 4000)
        let b = QueueItem(action: .trigger(name: "wave"))
        _ = try queue.enqueue([a, b], now: t0).get()

        let snapshot = queue.snapshot(now: t0.addingTimeInterval(1))
        XCTAssertEqual(snapshot.depth, 2)
        XCTAssertEqual(snapshot.current?.id, a.id)
        XCTAssertEqual(snapshot.currentRemaining ?? -1, 3, accuracy: 0.001)
        XCTAssertEqual(snapshot.pending.map(\.id), [b.id])
        XCTAssertEqual(snapshot.pending.first?.step, .trigger(name: "wave"))
    }

    // MARK: wire bridge

    func testScriptStepBridgeRoundTrips() {
        let steps: [ScriptStep] = [
            .say(text: "hi", holdMS: 1234),
            .setState(name: "running", holdMS: 500),
            .trigger(name: "wave"),
            .pause(ms: 800),
        ]
        let items = steps.map(QueueItem.init(step:))
        XCTAssertEqual(items.map(\.step), steps)
        XCTAssertEqual(items[2].holdMS, nil, "bridged triggers keep the default gesture hold")
    }
}
