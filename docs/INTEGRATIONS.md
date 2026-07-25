# Agent Integrations

The fastest first connection is the **connect prompt**: Settings → Control Plane
Status → *Copy prompt* produces markdown you paste into any agent chat. It embeds the
live port and bearer token, walks the agent through ping → schema → a visible
wave-and-say, and — when the server is bound publicly (0.0.0.0) — tells the agent
that you will provide the machine's base address. Re-copy after any server restart
(tokens rotate).

Beyond that, Motive integrates with agents two ways, both over the same command
surface:

- **REST** — anything that can `curl` drives the sprite via the loopback control
  plane; see [API.md](API.md). Discovery: `~/.motive/runtime/server.json` (port) and
  `~/.motive/runtime/token` (bearer token). Best for CLI agents (Claude Code, Codex,
  OpenCode) via skills/hooks.
- **MCP** — the `motive-mcp` executable is a stdio MCP server that proxies tool calls
  to the running Motive app's REST plane. It discovers the app the same way (honors
  `MOTIVE_HOME`), re-discovering on every call so it survives app restarts. Best for
  desktop hosts (Claude Desktop, ChatGPT Desktop).

## MCP tools

| Tool | Arguments | Effect |
| --- | --- | --- |
| `motive_status` | — | Current state + speech bubble. |
| `motive_set_state` | `state`, `duration?` (ms) | Change animation state (auto-revert with `duration`). |
| `motive_trigger` | `name` | One-shot gesture, then return. |
| `motive_say` | `text`, `ttl?` (ms) | Speech bubble (≤400 chars). |
| `motive_dismiss_speech` | — | Dismiss the current bubble; the queue is untouched. |
| `motive_enqueue` | `items` (array of `{type: say\|setState\|trigger\|pause, …}`) | Append to the action queue; plays in order after existing items. |
| `motive_queue` | — | Inspect the queue: depth, current item + remaining hold, pending items. |
| `motive_clear_queue` | — | Flush the queue and return to the default state. |
| `motive_skip` | — | Skip the current queue item; pending preserved. |
| `motive_play_script` | `steps` (same shape) | Replace the queue with this sequence. |

Direct tools (`motive_say`/`motive_set_state`/`motive_trigger`) play **next**, ahead
of the queue; queued items continue afterwards.

The tool set is 1:1 with the canonical verb list (`ControlSchema.standardVerbs`),
with two deliberate exceptions: `cancel-script` (an alias of `clear-queue` — MCP
hosts get one tool per behavior) and `events` (a long-lived SSE stream with no
request/response tool shape; poll `motive_status`/`motive_queue` instead).

Tool descriptions are generated from the live `/v1/schema`, so they name the loaded
sprite's actual states and triggers.

## Claude Desktop

Build the shim (`swift build -c release`) and add to
`~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "motive": { "command": "/path/to/motive/.build/release/motive-mcp" }
  }
}
```

Restart Claude Desktop, start your Motive app (e.g. `swift run motive-demo`), and ask
Claude to make the sprite jump.

## ChatGPT Desktop

ChatGPT's custom connectors are remote-server oriented and account-tier dependent; where
stdio MCP servers are supported (developer mode), register the same `motive-mcp` binary.
Otherwise use the REST plane directly.

## CLI agents (Claude Code, Codex, OpenCode)

`MotiveAgents` provides installers that write the appropriate skill/config files
(write-with-backup, uninstallable) teaching each agent the REST verbs — discovery,
auth, and the full verb vocabulary. In the demo they're one-click rows under
Settings → Agent Skills; embedders call the installers directly
([EMBEDDING.md](EMBEDDING.md)). Targets:

| Agent | Installer writes |
| --- | --- |
| Claude Code | `~/.claude/skills/motive-companion/SKILL.md` |
| Codex | `~/.codex/prompts/motive-companion.md` |
| OpenCode | `~/.config/opencode/command/motive-companion.md` |
| Claude Desktop | merges the `motive-mcp` server into `~/Library/Application Support/Claude/claude_desktop_config.json` |

## Implementation note

The MCP stdio protocol here is newline-delimited JSON-RPC 2.0, implemented directly in
`MotiveMCP` (initialize / ping / tools/list / tools/call). The official MCP swift-sdk is
not used: at 0.9.0 it fails to compile under current strict-concurrency toolchains, and
the needed surface is small. `MCPServer` accepts any `MotiveCommandTransport`, so an
in-process MCP server (no REST hop) is also available to embedding apps.
