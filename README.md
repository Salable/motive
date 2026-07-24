# Motive

**Motive** is a composable Swift framework for building desktop "pet" apps on macOS — animated sprite companions that live on your desktop, react to what your tools are doing, and can be driven by AI agents over REST or MCP.

Rather than shipping one bundled app, Motive is a component library: pick the pieces you need and compose your own pet.

## Components

| Product | What it gives you |
| --- | --- |
| `MotiveCore` | Pure, timer-free animation state machine, the `MotiveEngine` runtime, the `MotiveControl` command surface, and the capability registry. No UI dependencies. |
| `MotiveSprite` | The sprite package model and pluggable format **runners**: `CodexRunner` (compatible with the Codex/Fido `pet.json` sprite-sheet contract) and `MotiveRunner` (the Motive-native `motive.json` format). |
| `MotiveUI` | AppKit/SwiftUI surfaces: the sprite view, the borderless sprite box window, speech bubbles, the menu-bar notification menu, and the settings window. |
| `MotiveHTTP` | A loopback REST control plane (token-authenticated, SSE events, self-describing schema) for driving the sprite from anything that can `curl`. |
| `MotiveMCP` | MCP tool definitions over the same command surface, plus the `motive-mcp` stdio shim for Claude Desktop / ChatGPT Desktop. |
| `MotiveAgents` | Installers that teach agent CLIs (Claude Code, Codex, OpenCode) how to talk to your pet. |

## Quick start

Requires macOS 13+ and Swift 5.10+.

```sh
git clone <repo-url> motive && cd motive
swift run motive-demo
```

The demo renders **Salli**, the bundled test sprite, on your desktop. Once the REST milestone lands you can drive her:

```sh
TOKEN=$(cat ~/.motive/runtime/token)
curl -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/json" \
     -d '{"state": "jumping"}' \
     http://127.0.0.1:PORT/v1/state
```

## Using Motive in your own app

```swift
// Package.swift
.package(url: "<repo-url>", from: "0.1.0")
// then depend on the products you need, e.g.
.product(name: "MotiveCore", package: "Motive"),
.product(name: "MotiveUI", package: "Motive"),
```

## Status

Early development (`0.x`). APIs will change. See [CHANGELOG.md](CHANGELOG.md) and the milestone issues for the roadmap.

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — layering and design principles
- [docs/FORMATS.md](docs/FORMATS.md) — sprite package formats (`codex/1` and `motive/1`)
- [docs/API.md](docs/API.md) — REST control plane
- [docs/INTEGRATIONS.md](docs/INTEGRATIONS.md) — hooking up Claude Code, Codex, OpenCode, Claude Desktop, ChatGPT Desktop

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Licensed under [MIT](LICENSE).
