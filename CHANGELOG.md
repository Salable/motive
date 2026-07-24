# Changelog

All notable changes to Motive are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed
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
