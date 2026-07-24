# Changelog

All notable changes to Motive are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- **`skip` verb** — the single-item counterpart of clear-queue: the current
  queue item ends immediately and the next pending item plays; pending is
  preserved, and a skipped `say`'s bubble is dismissed. Full command surface:
  `MotiveEngine.skipCurrent()` / `MotiveControl.skip()`,
  `DELETE /v1/queue/current`, the `motive_skip` MCP tool, declared in
  `standardVerbs` (auto-documented in generated agent skills), `skippedID` in
  receipts.
- **Default ("standard") state** as a first-class concept: the machine
  remembers its resolved initial state (`ActorStateMachine.defaultStateName`,
  `MotiveEngine.defaultState`), duration auto-revert targets it instead of a
  hardcoded `idle`, and **clearing the queue now returns the sprite to it** —
  stopping a scene can no longer leave the pet stuck in a state a dropped item
  would have cleaned up. Queue replacement (`play-script`) flushes without the
  reset, and natural drain still doesn't force a revert, so persistent direct
  states (an agent's `working`) survive.
- **Hover queue controls on the sprite box**: while the queue is playing and
  the pointer is over the box, skip (⏭) and stop-scene (✕) buttons appear in a
  fixed-height slot (no reflow); invisible otherwise, so the box stays
  chrome-free. `SpriteBoxWindow.Options.queueControlsEnabled` (default true)
  and `SpriteHost.queueActive` for embedders.

### Changed
- The demo sprite box is chrome-free: the Wave/Jump/Dash action buttons and the
  chat input (and its Settings toggle) are gone — Winston is sprite + speech
  bubbles only, driven entirely through the control plane. `SpriteBoxWindow`
  keeps `actions`/`chatEnabled` for embedders that want them.
- Onboarding tour v3: reworked as the feature showcase for the chrome-free box.
  One queued multi-step run now exercises the full `ScriptStep` vocabulary —
  length-paced says, zero-hold state changes under narration, one-shot triggers,
  and a demonstrated pause beat — and reframes interruption and the closing
  chapters around the control plane (agents, MCP, curl) instead of the removed
  chat/buttons.

## [0.3.0] - 2026-07-24

### Changed
- **Winston replaces Salli** as the bundled demo sprite: a black labradoodle puppy
  (WebP atlas) with a fully declared vocabulary — four one-shot triggers (`wave`,
  `jump`, and new `dash-left`/`dash-right` for the directional running states) in
  both `pet.json` and a canonical `motive.json`. The tour gains a triggers chapter
  demonstrating the dashes; the sprite box gains Dash buttons; the app icon is
  regenerated from Winston's idle frame.
- Onboarding tour v2: a chaptered ~25-item queued flow that tells the Motive story
  (what it is, the components, a narrated live states demo, messages & the queue,
  agent hookups) and points at github.com/Salable/motive; bubble holds now pace to
  text length. New "View on GitHub" menu-bar item.

## [0.2.0] - 2026-07-24

### Changed
- **Queue-first interaction model.** Every action is now a queue item processed in
  order. Direct verbs (`/v1/say`, `/v1/state`, `/v1/trigger` and the matching MCP
  tools) play *next* — they cut the current item's remaining hold and everything
  queued continues afterwards; nothing is dropped except by an explicit flush. New
  `POST/GET/DELETE /v1/queue` (append / inspect / flush), `motive_enqueue` and
  `motive_clear_queue` MCP tools, `queueDepth` in status, and SSE `queue` events.
  `/v1/script` remains as "replace the queue" sugar (v0.1.0 wire shape unchanged).
  Trigger items hold the queue for the gesture's length by default. `ScriptPlayer`
  replaced by `ActionQueue` in MotiveCore.
- Settings "Copy as curl" is now **Copy prompt**: a paste-into-any-agent connect
  prompt (`ConnectPrompt` in `MotiveAgents`) embedding the live port and token,
  proving the connection with a visible wave-and-say; public (0.0.0.0) binds ask the
  user to supply the base address.

## [0.1.0] - 2026-07-24

### Added
- `MotiveCore`: pure timer-free `ActorStateMachine` (interruption policies, crossfade
  transitions, one-shot triggers, then-chains, duration auto-revert), the `MotiveEngine`
  actor (tick clock, speech bubbles, typed event fan-out), the `MotiveControl` command
  surface with a self-describing schema, the `CapabilityRegistry`, and runtime discovery
  under `~/.motive/runtime/`.
- `MotiveSprite`: normalized `SpriteDefinition`, pluggable `SpriteRunner` registry,
  `CodexRunner` (`pet.json`, Codex/Fido-compatible) and `MotiveRunner` (`motive.json`,
  the motive/1 format — explicit frame layouts incl. cells and rects, multi-atlas
  states, duration shorthand, metadata block). Tolerant decode, loud validation.
- `MotiveUI`: `SpriteView` atlas renderer, `SpriteBoxWindow` (chat input, action
  buttons, speech bubbles), `NotificationMenu` menu-bar component, capability-driven
  `SettingsWindow`.
- `MotiveHTTP`: hardened loopback REST control plane (per-boot 0600 token,
  constant-time compare, rate limit, 64KB cap, SSE events, schema verb-honesty).
- `MotiveMCP` + `motive-mcp`: stdio MCP server (initialize/ping/tools/list/tools/call)
  with in-process and REST-proxy transports for Claude Desktop / ChatGPT Desktop.
- `MotiveAgents`: motive-companion skill installers for Claude Code, Codex, OpenCode,
  and a Claude Desktop MCP config merger — write-with-backup, uninstallable.
- `motive-demo` app bundling Salli, `scripts/build-demo-app.sh` packaging, release
  workflow attaching `MotiveDemo-<version>.zip` to tags.
- Script system: `ScriptStep`/`ScriptRun`/`ScriptPlayer` (pure, timer-free step
  sequencer — say/setState/trigger/pause with explicit holds, latest-wins
  cancellation on any external command), `POST /v1/script` + SSE script events, and
  the `motive_play_script` MCP tool. Demo plays a first-launch onboarding tour
  (replayable from the menu).
- Control-plane configurability: `MotiveServer` bind host (loopback or 0.0.0.0 with
  token auth unchanged), `ServerInfo.host`, and demo settings for REST on/off, port,
  and public bind with debounced live restart.
- `SettingsWindow` custom `extraSections`; demo Settings gains Agent Skills
  install/remove rows (Claude Code, Codex, OpenCode, Claude Desktop MCP) and a
  Control Plane Status pane with copy-as-curl.
