# Motive Architecture

Motive is layered so that all decision logic is pure, testable, and UI-free, with thin
adapters at the edges.

```
contracts (data)      sprite packages: pet.json (codex/1) · motive.json (motive/1)
        │
MotiveSprite          runners parse packages → normalized SpriteDefinition
        │
MotiveCore            StateMachine (pure, timer-free) · MotiveEngine (actor, ticks & events)
                      MotiveControl (single command surface) · CapabilityRegistry
        │
surfaces & adapters   MotiveUI (sprite box, bubbles, tray, settings)
                      MotiveHTTP (REST /v1) · MotiveMCP (MCP tools) · MotiveAgents (installers)
```

## Principles

- **Sprites are data, never code.** Packages are JSON + images; nothing in them executes.
- **Tolerant decode, loud validation.** Loaders accept unknown keys; `SpriteValidator`
  reports findings. Every package load passes through the validator.
- **One command surface.** REST routes and MCP tools are 1:1 adapters over `MotiveControl`;
  neither adds semantics of its own.
- **Every verb ships rendered.** No API surface for behavior the renderer doesn't honor.
- **Core is UI-free.** `MotiveCore`/`MotiveSprite` never import AppKit; the state machine is
  timer-free and driven by explicit clocks so tests are deterministic.

## Dependency direction

`MotiveCore` depends on nothing. `MotiveSprite → MotiveCore`. Servers (`MotiveHTTP`,
`MotiveMCP`) depend on Core only — never on UI. `MotiveUI` depends on Core + Sprite.
The demo app composes all of them; consumers pick the products they need.

## Component reference

Each product is a target under `Sources/` with a matching test target under
`Tests/`.

| Product | Owns | Key types |
| --- | --- | --- |
| `MotiveCore` | Decision logic, no UI, no I/O beyond runtime discovery. | `ActorStateMachine` (pure, timer-free), `MotiveEngine` (actor: tick clock, action queue, speech, event fan-out), `ActionQueue`, `MotiveControl` + `ControlSchema` (the one command surface), `CapabilityRegistry`/`CapabilityStore`, `RuntimePaths`/`ServerInfo`/`TokenManager`, `MotiveVersion`. |
| `MotiveSprite` | Sprite packages → normalized model. | `SpriteDefinition`, `SpriteRunner` protocol + `SpriteRunnerRegistry`, `CodexRunner` (`pet.json`), `MotiveRunner` (`motive.json`), `ValidationFinding`. |
| `MotiveUI` | AppKit/SwiftUI surfaces. | `SpriteHost` (engine ↔ SwiftUI bridge, publishes `queueActive`), `SpriteView` (atlas renderer), `SpriteBoxWindow` (bubbles, hover skip/clear queue controls, optional chat + action buttons), `NotificationMenu`, `SettingsWindow` (capability-driven, `extraSections` for custom panes). |
| `MotiveHTTP` | Loopback REST control plane (SwiftNIO). | `MotiveServer` — token auth, rate limit, SSE; see [API.md](API.md). |
| `MotiveMCP` | MCP tool layer over the same surface. | `MCPServer` (newline-delimited JSON-RPC stdio), `MotiveCommandTransport` with `LocalCommandTransport` (in-process) and `RESTCommandTransport` (proxy); the `motive-mcp` executable is the discovery shim. |
| `MotiveAgents` | Teaching agents about the pet. | `AgentInstaller` implementations (Claude Code, Codex, OpenCode, Claude Desktop config merge), `SkillGenerator`, `ConnectPrompt`. |
| `MotiveDemo` | Reference composition of everything above; ships as the downloadable demo app with the Winston sprite. | — |

Supporting directories: `Sprites/winston/` (the bundled sprite package, in both
formats), `scripts/` (packaging, demo driver, icon, worktrees), `Resources/`
(app bundle plist + icon), `.github/workflows/` (CI + release).
