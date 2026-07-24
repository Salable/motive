import Foundation
import MotiveCore

/// Minimal MCP server speaking the stdio transport: newline-delimited
/// JSON-RPC 2.0. Implements initialize, ping, tools/list, and tools/call —
/// the surface desktop MCP hosts (Claude Desktop, ChatGPT Desktop) need to
/// drive a sprite. Tools are thin adapters over `MotiveCommandTransport`, so
/// the same server works in-process or as the `motive-mcp` REST-proxy shim.
public final class MCPServer: @unchecked Sendable {
    public static let protocolVersion = "2024-11-05"

    private let transport: MotiveCommandTransport
    private let serverName: String

    public init(transport: MotiveCommandTransport, serverName: String = "motive") {
        self.transport = transport
        self.serverName = serverName
    }

    // MARK: tool definitions

    struct ToolSpec {
        let name: String
        let description: String
        let inputSchema: [String: Any]
    }

    func toolSpecs() async -> [ToolSpec] {
        // Vocabulary comes from the live schema so descriptions name the
        // sprite's actual states and triggers.
        var stateNames: [String] = []
        var triggerNames: [String] = []
        var spriteName = "the sprite"
        if let schema = try? await transport.schema() {
            stateNames = schema.states.map(\.name) + schema.aliases.keys.sorted()
            triggerNames = schema.triggers.map(\.name)
            spriteName = schema.name
        }

        let stateList = stateNames.isEmpty ? "" : " Valid states: \(stateNames.sorted().joined(separator: ", "))."
        let triggerList = triggerNames.isEmpty ? "" : " Valid triggers: \(triggerNames.sorted().joined(separator: ", "))."

        return [
            ToolSpec(
                name: "motive_status",
                description: "Get \(spriteName)'s current animation state and speech bubble.",
                inputSchema: ["type": "object", "properties": [String: Any](), "required": [String]()]
            ),
            ToolSpec(
                name: "motive_set_state",
                description: "Change \(spriteName)'s animation state. Plays next (ahead of the queue); queued items continue after.\(stateList)",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "state": ["type": "string", "description": "Target state name."],
                        "duration": ["type": "number", "description": "Optional milliseconds before auto-reverting to idle."],
                    ],
                    "required": ["state"],
                ]
            ),
            ToolSpec(
                name: "motive_trigger",
                description: "Play a one-shot gesture, then return to the prior state. Plays next (ahead of the queue); queued items continue after.\(triggerList)",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string", "description": "Trigger name."],
                    ],
                    "required": ["name"],
                ]
            ),
            ToolSpec(
                name: "motive_enqueue",
                description: "Append actions to \(spriteName)'s queue — they play in order after everything already queued. Use for tours and multi-beat flows.\(stateList)\(triggerList)",
                inputSchema: Self.stepsSchema(key: "items", description: "Items appended to the queue in order.")
            ),
            ToolSpec(
                name: "motive_clear_queue",
                description: "Flush \(spriteName)'s action queue: drop all pending items, stop waiting on the current one, and return to the default state.",
                inputSchema: ["type": "object", "properties": [String: Any](), "required": [String]()]
            ),
            ToolSpec(
                name: "motive_skip",
                description: "Skip \(spriteName)'s current queue item — it ends now and the next queued item plays immediately. Pending items are preserved (motive_clear_queue drops everything).",
                inputSchema: ["type": "object", "properties": [String: Any](), "required": [String]()]
            ),
            ToolSpec(
                name: "motive_play_script",
                description: "Replace \(spriteName)'s queue with this sequence (flush, then play these steps in order).\(stateList)\(triggerList)",
                inputSchema: Self.stepsSchema(key: "steps", description: "Steps executed in order.")
            ),
            ToolSpec(
                name: "motive_say",
                description: "Show a speech bubble next to \(spriteName) (max 400 chars). Plays next (ahead of the queue); queued items continue after.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string", "description": "What the sprite says."],
                        "ttl": ["type": "number", "description": "Optional milliseconds the bubble stays up (default 8000)."],
                    ],
                    "required": ["text"],
                ]
            ),
        ]
    }

    /// Shared items/steps array schema for queue-shaped tools.
    static func stepsSchema(key: String, description: String) -> [String: Any] {
        [
            "type": "object",
            "properties": [
                key: [
                    "type": "array",
                    "maxItems": 64,
                    "description": description,
                    "items": [
                        "type": "object",
                        "properties": [
                            "type": ["type": "string", "enum": ["say", "setState", "trigger", "pause"]],
                            "text": ["type": "string", "description": "say: bubble text."],
                            "name": ["type": "string", "description": "setState/trigger: target name."],
                            "ms": ["type": "number", "description": "pause: milliseconds."],
                            "hold": ["type": "number", "description": "say/setState: milliseconds to hold before the next item (say default 4000; triggers default to the gesture's length)."],
                        ],
                        "required": ["type"],
                    ],
                ],
            ],
            "required": [key],
        ]
    }

    // MARK: JSON-RPC dispatch

    /// Handle one JSON-RPC message. Returns the response line, or nil for
    /// notifications (which get no response).
    public func handle(line: String) async -> String? {
        guard let data = line.data(using: .utf8),
              let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return encodeError(id: NSNull(), code: -32700, message: "parse error")
        }
        let id = message["id"]
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]

        // Notifications (no id) get no response.
        if id == nil {
            return nil
        }

        switch method {
        case "initialize":
            // Echo the client's requested protocol version when present.
            let requested = params["protocolVersion"] as? String ?? Self.protocolVersion
            return encodeResult(id: id!, result: [
                "protocolVersion": requested,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": serverName, "version": MotiveVersion.current],
            ])

        case "ping":
            return encodeResult(id: id!, result: [String: Any]())

        case "tools/list":
            let tools = await toolSpecs().map { spec -> [String: Any] in
                ["name": spec.name, "description": spec.description, "inputSchema": spec.inputSchema]
            }
            return encodeResult(id: id!, result: ["tools": tools])

        case "tools/call":
            guard let toolName = params["name"] as? String else {
                return encodeError(id: id!, code: -32602, message: "missing tool name")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            return await callTool(id: id!, name: toolName, arguments: arguments)

        default:
            return encodeError(id: id!, code: -32601, message: "method not found: \(method)")
        }
    }

    private func callTool(id: Any, name: String, arguments: [String: Any]) async -> String {
        do {
            let payload: String
            switch name {
            case "motive_status":
                payload = encodeJSON(try await transport.status())

            case "motive_set_state":
                guard let state = arguments["state"] as? String else {
                    return toolFailure(id: id, message: "missing required argument: state")
                }
                let duration = (arguments["duration"] as? NSNumber)?.intValue
                payload = encodeJSON(try await transport.setState(state, durationMS: duration))

            case "motive_trigger":
                guard let trigger = arguments["name"] as? String else {
                    return toolFailure(id: id, message: "missing required argument: name")
                }
                payload = encodeJSON(try await transport.fireTrigger(trigger))

            case "motive_play_script":
                guard let run = decodeRun(arguments["steps"]) else {
                    return toolFailure(id: id, message: "invalid or missing steps: each needs a type of say|setState|trigger|pause with its fields")
                }
                payload = encodeJSON(try await transport.playScript(run))

            case "motive_enqueue":
                guard let run = decodeRun(arguments["items"] ?? arguments["steps"]) else {
                    return toolFailure(id: id, message: "invalid or missing items: each needs a type of say|setState|trigger|pause with its fields")
                }
                payload = encodeJSON(try await transport.enqueue(run.steps))

            case "motive_clear_queue":
                payload = encodeJSON(try await transport.clearQueue())

            case "motive_skip":
                payload = encodeJSON(try await transport.skip())

            case "motive_say":
                guard let text = arguments["text"] as? String else {
                    return toolFailure(id: id, message: "missing required argument: text")
                }
                let ttl = (arguments["ttl"] as? NSNumber)?.intValue
                payload = encodeJSON(try await transport.say(text, ttlMS: ttl))

            default:
                return encodeError(id: id, code: -32602, message: "unknown tool: \(name)")
            }
            return encodeResult(id: id, result: [
                "content": [["type": "text", "text": payload]],
                "isError": false,
            ])
        } catch let error as TransportError {
            return toolFailure(id: id, message: error.description)
        } catch {
            return toolFailure(id: id, message: "\(error)")
        }
    }

    /// Round-trip loose JSON tool arguments through the Codable model.
    private func decodeRun(_ steps: Any?) -> ScriptRun? {
        guard let steps,
              let data = try? JSONSerialization.data(withJSONObject: ["steps": steps]),
              let run = try? JSONDecoder().decode(ScriptRun.self, from: data) else {
            return nil
        }
        return run
    }

    private func toolFailure(id: Any, message: String) -> String {
        encodeResult(id: id, result: [
            "content": [["type": "text", "text": message]],
            "isError": true,
        ])
    }

    // MARK: stdio run loop

    /// Serve MCP over stdin/stdout until EOF.
    public func runStdio() async {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let response = await handle(line: line) {
                FileHandle.standardOutput.write(Data((response + "\n").utf8))
            }
        }
    }

    // MARK: encoding

    private func encodeResult(id: Any, result: [String: Any]) -> String {
        encodeMessage(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func encodeError(id: Any, code: Int, message: String) -> String {
        encodeMessage(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func encodeMessage(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"encoding failure"}}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func encodeJSON<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
