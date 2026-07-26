import XCTest
@testable import MotiveCore
@testable import MotiveHTTP

final class MotiveServerTests: XCTestCase {
    private var server: MotiveServer!
    private var engine: MotiveEngine!
    private var port = 0
    private var token = ""
    private var runtimeDir: URL!

    override func setUp() async throws {
        runtimeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("motive-http-tests-\(UUID().uuidString)/runtime", isDirectory: true)
        engine = MotiveEngine(definition: BehaviorDefinition(
            states: [
                "idle": StateBehavior(name: "idle", frameDurations: [0.1, 0.1], purpose: "resting"),
                "running": StateBehavior(name: "running", frameDurations: [0.1, 0.1]),
                "jumping": StateBehavior(name: "jumping", frameDurations: [0.1, 0.1]),
            ],
            aliases: ["working": "running"],
            triggers: ["jump": TriggerSpec(state: "jumping")]
        ))
        let control = MotiveControl(engine: engine, displayName: "TestCompanion")
        server = MotiveServer(
            control: control,
            paths: RuntimePaths(runtimeURL: runtimeDir),
            preferredPort: 0
        )
        let info = try await server.start()
        port = info.port
        token = try XCTUnwrap(TokenManager.load(at: server.paths.tokenURL))
    }

    override func tearDown() async throws {
        await server.stop()
        try? FileManager.default.removeItem(at: runtimeDir.deletingLastPathComponent())
    }

    // MARK: helpers

    private func request(
        _ method: String,
        _ path: String,
        body: String? = nil,
        authorized: Bool = true
    ) async throws -> (status: Int, json: [String: Any]) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        if authorized {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = Data(body.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (status, json)
    }

    // MARK: tests

    func testPingIsUnauthenticated() async throws {
        let (status, json) = try await request("GET", "/v1/ping", authorized: false)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(json["ok"] as? Bool, true)
    }

    func testMissingTokenIsUnauthorized() async throws {
        let (status, _) = try await request("GET", "/v1/status", authorized: false)
        XCTAssertEqual(status, 401)
    }

    func testWrongTokenIsUnauthorized() async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/status")!)
        request.setValue("Bearer nope", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401)
    }

    func testXMotiveTokenHeaderWorks() async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/status")!)
        request.setValue(token, forHTTPHeaderField: "X-Motive-Token")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    func testStateChangeRendersInEngine() async throws {
        let (status, json) = try await request("POST", "/v1/state", body: #"{"state":"working"}"#)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(json["state"] as? String, "running") // alias resolved
        let engineState = await engine.machine.currentStateName
        XCTAssertEqual(engineState, "running")
    }

    func testUnknownStateRejectedWithVocabulary() async throws {
        let (status, json) = try await request("POST", "/v1/state", body: #"{"state":"zooming"}"#)
        XCTAssertEqual(status, 400)
        XCTAssertEqual(json["error"] as? String, "unknown_state")
        let valid = try XCTUnwrap(json["valid"] as? [String])
        XCTAssertTrue(valid.contains("idle"))
    }

    func testTriggerFires() async throws {
        let (status, json) = try await request("POST", "/v1/trigger", body: #"{"name":"jump"}"#)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(json["state"] as? String, "jumping")
    }

    func testSayPostsSpeechAndStatusReflectsIt() async throws {
        let (status, json) = try await request("POST", "/v1/say", body: #"{"text":"hello \"world\""}"#)
        XCTAssertEqual(status, 200)
        XCTAssertNotNil(json["speechID"] as? String)

        let (_, statusJSON) = try await request("GET", "/v1/status")
        let speech = try XCTUnwrap(statusJSON["speech"] as? [String: Any])
        XCTAssertEqual(speech["text"] as? String, "hello \"world\"")

        let (dismissStatus, _) = try await request("DELETE", "/v1/speech")
        XCTAssertEqual(dismissStatus, 200)
        let (_, after) = try await request("GET", "/v1/status")
        XCTAssertNil(after["speech"])
    }

    func testPlayScriptExecutesAndReturnsID() async throws {
        let body = #"{"steps":[{"type":"setState","name":"jumping"},{"type":"say","text":"weee","hold":2000}]}"#
        let (status, json) = try await request("POST", "/v1/script", body: body)
        XCTAssertEqual(status, 200)
        XCTAssertNotNil(json["scriptID"] as? String)
        let state = await engine.machine.currentStateName
        XCTAssertEqual(state, "jumping")
        let speech = await engine.speech
        XCTAssertEqual(speech?.text, "weee")
    }

    func testPlayScriptValidatesFailFast() async throws {
        let body = #"{"steps":[{"type":"say","text":"never shown"},{"type":"setState","name":"zooming"}]}"#
        let (status, json) = try await request("POST", "/v1/script", body: body)
        XCTAssertEqual(status, 400)
        XCTAssertEqual(json["error"] as? String, "unknown_state")
        XCTAssertNotNil(json["valid"] as? [String])
        // Nothing half-played.
        let speech = await engine.speech
        XCTAssertNil(speech)
    }

    func testPlayScriptRejectsMalformedAndEmpty() async throws {
        let (badStatus, badJSON) = try await request("POST", "/v1/script", body: #"{"steps":[{"type":"dance"}]}"#)
        XCTAssertEqual(badStatus, 400)
        XCTAssertEqual(badJSON["error"] as? String, "invalid_steps")

        let (emptyStatus, emptyJSON) = try await request("POST", "/v1/script", body: #"{"steps":[]}"#)
        XCTAssertEqual(emptyStatus, 400)
        XCTAssertEqual(emptyJSON["error"] as? String, "empty_script")
    }

    func testCancelScriptRoute() async throws {
        _ = try await request("POST", "/v1/script", body: #"{"steps":[{"type":"pause","ms":20000},{"type":"say","text":"later"}]}"#)
        let depth = await engine.queueDepth
        XCTAssertEqual(depth, 2)
        let (status, _) = try await request("DELETE", "/v1/script")
        XCTAssertEqual(status, 200)
        let after = await engine.queueDepth
        XCTAssertEqual(after, 0)
    }

    // MARK: queue routes

    func testEnqueueAppendsAndReportsIDs() async throws {
        let body = #"{"items":[{"type":"say","text":"one","hold":5000},{"type":"say","text":"two","hold":5000}]}"#
        let (status, json) = try await request("POST", "/v1/queue", body: body)
        XCTAssertEqual(status, 200)
        XCTAssertEqual((json["itemIDs"] as? [String])?.count, 2)
        XCTAssertEqual(json["queueDepth"] as? Int, 2)
        // First item is already playing.
        let speech = await engine.speech
        XCTAssertEqual(speech?.text, "one")
    }

    func testEnqueueAcceptsStepsAlias() async throws {
        let (status, _) = try await request("POST", "/v1/queue", body: #"{"steps":[{"type":"say","text":"hi"}]}"#)
        XCTAssertEqual(status, 200)
    }

    func testEnqueueValidatesAllOrNothing() async throws {
        let body = #"{"items":[{"type":"say","text":"fine"},{"type":"setState","name":"zooming"}]}"#
        let (status, json) = try await request("POST", "/v1/queue", body: body)
        XCTAssertEqual(status, 400)
        XCTAssertEqual(json["error"] as? String, "unknown_state")
        XCTAssertNotNil(json["valid"] as? [String])
        let depth = await engine.queueDepth
        XCTAssertEqual(depth, 0, "rejected batch must leave the queue untouched")
    }

    func testQueueStatusShowsCurrentAndPending() async throws {
        _ = try await request("POST", "/v1/queue", body: #"{"items":[{"type":"say","text":"now","hold":30000},{"type":"trigger","name":"jump"}]}"#)
        let (status, json) = try await request("GET", "/v1/queue")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(json["depth"] as? Int, 2)
        let current = try XCTUnwrap(json["current"] as? [String: Any])
        XCTAssertEqual((current["step"] as? [String: Any])?["text"] as? String, "now")
        XCTAssertNotNil(json["currentRemaining"] as? Double)
        let pending = try XCTUnwrap(json["pending"] as? [[String: Any]])
        XCTAssertEqual(pending.count, 1)
    }

    func testClearQueueReportsDropped() async throws {
        _ = try await request("POST", "/v1/queue", body: #"{"items":[{"type":"say","text":"a","hold":30000},{"type":"say","text":"b"},{"type":"say","text":"c"}]}"#)
        let (status, json) = try await request("DELETE", "/v1/queue")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(json["dropped"] as? Int, 2)
        XCTAssertEqual(json["queueDepth"] as? Int, 0)
    }

    func testClearQueueRevertsToDefaultState() async throws {
        // A scene leaves the sprite in "running"; clear must bring it home.
        _ = try await request("POST", "/v1/queue", body: #"{"items":[{"type":"setState","name":"running"},{"type":"say","text":"narrating","hold":30000},{"type":"say","text":"more"}]}"#)
        let state = await engine.machine.currentStateName
        XCTAssertEqual(state, "running")

        let (status, json) = try await request("DELETE", "/v1/queue")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(json["state"] as? String, "idle", "clear returns to the default state")
    }

    func testSkipCurrentQueueItemAdvancesAndPreservesPending() async throws {
        _ = try await request("POST", "/v1/queue", body: #"{"items":[{"type":"say","text":"a","hold":30000},{"type":"say","text":"b","hold":30000},{"type":"say","text":"c"}]}"#)
        let (status, json) = try await request("DELETE", "/v1/queue/current")
        XCTAssertEqual(status, 200)
        XCTAssertNotNil(json["skippedID"] as? String)
        XCTAssertEqual(json["queueDepth"] as? Int, 2)
        let speech = await engine.speech
        XCTAssertEqual(speech?.text, "b", "the next item plays immediately")
    }

    func testSkipOnIdleQueueIsOkNoOp() async throws {
        let (status, json) = try await request("DELETE", "/v1/queue/current")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(json["ok"] as? Bool, true)
        XCTAssertNil(json["skippedID"])
        XCTAssertEqual(json["queueDepth"] as? Int, 0)
    }

    func testDirectSayHeadEnqueuesAheadOfFlow() async throws {
        _ = try await request("POST", "/v1/queue", body: #"{"items":[{"type":"say","text":"flow 1","hold":30000},{"type":"say","text":"flow 2"}]}"#)
        let (status, _) = try await request("POST", "/v1/say", body: #"{"text":"urgent"}"#)
        XCTAssertEqual(status, 200)
        let speech = await engine.speech
        XCTAssertEqual(speech?.text, "urgent", "direct say plays next, cutting the current hold")
        let depth = await engine.queueDepth
        XCTAssertEqual(depth, 2, "flow item 2 still queued — nothing dropped")
    }

    func testV010ScriptWireShapeStillDecodesAsReplace() async throws {
        // The exact /v1/script body shape shipped in v0.1.0 keeps working,
        // now meaning "replace the queue".
        _ = try await request("POST", "/v1/queue", body: #"{"items":[{"type":"say","text":"old","hold":30000}]}"#)
        let body = #"{"steps":[{"type":"say","text":"hi","hold":2000},{"type":"trigger","name":"jump"},{"type":"pause","ms":1000},{"type":"setState","name":"idle"}]}"#
        let (status, json) = try await request("POST", "/v1/script", body: body)
        XCTAssertEqual(status, 200)
        XCTAssertNotNil(json["scriptID"] as? String)
        XCTAssertEqual((json["itemIDs"] as? [String])?.count, 4)
        let speech = await engine.speech
        XCTAssertEqual(speech?.text, "hi", "script replaced the old queue content")
    }

    func testSchemaVerbHonesty() async throws {
        // Every verb the schema advertises must answer on its route — never
        // 404/501. This is the no-aspirational-API regression test.
        let (status, json) = try await request("GET", "/v1/schema")
        XCTAssertEqual(status, 200)
        let verbs = try XCTUnwrap(json["verbs"] as? [[String: Any]])
        XCTAssertFalse(verbs.isEmpty)
        for verb in verbs {
            let method = try XCTUnwrap(verb["method"] as? String)
            let path = try XCTUnwrap(verb["path"] as? String)
            if path == "/v1/events" { continue } // SSE checked separately
            let (verbStatus, _) = try await request(method, path, body: method == "POST" ? "{}" : nil)
            XCTAssertNotEqual(verbStatus, 404, "\(method) \(path) advertised but not routed")
            XCTAssertNotEqual(verbStatus, 501, "\(method) \(path) advertised but not implemented")
        }
    }

    func testSchemaListsStatesAndTriggers() async throws {
        let (_, json) = try await request("GET", "/v1/schema")
        let states = try XCTUnwrap(json["states"] as? [[String: Any]])
        XCTAssertEqual(states.count, 3)
        XCTAssertEqual(json["aliases"] as? [String: String], ["working": "running"])
        let triggers = try XCTUnwrap(json["triggers"] as? [[String: Any]])
        XCTAssertEqual(triggers.first?["name"] as? String, "jump")
    }

    func testUnknownRouteIs404() async throws {
        let (status, _) = try await request("GET", "/v1/nope")
        XCTAssertEqual(status, 404)
    }

    func testOversizedBodyRejected() async throws {
        let big = #"{"text":"\#(String(repeating: "a", count: 70 * 1024))"}"#
        let (status, json) = try await request("POST", "/v1/say", body: big)
        XCTAssertEqual(status, 413)
        XCTAssertEqual(json["error"] as? String, "payload_too_large")
    }

    func testSSEStreamsStateChanges() async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/events")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(
            ((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "")
                .contains("text/event-stream")
        )

        Task { [engine] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            await engine?.requestState("jumping")
        }

        var sawStateEvent = false
        for try await line in bytes.lines {
            if line.contains("event: state") { sawStateEvent = true }
            if sawStateEvent, line.contains("jumping") { break }
        }
        XCTAssertTrue(sawStateEvent)
    }

    func testRateLimitKicksIn() async throws {
        let strictEngine = MotiveEngine(definition: BehaviorDefinition(
            states: ["idle": StateBehavior(name: "idle", frameDurations: [0.1])]
        ))
        let control = MotiveControl(engine: strictEngine, displayName: "Strict")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("motive-http-rate-\(UUID().uuidString)", isDirectory: true)
        let strictServer = MotiveServer(
            control: control,
            paths: RuntimePaths(runtimeURL: dir),
            preferredPort: 0,
            rateLimiter: RateLimiter(ratePerSecond: 0.001, burst: 2)
        )
        let info = try await strictServer.start()
        let strictToken = try XCTUnwrap(TokenManager.load(at: strictServer.paths.tokenURL))
        defer { Task { await strictServer.stop(); try? FileManager.default.removeItem(at: dir) } }

        var statuses: [Int] = []
        for _ in 0..<4 {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(info.port)/v1/state")!)
            request.httpMethod = "POST"
            request.httpBody = Data(#"{"state":"idle"}"#.utf8)
            request.setValue("Bearer \(strictToken)", forHTTPHeaderField: "Authorization")
            let (_, response) = try await URLSession.shared.data(for: request)
            statuses.append((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        XCTAssertTrue(statuses.contains(429), "expected a 429 after burst exhaustion, got \(statuses)")
    }

    func testDiscoveryFilesWrittenAndCleanedUp() async throws {
        let info = try XCTUnwrap(ServerInfo.load(from: server.paths.serverInfoURL))
        XCTAssertEqual(info.host, "127.0.0.1")
        let attrs = try FileManager.default.attributesOfItem(atPath: server.paths.tokenURL.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    // MARK: M12 — bind host + lifecycle

    private func makeServer(
        preferredPort: Int = 0,
        bindHost: String = "127.0.0.1",
        paths: RuntimePaths? = nil
    ) async throws -> (MotiveServer, ServerInfo, String) {
        let runtime = paths ?? RuntimePaths(runtimeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("motive-http-m12-\(UUID().uuidString)", isDirectory: true))
        let engine = MotiveEngine(definition: BehaviorDefinition(
            states: ["idle": StateBehavior(name: "idle", frameDurations: [0.1])]
        ))
        let control = MotiveControl(engine: engine, displayName: "Bindy")
        let server = MotiveServer(control: control, paths: runtime, preferredPort: preferredPort, bindHost: bindHost)
        let info = try await server.start()
        let token = try XCTUnwrap(TokenManager.load(at: runtime.tokenURL))
        return (server, info, token)
    }

    func testPublicBindReachableAndRecorded() async throws {
        let (server, info, token) = try await makeServer(bindHost: "0.0.0.0")
        defer { Task { await server.stop() } }
        XCTAssertEqual(info.host, "0.0.0.0")
        XCTAssertEqual(ServerInfo.load(from: server.paths.serverInfoURL)?.host, "0.0.0.0")

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(info.port)/v1/status")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    func testRestartCycleRotatesTokenOnSamePaths() async throws {
        let paths = RuntimePaths(runtimeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("motive-http-restart-\(UUID().uuidString)", isDirectory: true))
        let (first, firstInfo, firstToken) = try await makeServer(paths: paths)
        await first.stop()
        XCTAssertNil(ServerInfo.load(from: paths.serverInfoURL), "stop() should remove discovery files")

        // Restart = fresh instance on the same paths (stop() killed the ELG).
        let (second, secondInfo, secondToken) = try await makeServer(paths: paths)
        defer { Task { await second.stop() } }
        XCTAssertNotEqual(firstToken, secondToken, "token must rotate per boot")
        _ = firstInfo

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(secondInfo.port)/v1/status")!)
        request.setValue("Bearer \(firstToken)", forHTTPHeaderField: "Authorization")
        let (_, stale) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((stale as? HTTPURLResponse)?.statusCode, 401, "old token must not survive a restart")
    }

    func testPortCollisionFallsBackToEphemeral() async throws {
        let (first, firstInfo, _) = try await makeServer(preferredPort: 0)
        defer { Task { await first.stop() } }
        let (second, secondInfo, _) = try await makeServer(preferredPort: firstInfo.port)
        defer { Task { await second.stop() } }
        XCTAssertNotEqual(secondInfo.port, firstInfo.port)
        XCTAssertEqual(ServerInfo.load(from: second.paths.serverInfoURL)?.port, secondInfo.port)
    }

    func testSSETerminatesOnStop() async throws {
        let (server, info, token) = try await makeServer()
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(info.port)/v1/events")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (bytes, _) = try await URLSession.shared.bytes(for: request)

        Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            await server.stop()
        }
        // The stream must end (not hang) once the server stops.
        var lines = 0
        do {
            for try await _ in bytes.lines { lines += 1 }
        } catch {
            // A connection-reset error is an acceptable form of termination.
        }
        XCTAssertLessThan(lines, 1_000)
    }

    func testLegacyServerInfoWithoutHostDecodes() throws {
        let legacy = #"{"name":"Old","pid":1,"port":1234,"startedAt":"2026-07-24T00:00:00Z","version":"0.1.0"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let info = try decoder.decode(ServerInfo.self, from: Data(legacy.utf8))
        XCTAssertEqual(info.host, "127.0.0.1")
    }

    // MARK: questions

    func testAskPollAnswerRoundTrip() async throws {
        let asked = try await request(
            "POST", "/v1/say",
            body: #"{"text":"Deploy to production?","respond":{"form":"confirm"}}"#
        )
        XCTAssertEqual(asked.status, 200)
        let questionID = try XCTUnwrap(asked.json["questionID"] as? String)
        XCTAssertEqual(asked.json["speechID"] as? String, questionID,
                       "the bubble and the question are the same thing")

        // Outstanding, and reported as awaiting.
        let open = try await request("GET", "/v1/questions")
        XCTAssertEqual(open.json["openCount"] as? Int, 1)
        let one = try await request("GET", "/v1/questions?id=\(questionID)")
        let question = try XCTUnwrap(one.json["question"] as? [String: Any])
        XCTAssertEqual(question["status"] as? String, "awaiting")
        XCTAssertEqual(question["form"] as? String, "confirm")

        // Only the UI can answer: go through the engine, as MotiveUI does.
        _ = await engine.answerQuestion(id: questionID, content: .confirm(true))

        let answered = try await request("GET", "/v1/questions?id=\(questionID)")
        let resolved = try XCTUnwrap(answered.json["question"] as? [String: Any])
        XCTAssertEqual(resolved["status"] as? String, "accepted")
        let answer = try XCTUnwrap(resolved["answer"] as? [String: Any])
        XCTAssertEqual(answer["confirmed"] as? Bool, true)
        XCTAssertEqual(resolved["via"] as? String, "typed")
    }

    /// A timed-out long poll is a 200 with status "awaiting", never an error —
    /// that is what makes the caller's loop trivially correct.
    func testLongPollTimesOutWithTwoHundred() async throws {
        let asked = try await request(
            "POST", "/v1/say", body: #"{"text":"Waiting?","respond":{"form":"confirm"}}"#
        )
        let questionID = try XCTUnwrap(asked.json["questionID"] as? String)

        let started = Date()
        let polled = try await request("GET", "/v1/questions?id=\(questionID)&wait=300")
        XCTAssertEqual(polled.status, 200)
        let question = try XCTUnwrap(polled.json["question"] as? [String: Any])
        XCTAssertEqual(question["status"] as? String, "awaiting")
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 0.25, "the poll should have parked")
    }

    func testCancelQuestionReleasesTheQueue() async throws {
        let asked = try await request(
            "POST", "/v1/say", body: #"{"text":"Deploy?","respond":{"form":"confirm"}}"#
        )
        let questionID = try XCTUnwrap(asked.json["questionID"] as? String)

        let cancelled = try await request("DELETE", "/v1/questions", body: #"{"id":"\#(questionID)"}"#)
        XCTAssertEqual(cancelled.status, 200)
        XCTAssertEqual(cancelled.json["cancelledIDs"] as? [String], [questionID])

        let depth = await engine.queueDepth
        XCTAssertEqual(depth, 0)
        let history = try await request("GET", "/v1/questions/history")
        let entries = try XCTUnwrap(history.json["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.first?["status"] as? String, "cancelled")
    }

    func testInvalidRespondFormIsRejectedWithVocabulary() async throws {
        let response = try await request(
            "POST", "/v1/say", body: #"{"text":"Hi","respond":{"form":"telepathy"}}"#
        )
        XCTAssertEqual(response.status, 400)
        XCTAssertEqual(response.json["error"] as? String, "invalid_respond")
    }

    func testChoiceQuestionRequiresValidOptions() async throws {
        let tooFew = try await request(
            "POST", "/v1/say",
            body: #"{"text":"Where?","respond":{"form":"choice","choices":["only"]}}"#
        )
        XCTAssertEqual(tooFew.status, 400)
        XCTAssertEqual(tooFew.json["error"] as? String, "invalid_choices")
    }

    /// The security invariant, pinned: no advertised verb can resolve a
    /// question as answered. Absence is the enforcement, so absence is what we
    /// assert.
    func testNoVerbAnswersAQuestion() {
        let answering = ControlSchema.standardVerbs.filter {
            $0.name.contains("answer") || $0.name.contains("resolve") || $0.name.contains("reply")
        }
        XCTAssertTrue(
            answering.isEmpty,
            "answers originate only from UI input; found \(answering.map(\.name))"
        )
    }

    func testQuestionHistoryAndActivityShareOneTimeline() async throws {
        for index in 0..<3 {
            let asked = try await request(
                "POST", "/v1/say", body: #"{"text":"Q\#(index)?","respond":{"form":"confirm"}}"#
            )
            let id = try XCTUnwrap(asked.json["questionID"] as? String)
            _ = await engine.answerQuestion(id: id, content: .confirm(true))
        }
        let history = try await request("GET", "/v1/questions/history")
        XCTAssertEqual(history.json["total"] as? Int, 3, "history is a filtered view")

        // Each question contributes two activity entries: asked, then resolved.
        let activity = try await request("GET", "/v1/activity")
        let entries = try XCTUnwrap(activity.json["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 6)
        XCTAssertEqual(entries.first?["kind"] as? String, "asked")

        // One store, one retention control.
        let culled = try await request("DELETE", "/v1/activity", body: #"{"keep":2}"#)
        XCTAssertEqual(culled.json["removed"] as? Int, 4)
        let after = try await request("GET", "/v1/questions/history")
        XCTAssertEqual(after.json["total"] as? Int, 1, "one resolved question survived")
    }

    /// The cursor is what makes polling a real alternative to holding the SSE
    /// stream open: ask for everything after the last sequence you saw.
    func testActivityCursorReturnsOnlyWhatIsNew() async throws {
        _ = try await request("POST", "/v1/say", body: #"{"text":"first"}"#)
        let first = try await request("GET", "/v1/activity")
        let cursor = try XCTUnwrap(first.json["nextSeq"] as? Int)
        XCTAssertGreaterThan(cursor, 0)

        _ = try await request("POST", "/v1/state", body: #"{"state":"running"}"#)
        let next = try await request("GET", "/v1/activity?since=\(cursor)")
        let entries = try XCTUnwrap(next.json["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1, "only what happened since")
        XCTAssertEqual(entries.first?["kind"] as? String, "stateRequested")
        XCTAssertEqual(entries.first?["actor"] as? String, "agent")

        // Nothing new: an empty page and the cursor held steady.
        let latest = try XCTUnwrap(next.json["nextSeq"] as? Int)
        let idle = try await request("GET", "/v1/activity?since=\(latest)")
        XCTAssertEqual((idle.json["entries"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual(idle.json["nextSeq"] as? Int, latest, "the cursor must not rewind")
    }

    func testActivityRecordsWhoDidWhat() async throws {
        let asked = try await request(
            "POST", "/v1/say", body: #"{"text":"Deploy?","respond":{"form":"confirm"}}"#
        )
        let id = try XCTUnwrap(asked.json["questionID"] as? String)
        _ = await engine.answerQuestion(id: id, content: .confirm(true))

        let activity = try await request("GET", "/v1/activity")
        let entries = try XCTUnwrap(activity.json["entries"] as? [[String: Any]])
        let asking = try XCTUnwrap(entries.first { $0["kind"] as? String == "asked" })
        XCTAssertEqual(asking["actor"] as? String, "agent")
        let answering = try XCTUnwrap(entries.first { $0["kind"] as? String == "questionResolved" })
        XCTAssertEqual(answering["actor"] as? String, "human", "the answer was the human's")
        XCTAssertEqual(answering["summary"] as? String, "Answered yes")
    }
}
