import XCTest
@testable import MotiveCore

final class QuestionHistoryTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("motive-history-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func record(_ id: String, at offset: TimeInterval = 0) -> QuestionRecord {
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

    private func makeStore(maxRecords: Int = 500) -> FileQuestionHistoryStore {
        FileQuestionHistoryStore(
            url: root.appendingPathComponent("history/questions.jsonl"),
            maxRecords: maxRecords
        )
    }

    func testAppendAndReadBackRoundTrips() async {
        let store = makeStore()
        await store.append(record("a"))
        await store.append(record("b", at: 10))

        let recent = await store.recent(limit: 10)
        XCTAssertEqual(recent.map(\.id), ["b", "a"], "newest first")
        XCTAssertEqual(recent.first?.answer, .confirm(true))
        XCTAssertEqual(recent.first?.askedAt, t0.addingTimeInterval(10), "dates survive as ISO8601")
    }

    func testSurvivesAFreshStoreOnTheSameFile() async {
        let url = root.appendingPathComponent("history/questions.jsonl")
        let first = FileQuestionHistoryStore(url: url)
        await first.append(record("a"))

        // A new process, same file.
        let second = FileQuestionHistoryStore(url: url)
        let recent = await second.recent(limit: 10)
        XCTAssertEqual(recent.map(\.id), ["a"])
    }

    /// A hard kill can leave a half-written trailing line. That costs one
    /// record, never the file.
    func testTornTrailingLineIsSkipped() async throws {
        let store = makeStore()
        await store.append(record("a"))
        await store.append(record("b", at: 10))

        let url = root.appendingPathComponent("history/questions.jsonl")
        let text = try String(contentsOf: url, encoding: .utf8)
        try (text + "{\"id\":\"c\",\"text\":\"tru").write(to: url, atomically: true, encoding: .utf8)

        let recent = await store.recent(limit: 10)
        XCTAssertEqual(recent.map(\.id), ["b", "a"], "earlier records still read")
    }

    func testCullKeepsNewestAndReportsRemoved() async {
        let store = makeStore()
        for index in 0..<5 {
            await store.append(record("q\(index)", at: TimeInterval(index)))
        }
        let removed = await store.cull(keepingNewest: 2)
        XCTAssertEqual(removed, 3)
        let recent = await store.recent(limit: 10)
        XCTAssertEqual(recent.map(\.id), ["q4", "q3"])
    }

    func testClearEmptiesTheFile() async {
        let store = makeStore()
        await store.append(record("a"))
        let removed = await store.clear()
        XCTAssertEqual(removed, 1)
        let recent = await store.recent(limit: 10)
        XCTAssertTrue(recent.isEmpty)
    }

    func testHistoryFileIsOwnerOnly() async throws {
        let store = makeStore()
        await store.append(record("a"))
        _ = await store.cull(keepingNewest: 1) // forces the atomic rewrite path

        let url = root.appendingPathComponent("history/questions.jsonl")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let mode = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.int16Value, 0o600, "answers are private to the user")
    }

    func testGrowthIsBoundedAcrossAppends() async {
        let store = makeStore(maxRecords: 5)
        for index in 0..<120 {
            await store.append(record("q\(index)", at: TimeInterval(index)))
        }
        let recent = await store.recent(limit: 1000)
        XCTAssertLessThanOrEqual(recent.count, 105, "the file must not grow without bound")
        XCTAssertEqual(recent.first?.id, "q119", "the newest record always survives")
    }

    // MARK: paths

    func testHistoryIsASiblingOfRuntimeNotAChild() {
        let paths = RuntimePaths(rootURL: URL(fileURLWithPath: "/tmp/motive-home"))
        XCTAssertEqual(paths.runtimeURL.lastPathComponent, "runtime")
        XCTAssertEqual(paths.historyURL.lastPathComponent, "history")
        XCTAssertFalse(
            paths.questionHistoryURL.path.contains("/runtime/"),
            "MotiveServer.stop() deletes files under runtime/ — history must not live there"
        )
    }

    func testRuntimeURLInitDerivesTheRoot() {
        let paths = RuntimePaths(runtimeURL: URL(fileURLWithPath: "/tmp/motive-home/runtime"))
        XCTAssertEqual(paths.rootURL.path, "/tmp/motive-home")
        XCTAssertEqual(paths.questionHistoryURL.path, "/tmp/motive-home/history/questions.jsonl")
    }

    // MARK: engine integration

    func testEngineWritesHistoryAndANewEngineReadsItBack() async throws {
        let store = makeStore()
        let definition = BehaviorDefinition(
            states: ["idle": StateBehavior(name: "idle", frameDurations: [0.1])]
        )
        let engine = MotiveEngine(definition: definition, history: store)
        let id = try await engine.ask("Deploy?", respond: ResponseSpec(form: .confirm), now: t0).get().id
        _ = try await engine.answerQuestion(id: id, content: .confirm(true), now: t0).get()

        // A fresh engine on the same store, as a restart would be.
        let restarted = MotiveEngine(definition: definition, history: store)
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
            history: store
        )
        let id = try await engine.ask("Deploy?", respond: ResponseSpec(form: .confirm), now: t0).get().id
        _ = try await engine.answerQuestion(id: id, content: .confirm(true), now: t0).get()

        let removed = await engine.clearQuestionHistory()
        XCTAssertEqual(removed, 1)
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
        let first = MotiveEngine(definition: definition, history: store)
        let id = try await first.ask("Deploy?", respond: ResponseSpec(form: .confirm), now: t0).get().id
        _ = try await first.answerQuestion(id: id, content: .confirm(true), now: t0).get()

        let restarted = MotiveEngine(definition: definition, history: store)
        await restarted.restoreHistory()
        let history = await restarted.questionHistory()
        XCTAssertEqual(history.map(\.id), [id], "a surface can render this without waiting for a live event")
        XCTAssertEqual(history.first?.answer, .confirm(true))
    }
}
