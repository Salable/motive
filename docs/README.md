# Motive Documentation

Start with the [project README](../README.md) for the elevator pitch and a
five-minute demo. Then pick the doc for what you're doing:

| Doc | Read it when you want to… |
| --- | --- |
| [ARCHITECTURE.md](ARCHITECTURE.md) | understand the layering, the design principles, and what each component owns |
| [EMBEDDING.md](EMBEDDING.md) | build your own pet app on the Motive packages |
| [FORMATS.md](FORMATS.md) | author a sprite package (`pet.json` / `motive.json`) or add a new format runner |
| [API.md](API.md) | drive a running pet over the REST control plane |
| [INTEGRATIONS.md](INTEGRATIONS.md) | connect agents — Claude Code / Codex / OpenCode skills, Claude Desktop / ChatGPT Desktop MCP |
| [RELEASING.md](RELEASING.md) | cut a release or package the demo app bundle |

## Reading paths

- **"I want a pet in my app"** — [EMBEDDING.md](EMBEDDING.md), then
  [FORMATS.md](FORMATS.md) for your own sprite, then
  [INTEGRATIONS.md](INTEGRATIONS.md) to let agents drive it.
- **"I want to draw a new sprite"** — [FORMATS.md](FORMATS.md). Test it by
  pointing the demo at your package: `MOTIVE_SPRITE=path/to/package swift run motive-demo`.
- **"I want my agent to drive a running pet"** — [INTEGRATIONS.md](INTEGRATIONS.md)
  for the hookups, [API.md](API.md) for the wire details.
- **"I want to contribute to Motive itself"** — [CONTRIBUTING.md](../CONTRIBUTING.md),
  then [ARCHITECTURE.md](ARCHITECTURE.md) for the rules the codebase follows.
