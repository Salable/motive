# Components

> **Audience:** anyone deciding what to depend on.
> **Prerequisites:** none.
> **Source of truth:** `Package.swift`.

Motive is seven libraries and two executables. You depend on the ones you need;
there is no umbrella module and no framework to inherit from.

| Product | Depends on | Gives you | Page |
| --- | --- | --- | --- |
| `MotiveCore` | *nothing* | The engine, the queue, the state machine, the command surface, capabilities, runtime discovery. Foundation only. | [CORE.md](CORE.md) |
| `MotiveSprite` | Core | Sprite packages → a validated `SpriteDefinition`, and pluggable format runners. | [SPRITE.md](SPRITE.md) |
| `MotiveUI` | Core, Sprite | AppKit/SwiftUI surfaces: the sprite box, queue window, settings window, menu bar. | [UI.md](UI.md) |
| `MotiveHTTP` | Core, SwiftNIO | The loopback REST control plane with SSE. | [HTTP.md](HTTP.md) |
| `MotiveMCP` | Core | An MCP server over the same surface, in-process or over REST. | [MCP.md](MCP.md) |
| `MotiveAgents` | Core | Installers that teach agent CLIs and Claude Desktop about your pet. | [AGENTS.md](AGENTS.md) |
| `MotiveVoice` | Core | Speech out and in, behind a preflight gate. | [VOICE.md](VOICE.md) |

Executables: `motive-demo` (the reference composition) and `motive-mcp` (the
stdio MCP shim). See [../reference/CLI.md](../reference/CLI.md).

## Choosing

| You are building… | Depend on |
| --- | --- |
| a desktop pet with a visible sprite | `MotiveCore` + `MotiveSprite` + `MotiveUI` |
| …that agents can drive over REST | add `MotiveHTTP` |
| …that MCP hosts can drive | add `MotiveMCP`, or just ship the `motive-mcp` shim |
| …with one-click agent setup in your UI | add `MotiveAgents` |
| …that talks | add `MotiveVoice` |
| a headless tool that animates decision state | `MotiveCore` (+ `MotiveSprite` to load packages) |
| a client for someone else's pet | none — use the [REST API](../API.md) |

Every non-core target `@_exported import MotiveCore`, and `MotiveUI` also
re-exports `MotiveSprite`, so importing one library gives you the core
vocabulary transitively. The explicit imports in the docs are for clarity, not
necessity.

## The dependency rule

```
                    contracts (data)
                sprite packages: pet.json · motive.json
                            │
                     MotiveSprite
                            │
                      MotiveCore ─────────────────┐
                            │                     │
      ┌──────────┬──────────┼──────────┬──────────┤
   MotiveUI  MotiveHTTP  MotiveMCP  MotiveAgents  MotiveVoice
```

`MotiveCore` depends on nothing. Servers depend on Core and **never** on UI.
`MotiveUI` depends on Core and Sprite. Core and Sprite must never import AppKit,
SwiftUI, AVFoundation, or Speech — a source-scanning test enforces it.

The payoff is that all decision logic sits in a layer with no I/O, no timers, and
no platform frameworks, so it can be tested exhaustively and instantly. See
[../ARCHITECTURE.md](../ARCHITECTURE.md).

## The rule that shapes the surfaces

**One command surface.** REST routes and MCP tools are 1:1 adapters over
`MotiveControl` and add no semantics of their own. A new verb is three edits —
`standardVerbs`, a REST route, an MCP tool — landing together, and
`testEveryStandardVerbHasATool` fails if they do not.

Route your own UI through `MotiveControl` too. Then a behavior works identically
from your window, from `curl`, and from Claude, and `/v1/schema` keeps telling
the truth.
