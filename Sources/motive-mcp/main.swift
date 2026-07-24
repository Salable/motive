import Foundation
import MotiveCore
import MotiveMCP

/// Stdio MCP shim: register this executable in Claude Desktop / ChatGPT
/// Desktop / any MCP host. It discovers the running Motive app through
/// `~/.motive/runtime/` (honors MOTIVE_HOME) and proxies MCP tool calls to
/// the app's REST control plane — no linking against the app required.
///
/// Discovery is lazy: the shim starts and answers initialize/tools-list even
/// before the app is up; tool calls report a helpful error until it is.

let transport = LazyDiscoveryTransport()
let server = MCPServer(transport: transport)
await server.runStdio()

/// Re-discovers the app on each call so the shim survives app restarts
/// (each restart rotates the port and token).
struct LazyDiscoveryTransport: MotiveCommandTransport {
    func schema() async throws -> ControlSchema {
        try await RESTCommandTransport.discover().schema()
    }

    func status() async throws -> ControlStatus {
        try await RESTCommandTransport.discover().status()
    }

    func setState(_ name: String, durationMS: Int?) async throws -> ControlReceipt {
        try await RESTCommandTransport.discover().setState(name, durationMS: durationMS)
    }

    func fireTrigger(_ name: String) async throws -> ControlReceipt {
        try await RESTCommandTransport.discover().fireTrigger(name)
    }

    func say(_ text: String, ttlMS: Int?) async throws -> ControlReceipt {
        try await RESTCommandTransport.discover().say(text, ttlMS: ttlMS)
    }

    func playScript(_ run: ScriptRun) async throws -> ControlReceipt {
        try await RESTCommandTransport.discover().playScript(run)
    }

    func enqueue(_ steps: [ScriptStep]) async throws -> ControlReceipt {
        try await RESTCommandTransport.discover().enqueue(steps)
    }

    func clearQueue() async throws -> ControlReceipt {
        try await RESTCommandTransport.discover().clearQueue()
    }

    func skip() async throws -> ControlReceipt {
        try await RESTCommandTransport.discover().skip()
    }
}
