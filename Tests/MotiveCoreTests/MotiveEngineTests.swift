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
