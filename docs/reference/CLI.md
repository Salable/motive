# Executables and Scripts

> **Audience:** anyone running Motive from a terminal or working on the repository.
> **Prerequisites:** a checkout, for the scripts.
> **Source of truth:** `Sources/MotiveDemo/`, `Sources/motive-mcp/`, `scripts/`.

## `motive-demo`

The reference composition — every product wired together with Winston as the
sprite. See [../guides/DEMO.md](../guides/DEMO.md) for what it does once running.

```
motive-demo [sprite-package-path]
```

No flags. One optional positional argument. Sprite package lookup order, first
directory containing a `motive.json` wins:

1. `$MOTIVE_SPRITE`
2. the positional argument
3. `./Sprites/winston` — so a checkout just works
4. `winston` inside the app bundle's resources — so the shipped `.app` just works

Exits 1 naming all three routes if none matches. Prints its address, token path,
and a ready-to-paste `curl` on start.

```sh
swift run motive-demo
swift run motive-demo ~/sprites/mysprite
MOTIVE_SPRITE=~/sprites/mysprite swift run motive-demo
MOTIVE_HOME=$(pwd)/.motive-home swift run motive-demo
```

## `motive-mcp`

A standalone stdio MCP server. It holds no state and owns no companion: on every call
it rediscovers the running app through `$MOTIVE_HOME/runtime/` and proxies to its
REST plane. Rediscovering per call rather than at startup is what lets it survive
the app restarting underneath it — including the token rotation that comes with
one.

```sh
swift build -c release        # .build/release/motive-mcp
```

Register it by absolute path:

```json
{ "mcpServers": { "motive": { "command": "/abs/path/.build/release/motive-mcp" } } }
```

It reads `MOTIVE_HOME` from *its own* environment, which is the MCP host's
environment rather than your shell's. Speaks newline-delimited JSON-RPC 2.0 on
stdin/stdout; it is not useful to run interactively. The demo app bundles a copy
inside `MotiveDemo.app/Contents/MacOS/`. See
[../INTEGRATIONS.md](../INTEGRATIONS.md).

## Scripts

### `scripts/demo-curl.sh`

Drives a running demo through every REST verb — ping, schema, status, say, state
with auto-revert, trigger — and finishes by printing the SSE command for
`/v1/events`. Reads `${MOTIVE_HOME:-$HOME/.motive}/runtime/`, and tells you to
start a companion if it finds nothing. The fastest way to confirm the control plane
works.

### `scripts/build-demo-app.sh`

Produces `dist/MotiveDemo.app`.

| Flag | Effect |
| --- | --- |
| *(none)* | Native-architecture bundle. |
| `--universal` | arm64 + x86_64 via per-arch builds and `lipo`. |
| `--zip` | Also `dist/MotiveDemo-<version>.zip` via `ditto`. |

It regenerates the icon only if `Resources/AppIcon.icns` is missing, reads the
version out of `MotiveVersion.swift` and stamps it into the bundle plist, copies
`Sprites/winston` into resources, and codesigns with `${MOTIVE_SIGN_IDENTITY:--}`
(ad-hoc by default).

`--universal` does two separate `swift build` invocations and then `lipo`, rather
than one build with two `--arch` flags. The combined mode routes through xcbuild
and exits nonzero on GitHub runners; do not "simplify" it back.

### `scripts/worktree.sh`

```sh
scripts/worktree.sh new <name> [base]   # branch feature/<name> in .worktrees/<name>
scripts/worktree.sh list
scripts/worktree.sh remove <name>
```

Each worktree gets its own checkout and `.build/`, so parallel features need no
stash-dance. `remove` uses `git branch -d`, so an unmerged branch is kept rather
than silently destroyed. Give each worktree its own `MOTIVE_HOME` to run their
demos simultaneously.

### `scripts/make-icon.py`

Deterministic. Crops cell (0,0) of the Winston atlas onto a warm-paper rounded
rect and runs `iconutil` to produce `Resources/AppIcon.icns`. Needs Pillow. Run
it only when the atlas changes.

### `scripts/make-readme-art.py`

Deterministic. Reads rows, timings, and aliases from `motive.json` and emits the
looping GIFs in `docs/images/` — the hero and the four state cards. Run manually
(`python3 scripts/make-readme-art.py`) when the Winston atlas or `motive.json`
changes; nothing runs it automatically, so nothing will tell you it has gone
stale.

## Build and test

```sh
swift build
swift test
swift package clean     # after changing a defaulted parameter on a public actor
```

That last one is not superstition. Adding or reordering a defaulted parameter on
a public actor's `init` or method leaves stale test objects behind: the build
"succeeds" and then the suite fails to link, or crashes with SIGBUS/SIGSEGV
part-way through. `swift package clean` fixes it. Do not go hunting for a memory
bug.

CI runs `swift build` and `swift test` on macOS for every PR and push to `main`.
