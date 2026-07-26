import XCTest
@testable import MotiveCore
@testable import MotiveMCP

final class MCPServerTests: XCTestCase {
    private func makeServer() -> (MCPServer, MotiveEngine) {
        let engine = MotiveEngine(definition: BehaviorDefinition(
            states: [
                "idle": StateBehavior(name: "idle", frameDurations: [0.1], purpose: "resting"),
                "jumping": StateBehavior(name: "jumping", frameDurations: [0.1]),
            ],
            aliases: ["working": "idle"],
            triggers: ["jump": TriggerSpec(state: "jumping")]
        ))
        let control = MotiveControl(engine: engine, displayName: "TestPet")
        let server = MCPServer(transport: LocalCommandTransport(control: control))
        return (server, engine)
    }

    private func json(_ line: String?) throws -> [String: Any] {
        let data = try XCTUnwrap(line?.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testInitializeHandshake() async throws {
        let (server, _) = makeServer()
        let response = try json(await server.handle(
            line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#
        ))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        let serverInfo = try XCTUnwrap(result["serverInfo"] as? [String: Any])
        XCTAssertEqual(serverInfo["name"] as? String, "motive")
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"])
    }

    func testNotificationsGetNoResponse() async throws {
        let (server, _) = makeServer()
        let response = await server.handle(
            line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
        )
        XCTAssertNil(response)
    }

    func testToolsListNamesSpriteVocabulary() async throws {
        let (server, _) = makeServer()
        let response = try json(await server.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        XCTAssertEqual(
            Set(tools.compactMap { $0["name"] as? String }),
            ["motive_status", "motive_set_state", "motive_trigger", "motive_say",
             "motive_dismiss_speech", "motive_play_script", "motive_enqueue",
             "motive_queue", "motive_clear_queue", "motive_skip",
             "motive_questions", "motive_cancel_question",
             "motive_question_history", "motive_clear_question_history"]
        )
        let setState = try XCTUnwrap(tools.first { $0["name"] as? String == "motive_set_state" })
        let description = try XCTUnwrap(setState["description"] as? String)
        XCTAssertTrue(description.contains("jumping"), "tool description should list valid states: \(description)")
        XCTAssertNotNil(setState["inputSchema"])
    }

    func testToolCallSetStateRendersInEngine() async throws {
        let (server, engine) = makeServer()
        let response = try json(await server.handle(
            line: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"motive_set_state","arguments":{"state":"jumping"}}}"#
        ))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let state = await engine.machine.currentStateName
        XCTAssertEqual(state, "jumping")
    }

    func testToolCallUnknownStateIsToolErrorWithVocabulary() async throws {
        let (server, _) = makeServer()
        let response = try json(await server.handle(
            line: #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"motive_set_state","arguments":{"state":"zooming"}}}"#
        ))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let content = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertTrue(content.contains("idle"), "error should list valid states: \(content)")
    }

    func testToolCallSayAndStatus() async throws {
        let (server, _) = makeServer()
        _ = await server.handle(
            line: #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"motive_say","arguments":{"text":"hi"}}}"#
        )
        let response = try json(await server.handle(
            line: #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"motive_status","arguments":{}}}"#
        ))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertTrue(text.contains(#""text":"hi""#), "status should include the speech bubble: \(text)")
    }

    func testPlayScriptToolListedAndExecutes() async throws {
        let (server, engine) = makeServer()
        let list = try json(await server.handle(line: #"{"jsonrpc":"2.0","id":10,"method":"tools/list"}"#))
        let tools = try XCTUnwrap((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertTrue(tools.contains { $0["name"] as? String == "motive_play_script" })

        let call = #"{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"motive_play_script","arguments":{"steps":[{"type":"setState","name":"jumping"},{"type":"say","text":"hi","hold":3000}]}}}"#
        let response = try json(await server.handle(line: call))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let state = await engine.machine.currentStateName
        XCTAssertEqual(state, "jumping")
    }

    func testPlayScriptToolRejectsUnknownVocabulary() async throws {
        let (server, _) = makeServer()
        let call = #"{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"motive_play_script","arguments":{"steps":[{"type":"trigger","name":"moonwalk"}]}}}"#
        let response = try json(await server.handle(line: call))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertTrue(text.contains("jump"), "error should list valid triggers: \(text)")
    }

    func testEnqueueAndClearQueueTools() async throws {
        let (server, engine) = makeServer()
        let list = try json(await server.handle(line: #"{"jsonrpc":"2.0","id":20,"method":"tools/list"}"#))
        let tools = try XCTUnwrap((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertTrue(names.isSuperset(of: ["motive_enqueue", "motive_clear_queue"]))

        let enqueue = #"{"jsonrpc":"2.0","id":21,"method":"tools/call","params":{"name":"motive_enqueue","arguments":{"items":[{"type":"say","text":"a","hold":30000},{"type":"say","text":"b"}]}}}"#
        let response = try json(await server.handle(line: enqueue))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertTrue(text.contains("itemIDs"), "receipt should carry item ids: \(text)")
        var depth = await engine.queueDepth
        XCTAssertEqual(depth, 2)

        let clear = #"{"jsonrpc":"2.0","id":22,"method":"tools/call","params":{"name":"motive_clear_queue","arguments":{}}}"#
        let clearResponse = try json(await server.handle(line: clear))
        let clearResult = try XCTUnwrap(clearResponse["result"] as? [String: Any])
        XCTAssertEqual(clearResult["isError"] as? Bool, false)
        depth = await engine.queueDepth
        XCTAssertEqual(depth, 0)
    }

    func testSkipToolAdvancesQueue() async throws {
        let (server, engine) = makeServer()
        let enqueue = #"{"jsonrpc":"2.0","id":30,"method":"tools/call","params":{"name":"motive_enqueue","arguments":{"items":[{"type":"say","text":"a","hold":30000},{"type":"say","text":"b","hold":30000}]}}}"#
        _ = await server.handle(line: enqueue)

        let skip = #"{"jsonrpc":"2.0","id":31,"method":"tools/call","params":{"name":"motive_skip","arguments":{}}}"#
        let response = try json(await server.handle(line: skip))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertTrue(text.contains("skippedID"), "receipt should name the skipped item: \(text)")
        let depth = await engine.queueDepth
        XCTAssertEqual(depth, 1, "pending survives a skip")
        let speech = await engine.speech
        XCTAssertEqual(speech?.text, "b")
    }

    func testStatusToolReportsQueueDepth() async throws {
        let (server, engine) = makeServer()
        _ = await engine.enqueue([QueueItem(action: .say(text: "x"), holdMS: 30000)], now: Date())
        let response = try json(await server.handle(
            line: #"{"jsonrpc":"2.0","id":23,"method":"tools/call","params":{"name":"motive_status","arguments":{}}}"#
        ))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertTrue(text.contains(#""queueDepth":1"#), "status should report queue depth: \(text)")
    }

    func testQueueToolReportsCurrentAndPending() async throws {
        let (server, _) = makeServer()
        let enqueue = #"{"jsonrpc":"2.0","id":40,"method":"tools/call","params":{"name":"motive_enqueue","arguments":{"items":[{"type":"say","text":"a","hold":30000},{"type":"say","text":"b","hold":30000}]}}}"#
        _ = await server.handle(line: enqueue)

        let response = try json(await server.handle(
            line: #"{"jsonrpc":"2.0","id":41,"method":"tools/call","params":{"name":"motive_queue","arguments":{}}}"#
        ))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertTrue(text.contains(#""depth":2"#), "queue inspection should report depth: \(text)")
        XCTAssertTrue(text.contains(#""text":"a""#), "queue inspection should show the current item: \(text)")
        XCTAssertTrue(text.contains(#""text":"b""#), "queue inspection should show pending items: \(text)")
        XCTAssertTrue(text.contains("currentRemaining"), "queue inspection should carry the remaining hold: \(text)")
    }

    func testDismissSpeechToolClearsBubbleAndKeepsQueue() async throws {
        let (server, engine) = makeServer()
        let enqueue = #"{"jsonrpc":"2.0","id":50,"method":"tools/call","params":{"name":"motive_enqueue","arguments":{"items":[{"type":"say","text":"hello","hold":30000},{"type":"say","text":"later","hold":30000}]}}}"#
        _ = await server.handle(line: enqueue)
        var speech = await engine.speech
        XCTAssertEqual(speech?.text, "hello")

        let response = try json(await server.handle(
            line: #"{"jsonrpc":"2.0","id":51,"method":"tools/call","params":{"name":"motive_dismiss_speech","arguments":{}}}"#
        ))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        speech = await engine.speech
        XCTAssertNil(speech, "the bubble is dismissed")
        let depth = await engine.queueDepth
        XCTAssertEqual(depth, 2, "dismissing speech must not touch the queue")
    }

    /// The 1:1 contract the docs promise: every canonical verb has an MCP
    /// tool. Two exemptions: `cancel-script` is a documented alias of
    /// `clear-queue` (one tool per behavior, not per route), and `events` is
    /// a long-lived SSE stream with no request/response tool shape.
    func testEveryStandardVerbHasATool() async throws {
        let exempt: Set<String> = ["cancel-script", "events"]
        let (server, _) = makeServer()
        let toolNames = Set(await server.toolSpecs().map(\.name))
        for verb in ControlSchema.standardVerbs where !exempt.contains(verb.name) {
            let expected = "motive_" + verb.name.replacingOccurrences(of: "-", with: "_")
            XCTAssertTrue(
                toolNames.contains(expected),
                "verb '\(verb.name)' has no MCP tool (expected \(expected)); tools: \(toolNames.sorted())"
            )
        }
    }

    func testUnknownMethodIsJSONRPCError() async throws {
        let (server, _) = makeServer()
        let response = try json(await server.handle(line: #"{"jsonrpc":"2.0","id":7,"method":"resources/list"}"#))
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32601)
    }

    func testParseErrorHandled() async throws {
        let (server, _) = makeServer()
        let response = try json(await server.handle(line: "not json"))
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32700)
    }
}
