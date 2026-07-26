# Motive Documentation

> **Audience:** everyone. This is the map.
> **Prerequisites:** none.
> **Source of truth:** the tree below; [DOCUMENTATION.md](DOCUMENTATION.md) explains how it is organised.

Four kinds of page, because a reader learning and a reader looking something up
want opposite things. Find your row.

| I want to… | Go to |
| --- | --- |
| get a pet on my desktop in five minutes | [guides/QUICKSTART.md](guides/QUICKSTART.md) |
| know everything the demo app does | [guides/DEMO.md](guides/DEMO.md) |
| build my own pet, start to finish | [guides/FIRST-PET.md](guides/FIRST-PET.md) |
| fix something that is broken | [guides/TROUBLESHOOTING.md](guides/TROUBLESHOOTING.md) |
| understand *why* it behaves like that | [concepts/](#concepts) |
| look up a product's types and parameters | [components/](#components) |
| copy a recipe into my app | [EMBEDDING.md](EMBEDDING.md) |
| drive a running pet over HTTP | [API.md](API.md) |
| connect an AI agent | [INTEGRATIONS.md](INTEGRATIONS.md) |
| author a sprite | [FORMATS.md](FORMATS.md) |
| contribute to Motive itself | [../CONTRIBUTING.md](../CONTRIBUTING.md), then [ARCHITECTURE.md](ARCHITECTURE.md) |
| write documentation | [DOCUMENTATION.md](DOCUMENTATION.md) |

## Guides

Read start to finish; each one has one happy path.

- [QUICKSTART.md](guides/QUICKSTART.md) — run the demo, find the door, drive it
- [DEMO.md](guides/DEMO.md) — every menu item and setting in `motive-demo`
- [FIRST-PET.md](guides/FIRST-PET.md) — an empty directory to a working pet
- [TROUBLESHOOTING.md](guides/TROUBLESHOOTING.md) — symptom, cause, fix

## Concepts

The mental model. Read these when the behavior surprised you.

- [QUEUE.md](concepts/QUEUE.md) — why every action is a queue item, and why a
  direct verb plays *next* rather than last
- [STATES.md](concepts/STATES.md) — states, triggers, interrupt policy,
  transitions
- [QUESTIONS.md](concepts/QUESTIONS.md) — human-in-the-loop, and why no API can
  answer
- [VOICE.md](concepts/VOICE.md) — speaking, listening, and the entitlement gate
- [RUNTIME.md](concepts/RUNTIME.md) — the runtime home, discovery, and auth

## Components

One page per product: what it owns, its key types and their parameters, the
integration patterns, and the gotchas.

- [OVERVIEW.md](components/OVERVIEW.md) — **start here**: which product do I need
- [CORE.md](components/CORE.md) · [SPRITE.md](components/SPRITE.md) ·
  [UI.md](components/UI.md) · [HTTP.md](components/HTTP.md) ·
  [MCP.md](components/MCP.md) · [AGENTS.md](components/AGENTS.md) ·
  [VOICE.md](components/VOICE.md)

Symbol-level reference for every public type is generated from the source by
DocC and published to
[GitHub Pages](https://salable.github.io/motive/documentation/motivecore).

## Recipes and wire formats

- [EMBEDDING.md](EMBEDDING.md) — task-titled recipes for building on the packages
- [INTEGRATIONS.md](INTEGRATIONS.md) — Claude Code, Codex, OpenCode, Claude
  Desktop, ChatGPT Desktop
- [API.md](API.md) — the REST control plane, endpoint by endpoint
- [FORMATS.md](FORMATS.md) — `pet.json` (`codex/1`) and `motive.json` (`motive/1`)

## Reference

- [ENVIRONMENT.md](reference/ENVIRONMENT.md) — every environment variable, file,
  and limit
- [CLI.md](reference/CLI.md) — `motive-demo`, `motive-mcp`, and every script

## Project

- [ARCHITECTURE.md](ARCHITECTURE.md) — layering and the invariants that hold it
  together
- [RELEASING.md](RELEASING.md) — cutting a release
- [DOCUMENTATION.md](DOCUMENTATION.md) — how this doc set is structured, and
  what a new feature must document
- [proposals/](proposals/) — design records. Historical once shipped; read them
  for the reasoning, not for current behavior.

## Reading paths

- **"I want a pet in my app"** — [guides/FIRST-PET.md](guides/FIRST-PET.md),
  then [FORMATS.md](FORMATS.md) for your own sprite, then
  [INTEGRATIONS.md](INTEGRATIONS.md) to let agents drive it.
- **"I want to draw a new sprite"** — [FORMATS.md](FORMATS.md). Test it with
  `MOTIVE_SPRITE=path/to/package swift run motive-demo`.
- **"I want my agent to drive a running pet"** —
  [INTEGRATIONS.md](INTEGRATIONS.md) for the hookups,
  [API.md](API.md) for the wire details,
  [concepts/QUEUE.md](concepts/QUEUE.md) for why it behaves as it does.
- **"I want to contribute"** — [../CONTRIBUTING.md](../CONTRIBUTING.md), then
  [ARCHITECTURE.md](ARCHITECTURE.md) for the rules, then
  [DOCUMENTATION.md](DOCUMENTATION.md) for what your PR must document.

This tree is mirrored to the [GitHub wiki](https://github.com/Salable/motive/wiki)
on every merge to `main`. The repository is the source of truth; wiki edits are
overwritten.
