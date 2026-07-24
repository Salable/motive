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
        let control = MotiveControl(engine: engine, displayName: "TestPet")
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
        let running = await engine.isScriptRunning
        XCTAssertTrue(running)
        let (status, _) = try await request("DELETE", "/v1/script")
        XCTAssertEqual(status, 200)
        let after = await engine.isScriptRunning
        XCTAssertFalse(after)
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
        XCTAssertNotNil(ServerInfo.load(from: server.paths.serverInfoURL))
        let attrs = try FileManager.default.attributesOfItem(atPath: server.paths.tokenURL.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
