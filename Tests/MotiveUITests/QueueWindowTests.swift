import XCTest
@testable import MotiveUI

final class QueueEntryPresentationTests: XCTestCase {
    func testSayReadsAsItsTextWithSpeakingDuration() {
        let presentation = QueueEntryPresentation(step: .say(text: "Hi, I'm Winston!", holdMS: 4000))
        XCTAssertEqual(presentation.kind, .say)
        XCTAssertEqual(presentation.title, "Hi, I'm Winston!")
        XCTAssertEqual(presentation.detail, "Speaks for 4s")
        XCTAssertEqual(presentation.kindLabel, "Say")
    }

    func testStateWithHoldShowsIt() {
        let presentation = QueueEntryPresentation(step: .setState(name: "working", holdMS: 2500))
        XCTAssertEqual(presentation.kind, .state)
        XCTAssertEqual(presentation.title, "working")
        XCTAssertEqual(presentation.detail, "Holds 2.5s")
    }

    func testStateWithoutHoldSaysItMovesOn() {
        let presentation = QueueEntryPresentation(step: .setState(name: "idle", holdMS: nil))
        XCTAssertEqual(presentation.detail, "Sets the state, moves on")
    }

    func testTriggerAndPause() {
        let trigger = QueueEntryPresentation(step: .trigger(name: "wave"))
        XCTAssertEqual(trigger.kind, .trigger)
        XCTAssertEqual(trigger.title, "wave")

        let pause = QueueEntryPresentation(step: .pause(ms: 1500))
        XCTAssertEqual(pause.kind, .pause)
        XCTAssertEqual(pause.title, "Pause")
        XCTAssertEqual(pause.detail, "1.5s")
    }

    func testEveryKindHasASymbol() {
        let steps: [ScriptStep] = [
            .say(text: "x", holdMS: 1000),
            .setState(name: "idle", holdMS: nil),
            .trigger(name: "wave"),
            .pause(ms: 500),
        ]
        for step in steps {
            XCTAssertFalse(QueueEntryPresentation(step: step).symbolName.isEmpty)
        }
    }

    func testDurationFormatting() {
        XCTAssertEqual(QueueEntryPresentation.duration(seconds: 0), "0s")
        XCTAssertEqual(QueueEntryPresentation.duration(seconds: 4), "4s")
        XCTAssertEqual(QueueEntryPresentation.duration(seconds: 0.44), "0.4s")
        XCTAssertEqual(QueueEntryPresentation.duration(seconds: 12.55), "12.6s")
    }

    func testNegativeMillisecondsClampToZero() {
        XCTAssertEqual(QueueEntryPresentation(step: .pause(ms: -100)).detail, "0s")
    }
}

@MainActor
final class SpriteHostQueueTests: XCTestCase {
    /// The host republishes the engine's queue so the window can render the
    /// running item, its countdown, and the pending work behind it.
    func testHostPublishesQueueSnapshot() async throws {
        let host = SpriteHost(definition: TestSprite.definition, engine: TestSprite.engine())

        XCTAssertEqual(host.queue.depth, 0)

        let now = Date()
        _ = await host.engine.enqueue(
            [
                QueueItem(action: .say(text: "first"), holdMS: 4000),
                QueueItem(action: .say(text: "second"), holdMS: 4000),
            ],
            at: .tail,
            now: now
        )
        await host.refreshQueue()

        XCTAssertEqual(host.queue.depth, 2)
        XCTAssertEqual(host.queue.pending.count, 1)
        let current = try XCTUnwrap(host.queue.current)
        XCTAssertEqual(QueueEntryPresentation(step: current.step).title, "first")
        XCTAssertEqual(QueueEntryPresentation(step: host.queue.pending[0].step).title, "second")
        XCTAssertNotNil(host.queue.currentRemaining)

        await host.engine.flushQueue()
        await host.refreshQueue()
        XCTAssertEqual(host.queue.depth, 0)
        XCTAssertNil(host.queue.current)
    }
}

/// A minimal two-state sprite — enough to build an engine without touching the
/// filesystem or an atlas image.
enum TestSprite {
    static let definition = SpriteDefinition(
        format: "motive/1",
        metadata: SpriteMetadata(id: "test", displayName: "Test"),
        atlases: [:],
        states: [
            "idle": SpriteState(name: "idle", frames: [frame], loop: true),
            "wave": SpriteState(name: "wave", frames: [frame], loop: false, then: "idle"),
        ],
        triggers: ["wave": TriggerSpec(state: "wave")]
    )

    static func engine() -> MotiveEngine {
        MotiveEngine(definition: definition.behaviorDefinition)
    }

    private static let frame = SpriteFrame(
        atlasKey: "main",
        rect: FrameRect(x: 0, y: 0, width: 1, height: 1),
        duration: 0.1
    )
}
