import XCTest
@testable import MotiveCore

/// Completes on command, never on a clock — so Core tests stay timer-free even
/// though real audio is anything but.
final class FakeSpeechOutput: SpeechOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var _spoken: [SpeechUtterance] = []
    private var _stops = 0
    var available = true

    var spoken: [SpeechUtterance] {
        lock.lock(); defer { lock.unlock() }
        return _spoken
    }
    var stops: Int {
        lock.lock(); defer { lock.unlock() }
        return _stops
    }

    func speak(_ utterance: SpeechUtterance) async {
        lock.lock(); _spoken.append(utterance); lock.unlock()
    }
    func stop(graceful: Bool) async {
        lock.lock(); _stops += 1; lock.unlock()
    }
    func pause() async {}
    func resume() async {}
    var isAvailable: Bool { get async { available } }
}

final class SpeechOutputTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func makeEngine() -> MotiveEngine {
        MotiveEngine(definition: BehaviorDefinition(
            states: [
                "idle": StateBehavior(name: "idle", frameDurations: [0.1]),
                "talking": StateBehavior(name: "talking", frameDurations: [0.1]),
            ]
        ))
    }

    func testWithoutSpeechOutputSayKeepsItsHold() async {
        let engine = makeEngine()
        _ = await engine.say("hello", ttl: 2, now: t0)
        await engine.tick(now: t0.addingTimeInterval(1))
        var depth = await engine.queueDepth
        XCTAssertEqual(depth, 1, "still holding")
        await engine.tick(now: t0.addingTimeInterval(2))
        depth = await engine.queueDepth
        XCTAssertEqual(depth, 0, "the hold elapsed exactly as before")
    }

    func testSpokenSayWaitsForTheAudioNotTheClock() async throws {
        let engine = makeEngine()
        let output = FakeSpeechOutput()
        await engine.setSpeechOutput(output)

        _ = await engine.say("hello there", ttl: 2, now: t0)
        await engine.drainSpeechRequests()
        XCTAssertEqual(output.spoken.map(\.text), ["hello there"])

        // Well past the 2s ttl the item is still current: audio decides when a
        // spoken line ends, not the hold it would otherwise have had.
        await engine.tick(now: t0.addingTimeInterval(10))
        var depth = await engine.queueDepth
        XCTAssertEqual(depth, 1)

        let id = try XCTUnwrap(output.spoken.first?.id)
        await engine.speechDidStart(id: id, at: t0)
        await engine.speechDidFinish(id: id, outcome: .finished, at: t0.addingTimeInterval(11))
        depth = await engine.queueDepth
        XCTAssertEqual(depth, 0, "the queue advances when the audio ends")
    }

    /// The hard-won rule: reporting done without ever having started means the
    /// audio route failed, and a silent queue must not look like a spoken one.
    func testFinishWithoutStartIsRecordedAsAFailure() async {
        let engine = makeEngine()
        let output = FakeSpeechOutput()
        await engine.setSpeechOutput(output)
        _ = await engine.say("hello", now: t0)
        await engine.drainSpeechRequests()
        let id = output.spoken[0].id

        await engine.speechDidFinish(id: id, outcome: .finished, at: t0.addingTimeInterval(1))
        let failure = await engine.lastSpeechFailure
        XCTAssertNotNil(failure, "a route failure must be visible, not merely quiet")
        let depth = await engine.queueDepth
        XCTAssertEqual(depth, 0, "but the queue must still move on rather than wedge")
    }

    func testStaleCompletionForAnAlreadyFinishedItemIsIgnored() async {
        let engine = makeEngine()
        let output = FakeSpeechOutput()
        await engine.setSpeechOutput(output)
        _ = await engine.say("one", now: t0)
        await engine.drainSpeechRequests()
        let first = output.spoken[0].id
        await engine.speechDidStart(id: first, at: t0)
        await engine.speechDidFinish(id: first, outcome: .finished, at: t0.addingTimeInterval(1))

        _ = await engine.say("two", now: t0.addingTimeInterval(2))
        await engine.drainSpeechRequests()
        let second = output.spoken[1].id

        // A cancel callback arriving late for the first utterance must not
        // complete the second one.
        await engine.speechDidFinish(id: first, outcome: .cancelled, at: t0.addingTimeInterval(3))
        let depth = await engine.queueDepth
        XCTAssertEqual(depth, 1, "the live utterance survives a stale callback")
        XCTAssertNotEqual(first, second)
    }

    func testSpokenTimeoutScalesWithLengthAndIsBounded() {
        let short = QueueItem(action: .say(text: "hi"))
        let long = QueueItem(action: .say(text: String(repeating: "a", count: 400)))
        XCTAssertLessThan(
            MotiveEngine.spokenTimeoutMS(for: short),
            MotiveEngine.spokenTimeoutMS(for: long)
        )
        XCTAssertLessThanOrEqual(
            Double(MotiveEngine.spokenTimeoutMS(for: long)) / 1_000,
            ActionQueue.maxExternalTimeout
        )
    }

    func testSpritePreferencesReachTheUtterance() async {
        let engine = makeEngine()
        let output = FakeSpeechOutput()
        await engine.setSpeechOutput(output)
        await engine.setVoicePreferences(VoicePreferences(voiceID: "Daniel", rate: 1.2))

        _ = await engine.say("hello", now: t0)
        await engine.drainSpeechRequests()
        XCTAssertEqual(output.spoken.first?.voiceID, "Daniel")
        XCTAssertEqual(output.spoken.first?.rate, 1.2)
    }

    /// The ceiling is a backstop, not the detector: a synthesizer that never
    /// calls back must not park the queue forever.
    func testAWedgedSynthesizerReleasesTheQueueAtTheCeiling() async {
        let engine = makeEngine()
        await engine.setSpeechOutput(FakeSpeechOutput())
        _ = await engine.say("hello", now: t0)
        await engine.drainSpeechRequests()

        let ceiling = TimeInterval(MotiveEngine.spokenTimeoutMS(for: QueueItem(action: .say(text: "hello")))) / 1_000
        await engine.tick(now: t0.addingTimeInterval(ceiling - 1))
        var depth = await engine.queueDepth
        XCTAssertEqual(depth, 1, "still waiting on audio")

        await engine.tick(now: t0.addingTimeInterval(ceiling))
        depth = await engine.queueDepth
        XCTAssertEqual(depth, 0, "the backstop releases it")
    }
}

extension SpeechOutputTests {
    /// Regression: with audio installed the pet reads a question aloud, and the
    /// utterance's completion must not resolve the question. Before this, every
    /// question self-cancelled the moment it finished being spoken.
    func testSpeakingAQuestionAloudDoesNotAnswerOrCancelIt() async throws {
        let engine = makeEngine()
        let output = FakeSpeechOutput()
        await engine.setSpeechOutput(output)

        let id = try await engine.ask(
            "Ready to deploy?", respond: ResponseSpec(form: .confirm), now: t0
        ).get().id
        await engine.drainSpeechRequests()
        XCTAssertEqual(output.spoken.map(\.text), ["Ready to deploy?"], "the pet reads it aloud")

        await engine.speechDidStart(id: id, at: t0)
        await engine.speechDidFinish(id: id, outcome: .finished, at: t0.addingTimeInterval(3))

        let outstanding = await engine.outstandingQuestions()
        XCTAssertEqual(outstanding.map(\.id), [id], "the question still waits on a human")
        let record = await engine.question(id: id)
        XCTAssertEqual(record?.status, .awaiting)
        let depth = await engine.queueDepth
        XCTAssertEqual(depth, 1, "the queue stays parked")
    }

    func testAnsweringAfterItWasSpokenStillWorks() async throws {
        let engine = makeEngine()
        let output = FakeSpeechOutput()
        await engine.setSpeechOutput(output)
        let id = try await engine.ask(
            "Ready?", respond: ResponseSpec(form: .confirm), now: t0
        ).get().id
        await engine.drainSpeechRequests()
        await engine.speechDidStart(id: id, at: t0)
        await engine.speechDidFinish(id: id, outcome: .finished, at: t0.addingTimeInterval(2))

        let record = try await engine.answerQuestion(
            id: id, content: .confirm(true), now: t0.addingTimeInterval(9)
        ).get()
        XCTAssertEqual(record.status, .accepted)
        let depth = await engine.queueDepth
        XCTAssertEqual(depth, 0)
    }
}
