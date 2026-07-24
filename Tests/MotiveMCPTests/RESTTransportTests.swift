import XCTest
@testable import MotiveCore
@testable import MotiveHTTP
@testable import MotiveMCP

/// End-to-end: MCP server → REST transport → MotiveServer → engine. This is
/// exactly the motive-mcp shim path.
final class RESTTransportTests: XCTestCase {
    func testShimPathDrivesEngineOverREST() async throws {
        let runtimeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("motive-mcp-tests-\(UUID().uuidString)/runtime", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: runtimeDir.deletingLastPathComponent()) }

        let engine = MotiveEngine(definition: BehaviorDefinition(
            states: [
                "idle": StateBehavior(name: "idle", frameDurations: [0.1]),
                "review": StateBehavior(name: "review", frameDurations: [0.1]),
            ]
        ))
        let control = MotiveControl(engine: engine, displayName: "ShimPet")
        let paths = RuntimePaths(runtimeURL: runtimeDir)
        let httpServer = MotiveServer(control: control, paths: paths, preferredPort: 0)
        _ = try await httpServer.start()
        defer { Task { await httpServer.stop() } }

        let transport = try RESTCommandTransport.discover(paths: paths)
        let mcp = MCPServer(transport: transport)

        let line = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"motive_set_state","arguments":{"state":"review"}}}"#
        let rawResponse = await mcp.handle(line: line)
        let response = try XCTUnwrap(rawResponse)
        XCTAssertTrue(response.contains(#""isError":false"#), "unexpected response: \(response)")

        let state = await engine.machine.currentStateName
        XCTAssertEqual(state, "review")

        let statusLine = #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"motive_status","arguments":{}}}"#
        let rawStatus = await mcp.handle(line: statusLine)
        let statusResponse = try XCTUnwrap(rawStatus)
        XCTAssertTrue(statusResponse.contains("ShimPet"))

        // Skip over the same path: enqueue two long items, skip the first —
        // proves the DELETE-with-subpath proxying end to end.
        let enqueueLine = #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"motive_enqueue","arguments":{"items":[{"type":"say","text":"a","hold":30000},{"type":"say","text":"b","hold":30000}]}}}"#
        _ = await mcp.handle(line: enqueueLine)
        let skipLine = #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"motive_skip","arguments":{}}}"#
        let rawSkip = await mcp.handle(line: skipLine)
        let skipResponse = try XCTUnwrap(rawSkip)
        XCTAssertTrue(skipResponse.contains("skippedID"), "unexpected response: \(skipResponse)")
        let depth = await engine.queueDepth
        XCTAssertEqual(depth, 1, "pending survives a skip over the shim path")
    }

    func testDiscoveryFailsHelpfullyWhenNoApp() {
        let empty = RuntimePaths(runtimeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("motive-mcp-none-\(UUID().uuidString)", isDirectory: true))
        XCTAssertThrowsError(try RESTCommandTransport.discover(paths: empty)) { error in
            XCTAssertTrue("\(error)".contains("no running Motive app"), "unhelpful error: \(error)")
        }
    }
}
