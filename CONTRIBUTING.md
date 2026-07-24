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

- **Sprites are data, never code.** Sprite packages are declarative JSON + images; nothing in a package is executed.
- **Every control-plane verb ships rendered.** Don't add API surface (REST route, MCP tool) that the renderer doesn't honor yet.
- **Core stays UI-free.** `MotiveCore` and `MotiveSprite` must not import AppKit/SwiftUI; all decision logic lives there so it can be unit tested.
- **Tolerant decode, loud validation.** Loaders accept unknown keys; the validator reports them. Every package load goes through the validator.

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
- Update the docs that describe what you changed (`docs/API.md` for control-plane
  changes, `docs/FORMATS.md` for manifest changes, and so on), and add a line
  to the `[Unreleased]` section of [CHANGELOG.md](CHANGELOG.md) for anything
  user-visible.
- Match the surrounding code style; no new dependencies without prior
  discussion in an issue.

## Reporting issues

Include your macOS version, Swift version, and — for sprite-loading issues — the sprite's manifest (`pet.json` / `motive.json`).
