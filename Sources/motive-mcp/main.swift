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

    func say(_ text: String, ttlMS: Int?, respond: ResponseSpec?) async throws -> ControlReceipt {
        try await RESTCommandTransport.discover().say(text, ttlMS: ttlMS, respond: respond)
    }

    func dismissSpeech() async throws -> ControlReceipt {
        try await RESTCommandTransport.discover().dismissSpeech()
    }

    func playScript(_ run: ScriptRun) async throws -> ControlReceipt {
        try await RESTCommandTransport.discover().playScript(run)
    }

    func enqueue(_ steps: [ScriptStep]) async throws -> ControlReceipt {
        try await RESTCommandTransport.discover().enqueue(steps)
    }

    func queueStatus() async throws -> QueueStatus {
        try await RESTCommandTransport.discover().queueStatus()
    }

    func clearQueue() async throws -> ControlReceipt {
        try await RESTCommandTransport.discover().clearQueue()
    }

    func skip() async throws -> ControlReceipt {
        try await RESTCommandTransport.discover().skip()
    }

    func pause() async throws -> ControlReceipt {
        try await RESTCommandTransport.discover().pause()
    }

    func resume() async throws -> ControlReceipt {
        try await RESTCommandTransport.discover().resume()
    }

    func questions(id: String?) async throws -> QuestionList {
        try await RESTCommandTransport.discover().questions(id: id)
    }

    func cancelQuestion(id: String?) async throws -> ControlReceipt {
        try await RESTCommandTransport.discover().cancelQuestion(id: id)
    }

    func activity(since: UInt64?, limit: Int?) async throws -> ActivityPage {
        try await RESTCommandTransport.discover().activity(since: since, limit: limit)
    }

    func clearActivity(keep: Int?) async throws -> ControlReceipt {
        try await RESTCommandTransport.discover().clearActivity(keep: keep)
    }

    func questionHistory(limit: Int?) async throws -> QuestionHistoryPage {
        try await RESTCommandTransport.discover().questionHistory(limit: limit)
    }

}
