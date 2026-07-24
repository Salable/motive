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
            ["motive_status", "motive_set_state", "motive_trigger", "motive_say"]
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
