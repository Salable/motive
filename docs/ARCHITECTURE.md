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
