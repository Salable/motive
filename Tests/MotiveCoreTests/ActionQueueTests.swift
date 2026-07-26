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
            .perform(.say(id: item.id, text: "hi", ttl: 2, respond: nil)),
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
            .perform(.say(id: second.id, text: "two", ttl: 1, respond: nil)),
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
            .perform(.say(id: interjection.id, text: "hello!", ttl: 1, respond: nil)),
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
            .perform(.say(id: say.id, text: "working", ttl: 1, respond: nil)),
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

    // MARK: skip

    func testSkipEndsCurrentAndStartsNextPreservingPending() throws {
        var queue = makeQueue()
        let a = QueueItem(action: .say(text: "a"), holdMS: 5000)
        let b = QueueItem(action: .say(text: "b"), holdMS: 1000)
        _ = try queue.enqueue([a, b], now: t0).get()

        let effects = queue.skip(now: t0.addingTimeInterval(1))
        XCTAssertEqual(effects, [
            .emit(.itemFinished(id: a.id)),
            .emit(.itemStarted(id: b.id, remaining: 0)),
            .perform(.say(id: b.id, text: "b", ttl: 1, respond: nil)),
        ])
        XCTAssertEqual(queue.depth, 1, "pending survives a skip")
    }

    func testSkipLastItemDrains() throws {
        var queue = makeQueue()
        let only = QueueItem(action: .say(text: "solo"), holdMS: 5000)
        _ = try queue.enqueue([only], now: t0).get()
        XCTAssertEqual(queue.skip(now: t0.addingTimeInterval(1)), [
            .emit(.itemFinished(id: only.id)),
            .emit(.drained),
        ])
        XCTAssertFalse(queue.isActive)
    }

    func testSkipWhenIdleIsQuiet() {
        var queue = makeQueue()
        XCTAssertEqual(queue.skip(now: t0), [])
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

    func testAskStepBridgeRoundTripsAndBecomesExternal() {
        let spec = ResponseSpec(form: .choice, choices: ["staging", "prod"])
        let step = ScriptStep.ask(text: "Where to?", respond: spec)
        let item = QueueItem(step: step)
        XCTAssertEqual(item.step, step)
        XCTAssertTrue(item.isQuestion)
        XCTAssertTrue(item.isExternal)
        XCTAssertNil(item.holdMS, "a question has no hold — its duration is the human's")
    }

    // MARK: external completion

    private func question(_ text: String, timeoutMS: Int? = nil) -> QueueItem {
        let spec = ResponseSpec(form: .confirm, timeoutMS: timeoutMS)
        return QueueItem(
            action: .ask(text: text, respond: spec),
            completion: .external(timeoutMS: timeoutMS)
        )
    }

    func testExternalItemParksIndefinitely() throws {
        var queue = makeQueue()
        let q = question("Deploy?")
        let effects = try queue.enqueue([q], now: t0).get()
        XCTAssertEqual(effects, [
            .emit(.itemStarted(id: q.id, remaining: 0)),
            .perform(.say(id: q.id, text: "Deploy?", ttl: 0, respond: q.respond)),
            .emit(.itemAwaiting(id: q.id, timeoutAt: nil)),
        ])
        // An hour later it is still waiting: no clock resolves a question.
        XCTAssertEqual(queue.tick(now: t0.addingTimeInterval(3600)), [])
        let snapshot = queue.snapshot(now: t0.addingTimeInterval(3600))
        XCTAssertEqual(snapshot.current?.id, q.id)
        XCTAssertNil(snapshot.currentRemaining, "a parked item has no countdown")
        XCTAssertEqual(snapshot.current?.awaiting, .question(q.respond!))
    }

    func testExternalItemWithCeilingTimesOut() throws {
        var queue = makeQueue()
        let q = question("Deploy?", timeoutMS: 5000)
        _ = try queue.enqueue([q], now: t0).get()
        XCTAssertEqual(queue.tick(now: t0.addingTimeInterval(4.9)), [])
        XCTAssertEqual(queue.tick(now: t0.addingTimeInterval(5)), [
            .emit(.itemResolved(id: q.id, reason: .timedOut)),
            .emit(.itemFinished(id: q.id)),
            .emit(.drained),
        ])
    }

    /// The regression test for the whole feature: before this guard, any
    /// ordinary `say` silently voided a question the human was looking at.
    func testHeadEnqueueDoesNotCutAParkedItem() throws {
        var queue = makeQueue()
        let q = question("Deploy?")
        _ = try queue.enqueue([q], now: t0).get()

        let interjection = QueueItem(action: .say(text: "meanwhile"), holdMS: 1000)
        let effects = try queue.enqueue([interjection], at: .head, now: t0.addingTimeInterval(1)).get()
        XCTAssertEqual(effects, [], "the question keeps the stage; the say waits behind it")
        XCTAssertEqual(queue.snapshot(now: t0.addingTimeInterval(1)).current?.id, q.id)

        // Answering releases it, and the deferred say plays then — deferred,
        // never dropped.
        let resolved = try queue.resolveExternal(id: q.id, reason: .signalled, now: t0.addingTimeInterval(2)).get()
        XCTAssertEqual(resolved, [
            .emit(.itemResolved(id: q.id, reason: .signalled)),
            .emit(.itemFinished(id: q.id)),
            .emit(.itemStarted(id: interjection.id, remaining: 0)),
            .perform(.say(id: interjection.id, text: "meanwhile", ttl: 1, respond: nil)),
        ])
    }

    func testZeroHoldChainingStopsAtAnExternalItem() throws {
        var queue = makeQueue()
        let state = QueueItem(action: .setState(name: "running", durationMS: nil))
        let q = question("Deploy?")
        let after = QueueItem(action: .say(text: "after"), holdMS: 1000)
        let effects = try queue.enqueue([state, q, after], now: t0).get()
        // The zero-hold state chains into the question and stops there — it
        // must not be consumed by the same call that started it.
        XCTAssertEqual(ids(effects), [state.id, q.id])
        XCTAssertEqual(queue.snapshot(now: t0).current?.id, q.id)
        XCTAssertEqual(queue.snapshot(now: t0).pending.map(\.id), [after.id])
    }

    func testResolvingAPendingQuestionLeavesTheHeadParked() throws {
        var queue = makeQueue()
        let q1 = question("First?")
        let q2 = question("Second?")
        _ = try queue.enqueue([q1, q2], now: t0).get()

        let effects = try queue.resolveExternal(id: q2.id, reason: .signalled, now: t0.addingTimeInterval(1)).get()
        XCTAssertEqual(effects, [
            .emit(.itemResolved(id: q2.id, reason: .signalled)),
            .emit(.itemFinished(id: q2.id)),
        ], "answering out of order resolves in place and does not disturb the head")
        XCTAssertEqual(queue.snapshot(now: t0).current?.id, q1.id)
        XCTAssertEqual(queue.depth, 1)
        // q2 never started and never will.
        XCTAssertEqual(queue.tick(now: t0.addingTimeInterval(3600)), [])
    }

    func testResolveRejectsUnknownAndNonExternalItems() throws {
        var queue = makeQueue()
        let say = QueueItem(action: .say(text: "hi"), holdMS: 1000)
        _ = try queue.enqueue([say], now: t0).get()

        guard case .failure(let unknown) = queue.resolveExternal(id: "nope", reason: .signalled, now: t0) else {
            return XCTFail("expected rejection")
        }
        XCTAssertEqual(unknown.error, "unknown_item")

        guard case .failure(let notAwaiting) = queue.resolveExternal(id: say.id, reason: .signalled, now: t0) else {
            return XCTFail("expected rejection")
        }
        XCTAssertEqual(notAwaiting.error, "not_awaiting")
    }

    func testSkipCancelsParkedQuestionAndStartsNext() throws {
        var queue = makeQueue()
        let q = question("Deploy?")
        let after = QueueItem(action: .say(text: "moving on"), holdMS: 1000)
        _ = try queue.enqueue([q, after], now: t0).get()

        let effects = queue.skip(now: t0.addingTimeInterval(1))
        XCTAssertEqual(effects, [
            .emit(.itemResolved(id: q.id, reason: .cancelled(.skipped))),
            .emit(.itemFinished(id: q.id)),
            .emit(.itemStarted(id: after.id, remaining: 0)),
            .perform(.say(id: after.id, text: "moving on", ttl: 1, respond: nil)),
        ], "a skipped question is cancelled, not timed out")
    }

    func testFlushResolvesHeadAndEveryPendingQuestion() throws {
        var queue = makeQueue()
        let q1 = question("First?")
        let filler = QueueItem(action: .say(text: "filler"), holdMS: 1000)
        let q2 = question("Second?")
        _ = try queue.enqueue([q1, filler, q2], now: t0).get()

        let effects = queue.flush(now: t0.addingTimeInterval(1))
        XCTAssertEqual(effects, [
            .emit(.itemResolved(id: q2.id, reason: .cancelled(.flushed))),
            .emit(.itemResolved(id: q1.id, reason: .cancelled(.flushed))),
            .emit(.itemFinished(id: q1.id)),
            .emit(.flushed(dropped: 2)),
        ], "every question resolves before the flush is announced")
    }

    func testOutstandingQuestionCapIsAllOrNothing() throws {
        var queue = makeQueue()
        let batch = (0..<ActionQueue.maxOutstandingQuestions).map { question("q\($0)") }
        _ = try queue.enqueue(batch, now: t0).get()
        XCTAssertEqual(queue.outstandingQuestionIDs.count, ActionQueue.maxOutstandingQuestions)

        let extra = question("one too many")
        guard case .failure(let failure) = queue.enqueue([extra], now: t0) else {
            return XCTFail("expected rejection")
        }
        XCTAssertEqual(failure.error, "too_many_questions")
        XCTAssertEqual(queue.depth, ActionQueue.maxOutstandingQuestions, "queue untouched")
    }
}

extension ActionQueueTests {
    // MARK: pause / resume / pacing

    func testPauseFreezesTheClockAndResumeGivesTheTimeBack() throws {
        var queue = makeQueue()
        let item = QueueItem(action: .say(text: "hello"), holdMS: 10_000)
        _ = try queue.enqueue([item], now: t0).get()

        XCTAssertTrue(queue.pause(now: t0.addingTimeInterval(2)))
        // Ten seconds of wall clock pass while paused; nothing advances.
        XCTAssertEqual(queue.tick(now: t0.addingTimeInterval(12)), [])
        XCTAssertTrue(queue.isPaused)

        _ = queue.resume(now: t0.addingTimeInterval(12))
        XCTAssertFalse(queue.isPaused)
        // 8s of the hold were left when we paused, so it ends at 12 + 8.
        XCTAssertEqual(queue.tick(now: t0.addingTimeInterval(19.9)), [])
        XCTAssertEqual(queue.tick(now: t0.addingTimeInterval(20)), [
            .emit(.itemFinished(id: item.id)),
            .emit(.drained),
        ])
    }

    func testPauseIsIdempotentAndNoOpsWhenIdle() {
        var queue = makeQueue()
        XCTAssertFalse(queue.pause(now: t0), "nothing to pause")
        let item = QueueItem(action: .say(text: "hi"), holdMS: 1000)
        _ = try? queue.enqueue([item], now: t0).get()
        XCTAssertTrue(queue.pause(now: t0))
        XCTAssertFalse(queue.pause(now: t0), "already paused")
        XCTAssertEqual(queue.resume(now: t0).count, 0, "resuming at the same instant changes nothing")
    }

    func testNothingNewStartsWhilePaused() throws {
        var queue = makeQueue()
        let first = QueueItem(action: .say(text: "one"), holdMS: 1000)
        let second = QueueItem(action: .say(text: "two"), holdMS: 1000)
        _ = try queue.enqueue([first, second], now: t0).get()
        XCTAssertTrue(queue.pause(now: t0.addingTimeInterval(0.5)))

        XCTAssertEqual(queue.tick(now: t0.addingTimeInterval(5)), [], "the second item must not start")
        XCTAssertEqual(queue.snapshot(now: t0.addingTimeInterval(5)).current?.id, first.id)
    }

    func testElapsedReportsRunningTimeAndStopsWhilePaused() throws {
        var queue = makeQueue()
        let item = QueueItem(action: .say(text: "hello"), holdMS: 10_000)
        _ = try queue.enqueue([item], now: t0).get()
        XCTAssertEqual(queue.snapshot(now: t0.addingTimeInterval(3)).currentElapsed ?? -1, 3, accuracy: 0.001)

        _ = queue.pause(now: t0.addingTimeInterval(4))
        let paused = queue.snapshot(now: t0.addingTimeInterval(9))
        XCTAssertEqual(paused.currentElapsed ?? -1, 4, accuracy: 0.001, "elapsed freezes with the clock")
        XCTAssertTrue(paused.isPaused)

        // And picks up where it left off rather than jumping: paused time is
        // not time the item spent running.
        _ = queue.resume(now: t0.addingTimeInterval(9))
        let resumed = queue.snapshot(now: t0.addingTimeInterval(10))
        XCTAssertEqual(resumed.currentElapsed ?? -1, 5, accuracy: 0.001)
    }

    func testGapHoldsABeatBetweenItems() throws {
        var queue = makeQueue()
        queue.gapMS = 500
        let first = QueueItem(action: .say(text: "one"), holdMS: 1000)
        let second = QueueItem(action: .say(text: "two"), holdMS: 1000)
        _ = try queue.enqueue([first, second], now: t0).get()

        // First finishes at 1s, but the second waits out the gap.
        let atFinish = queue.tick(now: t0.addingTimeInterval(1))
        XCTAssertEqual(ids(atFinish), [], "the next item waits for the gap")
        XCTAssertEqual(ids(queue.tick(now: t0.addingTimeInterval(1.4))), [])
        XCTAssertEqual(ids(queue.tick(now: t0.addingTimeInterval(1.5))), [second.id])
    }

    func testZeroGapIsTheShippedBehaviour() throws {
        var queue = makeQueue()
        let first = QueueItem(action: .say(text: "one"), holdMS: 1000)
        let second = QueueItem(action: .say(text: "two"), holdMS: 1000)
        _ = try queue.enqueue([first, second], now: t0).get()
        XCTAssertEqual(ids(queue.tick(now: t0.addingTimeInterval(1))), [second.id])
    }
}
