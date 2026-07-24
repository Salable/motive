# Motive

**Motive** is a composable Swift framework for building desktop "pet" apps on macOS — animated sprite companions that live on your desktop, react to what your tools are doing, and can be driven by AI agents over REST or MCP.

Rather than shipping one bundled app, Motive is a component library: pick the pieces you need and compose your own pet.

## Components

| Product | What it gives you |
| --- | --- |
| `MotiveCore` | Pure, timer-free animation state machine, the `MotiveEngine` runtime, the `MotiveControl` command surface with a self-describing schema, and the capability registry. No UI dependencies. |
| `MotiveSprite` | The sprite package model and pluggable format **runners**: `CodexRunner` (compatible with the Codex/Fido `pet.json` sprite-sheet contract) and `MotiveRunner` (the Motive-native `motive.json` format). |
| `MotiveUI` | AppKit/SwiftUI surfaces: the sprite view, the sprite box window (chat input, action buttons, speech bubbles), the menu-bar notification menu, and the capability-driven settings window. |
| `MotiveHTTP` | A loopback REST control plane (token-authenticated, SSE events, self-describing schema) for driving the sprite from anything that can `curl`. |
| `MotiveMCP` | An MCP server over the same command surface, plus the `motive-mcp` stdio shim for Claude Desktop / ChatGPT Desktop. |
| `MotiveAgents` | Installers that teach agent CLIs (Claude Code, Codex, OpenCode) how to talk to your pet. |

## Try the demo

Requires macOS 13+. Either download `MotiveDemo-<version>.zip` from Releases
(right-click → Open the first time; the app is not notarized yet), or from a checkout
(Swift 5.10+):

```sh
swift run motive-demo
```

**Winston**, the bundled test sprite (a shaggy black labradoodle pup), appears on your desktop with a chat box and action
buttons; a paw in the menu bar has Settings and Quit. Then drive the pup from a terminal:

```sh
PORT=$(python3 -c "import json;print(json.load(open('$HOME/.motive/runtime/server.json'))['port'])")
TOKEN=$(cat ~/.motive/runtime/token)
curl -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
     -d '{"state": "jumping"}' "http://127.0.0.1:$PORT/v1/state"
```

or run the full tour: `./scripts/demo-curl.sh`. To drive her from Claude Desktop,
register the MCP shim (see [docs/INTEGRATIONS.md](docs/INTEGRATIONS.md)).

## Using Motive in your own app

```swift
// Package.swift
.package(url: "<repo-url>", from: "0.1.0")
// then depend on the products you need, e.g.
.product(name: "MotiveCore", package: "Motive"),
.product(name: "MotiveSprite", package: "Motive"),
.product(name: "MotiveUI", package: "Motive"),
```

Minimal pet:

```swift
let definition = try SpriteRunnerRegistry.standard.load(spriteFolderURL)
let host = SpriteHost(definition: definition)          // engine + SwiftUI bridge
let box = SpriteBoxWindow(host: host)                  // desktop window
box.show()
let control = MotiveControl(engine: host.engine, displayName: definition.metadata.displayName)
let server = MotiveServer(control: control)            // REST control plane
try await server.start()
```

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — layering and design principles
- [docs/FORMATS.md](docs/FORMATS.md) — sprite package formats (`codex/1` and `motive/1`)
- [docs/API.md](docs/API.md) — REST control plane
- [docs/INTEGRATIONS.md](docs/INTEGRATIONS.md) — Claude Code, Codex, OpenCode, Claude Desktop, ChatGPT Desktop

## Status

Early development (`0.x`). APIs will change. See [CHANGELOG.md](CHANGELOG.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Licensed under [MIT](LICENSE).
