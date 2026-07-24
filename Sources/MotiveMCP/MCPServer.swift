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
                description: "Change \(spriteName)'s animation state.\(stateList)",
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
                description: "Play a one-shot gesture, then return to the prior state.\(triggerList)",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string", "description": "Trigger name."],
                    ],
                    "required": ["name"],
                ]
            ),
            ToolSpec(
                name: "motive_play_script",
                description: "Play a queued sequence of steps (speech, state changes, gestures, pauses) — \(spriteName) walks through them in order. Any other command cancels the script.\(stateList)\(triggerList)",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "steps": [
                            "type": "array",
                            "maxItems": 64,
                            "description": "Steps executed in order.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "type": ["type": "string", "enum": ["say", "setState", "trigger", "pause"]],
                                    "text": ["type": "string", "description": "say: bubble text."],
                                    "name": ["type": "string", "description": "setState/trigger: target name."],
                                    "ms": ["type": "number", "description": "pause: milliseconds."],
                                    "hold": ["type": "number", "description": "say/setState: milliseconds to hold before the next step (say default 4000)."],
                                ],
                                "required": ["type"],
                            ],
                        ],
                    ],
                    "required": ["steps"],
                ]
            ),
            ToolSpec(
                name: "motive_say",
                description: "Show a speech bubble next to \(spriteName) (max 400 chars).",
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
                guard let steps = arguments["steps"] else {
                    return toolFailure(id: id, message: "missing required argument: steps")
                }
                // Round-trip the loose JSON arguments through the Codable model.
                guard let data = try? JSONSerialization.data(withJSONObject: ["steps": steps]),
                      let run = try? JSONDecoder().decode(ScriptRun.self, from: data) else {
                    return toolFailure(id: id, message: "invalid steps: each needs a type of say|setState|trigger|pause with its fields")
                }
                payload = encodeJSON(try await transport.playScript(run))

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
