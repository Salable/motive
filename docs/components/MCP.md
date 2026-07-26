# MotiveMCP

> **Audience:** embedders exposing MCP tools. For connecting an existing host, read [../INTEGRATIONS.md](../INTEGRATIONS.md).
> **Prerequisites:** [CORE.md](CORE.md).
> **Source of truth:** `Sources/MotiveMCP/`; `Tests/MotiveMCPTests/`.

An MCP server over the same command surface as REST. Seventeen `motive_*` tools,
1:1 with the canonical verb list, adding no semantics of their own.

```swift
import MotiveMCP

let mcp = MCPServer(transport: LocalCommandTransport(control: control))
await mcp.runStdio()
```

## The transport seam

`MCPServer` does not know where the pet is. It talks to a
`MotiveCommandTransport`, and there are two implementations:

| Transport | Use when |
| --- | --- |
| `LocalCommandTransport(control:)` | Your app *is* the MCP server. In-process, no REST hop, no token. |
| `RESTCommandTransport(baseURL:token:session:)` | The pet is another process. This is what the `motive-mcp` shim uses. |

```swift
// Discover a running app through ~/.motive/runtime/ (honors MOTIVE_HOME).
let transport = try RESTCommandTransport.discover()
let transport = try RESTCommandTransport.discover(paths: RuntimePaths(rootURL: scratch))
```

The seam is why `MotiveMCP` depends on Core alone and never on `MotiveHTTP`: an
in-process MCP server needs no HTTP at all. It is also what makes the shim
testable — `RESTTransportTests` runs it against a real `MotiveHTTP` server.

## `MCPServer`

```swift
public init(transport: any MotiveCommandTransport, serverName: String = "motive")
public func handle(line: String) async -> String?
public func runStdio() async
```

`runStdio()` is the loop. `handle(line:)` is the same logic for one line, which
is what you want in tests or when you own the I/O — it returns `nil` for
notifications that take no response.

Protocol version `2024-11-05`. Methods: `initialize`, `ping`, `tools/list`,
`tools/call`.

## The tools

`motive_status`, `motive_set_state`, `motive_trigger`, `motive_say`,
`motive_dismiss_speech`, `motive_enqueue`, `motive_queue`, `motive_clear_queue`,
`motive_skip`, `motive_pause`, `motive_resume`, `motive_play_script`,
`motive_questions`, `motive_cancel_question`, `motive_question_history`,
`motive_activity`, `motive_clear_activity`.

Arguments and effects: [../INTEGRATIONS.md](../INTEGRATIONS.md#mcp-tools).

**Tool descriptions are generated from the live schema.** They name the loaded
sprite's actual states and triggers, so an agent connected to your pet is told
about *your* vocabulary rather than Winston's. Nothing is hand-written per
sprite.

Parity with `ControlSchema.standardVerbs` is enforced by
`testEveryStandardVerbHasATool`, with two documented exemptions:
`cancel-script` (an alias of `clear-queue` — MCP hosts get one tool per
behavior, not one per spelling) and `events` (a long-lived stream with no
request/response shape; poll `motive_status` or `motive_activity` instead).

No tool answers a question. See
[../concepts/QUESTIONS.md](../concepts/QUESTIONS.md#the-one-rule).

## The `motive-mcp` shim

A standalone stdio executable for desktop hosts. It holds no state and owns no
pet: on **every call** it rediscovers the running app through
`$MOTIVE_HOME/runtime/` and proxies to its REST plane.

Per-call rediscovery rather than at startup is the whole design. MCP hosts start
their servers once and keep them for a session; a pet restarts far more often
than Claude Desktop does, and every restart rotates the token. A shim that cached
its connection would work until the first restart and then fail silently for the
rest of the day.

It reads `MOTIVE_HOME` from *its own* environment, which is the MCP host's, not
your shell's.

```sh
swift build -c release        # .build/release/motive-mcp
```

The demo bundles a copy inside `MotiveDemo.app/Contents/MacOS/`, and
`resolveShimPath(near:path:)` in `MotiveAgents` is how an app finds it to offer
one-click registration.

## Which to ship

**Ship the shim** if users will register a binary with Claude Desktop or ChatGPT
Desktop. Nothing to link, one path to configure, and it survives your app
restarting. This is the common case.

**Go in-process** if your app is the MCP host side, or you want no REST hop —
then `MCPServer(transport: LocalCommandTransport(control:))` and you can skip
`MotiveHTTP` entirely.

Both can be true at once; they are two adapters over one `MotiveControl`.

## Why the protocol is hand-rolled

`MotiveMCP` implements newline-delimited JSON-RPC 2.0 directly, in about 730
lines. The official MCP swift-sdk is not used: at 0.9.0 it does not compile under
current strict-concurrency toolchains, and the surface actually needed here is
four methods.

If you are tempted to add the dependency back, check that it builds first — this
is a documented gotcha in `CLAUDE.md` because it has been re-discovered more than
once.
