import XCTest
@testable import MotiveCore

final class StateMachineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func makeDefinition() -> BehaviorDefinition {
        BehaviorDefinition(
            states: [
                "idle": StateBehavior(name: "idle", frameDurations: [0.1, 0.1], loop: true),
                "running": StateBehavior(name: "running", frameDurations: [0.1, 0.1, 0.1], loop: true),
                "failed": StateBehavior(name: "failed", frameDurations: [0.2, 0.2], loop: true),
                "waving": StateBehavior(name: "waving", frameDurations: [0.25, 0.25], loop: true, interrupt: .afterLoop),
                "intro": StateBehavior(name: "intro", frameDurations: [0.1, 0.1], loop: false, then: "idle"),
            ],
            aliases: ["working": "running"],
            triggers: ["wave": TriggerSpec(state: "waving", once: true)],
            transitions: [TransitionSpec(from: "*", to: "*", ms: 180)]
        )
    }

    func testImmediateStateChange() {
        var machine = ActorStateMachine(definition: makeDefinition(), now: t0)
        let outcome = machine.requestState("running", now: t0)
        guard case .changed(let directive) = outcome else {
            return XCTFail("expected .changed, got \(outcome)")
        }
        XCTAssertEqual(directive.stateName, "running")
        XCTAssertEqual(machine.currentStateName, "running")
    }

    func testAliasResolution() {
        var machine = ActorStateMachine(definition: makeDefinition(), now: t0)
        _ = machine.requestState("working", now: t0)
        XCTAssertEqual(machine.currentStateName, "running")
    }

    func testUnknownStateRejectedWithVocabulary() {
        var machine = ActorStateMachine(definition: makeDefinition(), now: t0)
        let outcome = machine.requestState("zooming", now: t0)
        guard case .rejected(let valid) = outcome else {
            return XCTFail("expected .rejected, got \(outcome)")
        }
        XCTAssertTrue(valid.contains("idle"))
        XCTAssertTrue(valid.contains("running"))
    }

    func testAfterLoopWaitsForBoundary() {
        var machine = ActorStateMachine(definition: makeDefinition(), now: t0)
        // idle loop is 0.2s; request waving mid-loop at t0+0.05.
        let outcome = machine.requestState("waving", now: t0.addingTimeInterval(0.05))
        guard case .scheduled(let promoteAt) = outcome else {
            return XCTFail("expected .scheduled, got \(outcome)")
        }
        XCTAssertEqual(promoteAt.timeIntervalSince(t0), 0.2, accuracy: 0.001)
        XCTAssertEqual(machine.currentStateName, "idle")

        // Before the boundary: nothing. At the boundary: promoted.
        XCTAssertEqual(machine.tick(now: t0.addingTimeInterval(0.1)), .noChange)
        guard case .changed(let directive) = machine.tick(now: promoteAt) else {
            return XCTFail("expected promotion at loop boundary")
        }
        XCTAssertEqual(directive.stateName, "waving")
    }

    func testPendingCoalescesLatestWins() {
        var machine = ActorStateMachine(definition: makeDefinition(), now: t0)
        _ = machine.requestState("waving", now: t0.addingTimeInterval(0.05))
        // A later immediate request replaces the pending one entirely.
        _ = machine.requestState("failed", now: t0.addingTimeInterval(0.06))
        XCTAssertEqual(machine.currentStateName, "failed")
        // The old pending waving must not fire afterwards.
        XCTAssertEqual(machine.tick(now: t0.addingTimeInterval(1)), .noChange)
        XCTAssertEqual(machine.currentStateName, "failed")
    }

    func testDurationAutoRevertsToIdle() {
        var machine = ActorStateMachine(definition: makeDefinition(), now: t0)
        _ = machine.requestState("running", duration: 1, now: t0)
        XCTAssertEqual(machine.tick(now: t0.addingTimeInterval(0.5)), .noChange)
        guard case .changed(let directive) = machine.tick(now: t0.addingTimeInterval(1.01)) else {
            return XCTFail("expected auto-revert")
        }
        XCTAssertEqual(directive.stateName, "idle")
    }

    func testDurationClampedToMax() {
        var machine = ActorStateMachine(definition: makeDefinition(), now: t0)
        _ = machine.requestState("running", duration: 9_999, now: t0)
        XCTAssertEqual(machine.tick(now: t0.addingTimeInterval(ActorStateMachine.maxDuration - 1)), .noChange)
        guard case .changed = machine.tick(now: t0.addingTimeInterval(ActorStateMachine.maxDuration + 0.2)) else {
            return XCTFail("expected revert at the 30s clamp")
        }
    }

    func testOneShotTriggerReturnsToPriorState() {
        var machine = ActorStateMachine(definition: makeDefinition(), now: t0)
        _ = machine.requestState("running", now: t0)
        guard case .changed(let directive) = machine.fireTrigger("wave", now: t0.addingTimeInterval(1)) else {
            return XCTFail("expected trigger to change state")
        }
        XCTAssertEqual(directive.stateName, "waving")
        // waving loop is 0.5s; after it completes we return to running.
        guard case .changed(let back) = machine.tick(now: t0.addingTimeInterval(1.55)) else {
            return XCTFail("expected return to prior state")
        }
        XCTAssertEqual(back.stateName, "running")
    }

    func testUnknownTriggerRejected() {
        var machine = ActorStateMachine(definition: makeDefinition(), now: t0)
        guard case .rejected(let valid) = machine.fireTrigger("moonwalk", now: t0) else {
            return XCTFail("expected rejection")
        }
        XCTAssertEqual(valid, ["wave"])
    }

    func testThenChainAdvancesWhenNonLoopingStateEnds() {
        var machine = ActorStateMachine(definition: makeDefinition(), initialState: "intro", now: t0)
        XCTAssertEqual(machine.currentStateName, "intro")
        guard case .changed(let directive) = machine.tick(now: t0.addingTimeInterval(0.21)) else {
            return XCTFail("expected then-chain to idle")
        }
        XCTAssertEqual(directive.stateName, "idle")
    }

    func testCrossfadePresentDuringTransitionThenClears() {
        var machine = ActorStateMachine(definition: makeDefinition(), now: t0)
        _ = machine.requestState("running", now: t0)
        let during = machine.directive(now: t0.addingTimeInterval(0.05))
        XCTAssertEqual(during.crossfade?.fromStateName, "idle")
        _ = machine.tick(now: t0.addingTimeInterval(0.5))
        let after = machine.directive(now: t0.addingTimeInterval(0.5))
        XCTAssertNil(after.crossfade)
    }

    func testFrameIndexingAndNonLoopClamp() {
        let behavior = StateBehavior(name: "x", frameDurations: [0.1, 0.2, 0.3], loop: false)
        XCTAssertEqual(behavior.frame(at: 0.05), 0)
        XCTAssertEqual(behavior.frame(at: 0.15), 1)
        XCTAssertEqual(behavior.frame(at: 0.45), 2)
        XCTAssertEqual(behavior.frame(at: 99), 2) // non-looping clamps to last frame
        XCTAssertEqual(behavior.frame(at: 0.45, reducedMotion: true), 0)

        let looping = StateBehavior(name: "y", frameDurations: [0.1, 0.1], loop: true)
        XCTAssertEqual(looping.frame(at: 0.25), 0) // wraps around
    }

    func testMissingInitialStateFallsBackToIdle() {
        let machine = ActorStateMachine(definition: makeDefinition(), initialState: "nope", now: t0)
        XCTAssertEqual(machine.currentStateName, "idle")
    }
}
