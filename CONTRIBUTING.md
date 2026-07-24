# Contributing to Motive

Thanks for your interest in Motive!

## Building and testing

Requires macOS 13+ and Swift 5.10+ (Xcode 15.3+).

```sh
swift build
swift test
```

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

## Pull requests

- Keep PRs focused; one logical change per PR.
- Add or update tests for behavior changes. `swift test` must pass.
- Match the surrounding code style; no new dependencies without prior discussion in an issue.

## Reporting issues

Include your macOS version, Swift version, and — for sprite-loading issues — the sprite's manifest (`pet.json` / `motive.json`).
