# Contributing to Motive

Thanks for your interest in Motive! This is the path from checkout to merged
PR; [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) explains the design rules the
codebase follows, and [docs/RELEASING.md](docs/RELEASING.md) covers how merged
work ships.

## Building and testing

Requires macOS 13+ and Swift 5.10+ (Xcode 15.3+).

```sh
swift build
swift test
swift run motive-demo    # run the demo pet from the checkout
```

CI runs `swift build` + `swift test` on macOS for every PR and push to `main`.

## Ground rules

Seven architecture invariants govern the codebase, several pinned by tests.
They are stated once, with their rationale, in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — read that before your first PR.
The headlines:

- **Sprites are data, never code**, decoded tolerantly and validated loudly.
- **Core stays UI-free** — and audio-free, and timer-free.
- **One command surface**: REST and MCP are 1:1 adapters over `MotiveControl`.
- **Every verb ships rendered.**
- **Queue-first**: no bypass paths around `ActionQueue`.
- **Answers originate only from UI input.**

## Working on features in parallel

Use git worktrees so each feature branch has its own checkout, build directory, and
runtime — no stash-dance between branches:

```sh
scripts/worktree.sh new my-feature        # branch feature/my-feature in .worktrees/my-feature
cd .worktrees/my-feature && swift test    # independent .build/
scripts/worktree.sh list
scripts/worktree.sh remove my-feature     # after merging
```

To run two demo instances side by side, give each worktree its own runtime home so
tokens and discovery files don't collide:

```sh
MOTIVE_HOME=$(pwd)/.motive-home swift run motive-demo
```

(Preferred-port collisions fall back to an ephemeral port automatically; each home's
`runtime/server.json` records the actual one.)

## Branches, commits, and pull requests

- Branch from `main` as `feature/<name>` (what `scripts/worktree.sh new` does);
  merge back via pull request with CI green.
- Keep PRs focused; one logical change per PR. Larger efforts land as a series
  of small commits with imperative subjects — see the git history for the
  house style.
- Add or update tests for behavior changes. `swift test` must pass.
- **Documentation ships with the feature.** A feature is not done when it is
  tested; it is done when a stranger can find it.
  [docs/DOCUMENTATION.md](docs/DOCUMENTATION.md) is the contract — it explains
  the four kinds of page, which ones your change affects, and the metadata
  header every page carries. Add a line to the `[Unreleased]` section of
  [CHANGELOG.md](CHANGELOG.md) for anything user-visible, and run
  `scripts/check-doc-links.py` before pushing.
- Match the surrounding code style; no new dependencies without prior
  discussion in an issue.

## Reporting issues

Include your macOS version, Swift version, and — for sprite-loading issues — the sprite's manifest (`pet.json` / `motive.json`).
