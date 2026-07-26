import XCTest
@testable import MotiveCore

final class ActivityStoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("motive-history-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func questionRecord(_ id: String, at offset: TimeInterval = 0) -> QuestionRecord {
        QuestionRecord(
            id: id,
            text: "Question \(id)",
            respond: ResponseSpec(form: .confirm),
            askedAt: t0.addingTimeInterval(offset),
            status: .accepted,
            resolvedAt: t0.addingTimeInterval(offset + 1),
            answer: .confirm(true),
            via: .typed
        )
    }

    private func record(_ id: String, at offset: TimeInterval = 0, seq: UInt64 = 0) -> ActivityRecord {
        ActivityRecord(
            seq: seq == 0 ? UInt64(abs(id.hashValue % 100_000) + 1) : seq,
            at: t0.addingTimeInterval(offset),
            actor: .human,
            kind: .questionResolved,
            summary: "Answered yes",
            question: questionRecord(id, at: offset)
        )
    }

    private func makeStore(maxRecords: Int = 500) -> FileActivityStore {
        FileActivityStore(
            url: root.appendingPathComponent("history/activity.jsonl"),
            maxRecords: maxRecords
        )
    }

    func testAppendAndReadBackRoundTrips() async {
        let store = makeStore()
        await store.append(record("a", seq: 1))
        await store.append(record("b", at: 10, seq: 2))

        let recent = await store.recent(limit: 10)
        XCTAssertEqual(recent.compactMap(\.question?.id), ["b", "a"], "newest first")
        XCTAssertEqual(recent.first?.question?.answer, .confirm(true))
        XCTAssertEqual(recent.first?.question?.askedAt, t0.addingTimeInterval(10), "dates survive as ISO8601")
    }

    func testSurvivesAFreshStoreOnTheSameFile() async {
        let url = root.appendingPathComponent("history/activity.jsonl")
        let first = FileActivityStore(url: url)
        await first.append(record("a", seq: 1))

        // A new process, same file.
        let second = FileActivityStore(url: url)
        let recent = await second.recent(limit: 10)
        XCTAssertEqual(recent.compactMap(\.question?.id), ["a"])
    }

    /// A hard kill can leave a half-written trailing line. That costs one
    /// record, never the file.
    func testTornTrailingLineIsSkipped() async throws {
        let store = makeStore()
        await store.append(record("a", seq: 1))
        await store.append(record("b", at: 10, seq: 2))

        let url = root.appendingPathComponent("history/activity.jsonl")
        let text = try String(contentsOf: url, encoding: .utf8)
        try (text + "{\"id\":\"c\",\"text\":\"tru").write(to: url, atomically: true, encoding: .utf8)

        let recent = await store.recent(limit: 10)
        XCTAssertEqual(recent.compactMap(\.question?.id), ["b", "a"], "earlier records still read")
    }

    func testCullKeepsNewestAndReportsRemoved() async {
        let store = makeStore()
        for index in 0..<5 {
            await store.append(record("q\(index)", at: TimeInterval(index), seq: UInt64(index + 1)))
        }
        let removed = await store.cull(keepingNewest: 2)
        XCTAssertEqual(removed, 3)
        let recent = await store.recent(limit: 10)
        XCTAssertEqual(recent.compactMap(\.question?.id), ["q4", "q3"])
    }

    func testClearEmptiesTheFile() async {
        let store = makeStore()
        await store.append(record("a", seq: 1))
        let removed = await store.clear()
        XCTAssertEqual(removed, 1)
        let recent = await store.recent(limit: 10)
        XCTAssertTrue(recent.isEmpty)
    }

    func testHistoryFileIsOwnerOnly() async throws {
        let store = makeStore()
        await store.append(record("a", seq: 1))
        _ = await store.cull(keepingNewest: 1) // forces the atomic rewrite path

        let url = root.appendingPathComponent("history/activity.jsonl")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let mode = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.int16Value, 0o600, "answers are private to the user")
    }

    func testGrowthIsBoundedAcrossAppends() async {
        let store = makeStore(maxRecords: 5)
        for index in 0..<120 {
            await store.append(record("q\(index)", at: TimeInterval(index), seq: UInt64(index + 1)))
        }
        let recent = await store.recent(limit: 1000)
        // Bounded by maxRecords plus the cull slack, not by how many arrived.
        XCTAssertLessThanOrEqual(recent.count, 25, "the file must not grow without bound")
        XCTAssertEqual(recent.first?.question?.id, "q119", "the newest record always survives")
    }

    // MARK: paths

    func testHistoryIsASiblingOfRuntimeNotAChild() {
        let paths = RuntimePaths(rootURL: URL(fileURLWithPath: "/tmp/motive-home"))
        XCTAssertEqual(paths.runtimeURL.lastPathComponent, "runtime")
        XCTAssertEqual(paths.historyURL.lastPathComponent, "history")
        XCTAssertFalse(
            paths.activityURL.path.contains("/runtime/"),
            "MotiveServer.stop() deletes files under runtime/ — history must not live there"
        )
    }

    func testRuntimeURLInitDerivesTheRoot() {
        let paths = RuntimePaths(runtimeURL: URL(fileURLWithPath: "/tmp/motive-home/runtime"))
        XCTAssertEqual(paths.rootURL.path, "/tmp/motive-home")
        XCTAssertEqual(paths.activityURL.path, "/tmp/motive-home/history/activity.jsonl")
    }

    // MARK: engine integration

    func testEngineWritesHistoryAndANewEngineReadsItBack() async throws {
        let store = makeStore()
        let definition = BehaviorDefinition(
            states: ["idle": StateBehavior(name: "idle", frameDurations: [0.1])]
        )
        let engine = MotiveEngine(definition: definition, activity: store)
        let id = try await engine.ask("Deploy?", respond: ResponseSpec(form: .confirm), now: t0).get().id
        _ = try await engine.answerQuestion(id: id, content: .confirm(true), now: t0).get()
        await engine.drainHistoryWrites()

        // A fresh engine on the same store, as a restart would be.
        let restarted = MotiveEngine(definition: definition, activity: store)
        var before = await restarted.questionHistory()
        XCTAssertTrue(before.isEmpty, "history is not read until it is restored")
        await restarted.restoreHistory()
        before = await restarted.questionHistory()
        XCTAssertEqual(before.map(\.id), [id])
        XCTAssertEqual(before.first?.answer, .confirm(true))
    }

    func testClearingHistoryClearsDiskToo() async throws {
        let store = makeStore()
        let engine = MotiveEngine(
            definition: BehaviorDefinition(
                states: ["idle": StateBehavior(name: "idle", frameDurations: [0.1])]
            ),
            activity: store
        )
        let id = try await engine.ask("Deploy?", respond: ResponseSpec(form: .confirm), now: t0).get().id
        _ = try await engine.answerQuestion(id: id, content: .confirm(true), now: t0).get()

        // Two entries: the question asked, then its answer.
        await engine.drainHistoryWrites()
        let removed = await engine.clearActivity()
        XCTAssertEqual(removed, 2)
        let onDisk = await store.recent(limit: 10)
        XCTAssertTrue(onDisk.isEmpty, "culling from settings or the API must reach the file")
    }

    /// The gap a restart exposes: the engine restores history from disk, so a
    /// surface that seeds itself from the engine shows it. Without this, the
    /// persistence is invisible exactly where a user would look for it.
    func testRestoredHistoryIsReadableImmediately() async throws {
        let store = makeStore()
        let definition = BehaviorDefinition(
            states: ["idle": StateBehavior(name: "idle", frameDurations: [0.1])]
        )
        let first = MotiveEngine(definition: definition, activity: store)
        let id = try await first.ask("Deploy?", respond: ResponseSpec(form: .confirm), now: t0).get().id
        _ = try await first.answerQuestion(id: id, content: .confirm(true), now: t0).get()
        await first.drainHistoryWrites()

        let restarted = MotiveEngine(definition: definition, activity: store)
        await restarted.restoreHistory()
        let history = await restarted.questionHistory()
        XCTAssertEqual(history.map(\.id), [id], "a surface can render this without waiting for a live event")
        XCTAssertEqual(history.first?.answer, .confirm(true))
    }
}

final class SpokenAnswerTests: XCTestCase {
    private func question(_ spec: ResponseSpec) -> QuestionRecord {
        QuestionRecord(id: "q", text: "?", respond: spec, askedAt: Date())
    }

    func testConfirmMatchesTheLabelsOnScreen() {
        let record = question(ResponseSpec(form: .confirm, yesLabel: "Ship it", noLabel: "Hold off"))
        XCTAssertEqual(record.interpret(spoken: "ship it"), .confirm(true))
        XCTAssertEqual(record.interpret(spoken: "Hold off please"), .confirm(false))
    }

    func testConfirmFallsBackToOrdinaryWords() {
        let record = question(ResponseSpec(form: .confirm))
        for yes in ["yes", "Yeah", "sure", "go ahead"] {
            XCTAssertEqual(record.interpret(spoken: yes), .confirm(true), yes)
        }
        for no in ["no", "nope", "don't", "cancel"] {
            XCTAssertEqual(record.interpret(spoken: no), .confirm(false), no)
        }
    }

    /// Better to hear nothing than to hear the wrong thing and act on it.
    func testAmbiguousSpeechIsNotAnAnswer() {
        let record = question(ResponseSpec(form: .confirm))
        XCTAssertNil(record.interpret(spoken: "hmm, maybe later"))
        XCTAssertNil(record.interpret(spoken: ""))
    }

    func testChoicePrefersAnExactMatchOverAPrefix() {
        let record = question(ResponseSpec(form: .choice, choices: ["prod", "production"]))
        XCTAssertEqual(record.interpret(spoken: "prod"), .choice("prod", index: 0))
        XCTAssertEqual(record.interpret(spoken: "production"), .choice("production", index: 1))
    }

    func testChoiceRefusesWhenSeveralOptionsMatch() {
        let record = question(ResponseSpec(form: .choice, choices: ["staging", "prod"]))
        XCTAssertNil(record.interpret(spoken: "staging or prod, either"))
        XCTAssertEqual(record.interpret(spoken: "let's do staging"), .choice("staging", index: 0))
    }

    func testTextTakesWhateverWasSaid() {
        let record = question(ResponseSpec(form: .text))
        XCTAssertEqual(record.interpret(spoken: "  ship the hotfix  "), .text("ship the hotfix"))
    }

    /// A spoken answer must survive the same validation a typed one does.
    func testInterpretedAnswersValidate() {
        let record = question(ResponseSpec(form: .choice, choices: ["staging", "prod"]))
        let answer = try? XCTUnwrap(record.interpret(spoken: "prod"))
        XCTAssertNil(record.validate(answer!))
    }
}

extension ActivityStoreTests {
    /// Sequence numbers are the cursor. Handing one out twice makes a polling
    /// agent skip an entry, so they must only ever move forward — including
    /// across a restore that races whatever the companion is already doing.
    func testRestoreNeverRewindsTheSequence() async throws {
        let store = makeStore()
        let definition = BehaviorDefinition(
            states: ["idle": StateBehavior(name: "idle", frameDurations: [0.1])]
        )
        let engine = MotiveEngine(definition: definition, activity: store)

        // Something happens before the restore completes, as onboarding does.
        _ = await engine.say("first", now: t0)
        await engine.restoreHistory()
        _ = await engine.say("second", now: t0.addingTimeInterval(1))

        let entries = await engine.activityEntries(after: 0, limit: 100)
        let sequences = entries.map(\.seq)
        XCTAssertEqual(Set(sequences).count, sequences.count, "sequence numbers must be unique")
        XCTAssertEqual(sequences, sequences.sorted(), "and monotonic")
    }

    func testCursorSkipsNothingAcrossAPoll() async throws {
        let engine = MotiveEngine(
            definition: BehaviorDefinition(
                states: ["idle": StateBehavior(name: "idle", frameDurations: [0.1])]
            ),
            activity: InMemoryActivityStore()
        )
        for index in 0..<5 {
            _ = await engine.say("line \(index)", now: t0.addingTimeInterval(TimeInterval(index)))
        }
        // Walk the log in pages of two, as an agent would.
        var cursor: UInt64 = 0
        var seen: [String] = []
        while true {
            let page = await engine.activityEntries(after: cursor, limit: 2)
            if page.isEmpty { break }
            seen.append(contentsOf: page.map(\.summary))
            cursor = page.last!.seq
        }
        XCTAssertEqual(seen, (0..<5).map { "line \($0)" }, "paging must lose nothing")
    }
}
