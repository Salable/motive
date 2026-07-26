# Contributing to TalkBox

Thanks for wanting to make the box talk better. This is a small,
sharp repo — the process below keeps it that way.

## Dev setup

macOS only (AppKit + Metal + AVSpeechSynthesizer).

```sh
# 1. The Native SDK CLI, pinned to the version this repo is built against
npm install -g @native-sdk/cli@0.4.2

# 2. The dynamic-tray-icon SDK patch — the build FAILS without it
#    (StatusItemState.icon_path doesn't exist in the stock CLI)
patch -p1 -d "$(npm root -g)/@native-sdk/cli" < docs/sdk-patches/dynamic-tray-icon.patch

# 3. Sidecars (swiftc, from Xcode Command Line Tools)
tools/build-speaker.sh && tools/build-listener.sh

# 4. Run it
native dev -Dautomation=true     # window opens, API on :4667
```

Notes: Zig is managed by the `native` CLI (installed to
`~/.native/toolchains/` on first build — it is not on PATH, and you
never invoke `zig` directly). `shellcheck` is optional locally
(`brew install shellcheck`) but runs in CI regardless.

## Checks — run these before pushing

```sh
tools/lint.sh              # format + convention gates (same as CI)
native test                # 56+ headless tests, fake effect executor
native check --strict      # markup <-> model contract
tools/verify.sh            # live end-to-end (see below)
```

`tools/verify.sh` needs a running `native dev -Dautomation=true` and
**speaks audibly** unless you started the app with `TALKBOX_FAKE=1`.
It cannot run in CI (no live app/audio on runners), so running it
locally is YOUR responsibility whenever a change affects behavior —
the PR checklist asks you to attest to it. Docs-only changes may skip
it.

## Naming conventions

| Thing | Convention | Example |
|---|---|---|
| Branches | `feat\|fix\|docs\|chore\|refactor/<kebab-slug>` | `feat/reply-timeout` |
| Commits / PR titles | Imperative subject ≤72 chars; body explains *why* | `Add manual "Restart server" button` |
| Tags | `vMAJOR.MINOR.PATCH` | `v0.7.0` |
| Zig | std conventions: types `PascalCase`, fns `camelCase`, fields/consts `snake_case` | `ResponseState`, `jobsDir`, `reply_stop_file_key` |
| Tests | lowercase descriptive sentences | `test "the queue drains in order"` |
| JSON API fields | `snake_case` | `expects_response`, `response_via` |
| Shell scripts | POSIX `sh`, `set -eu`, kebab-case names | `tools/package-app.sh` |

Two rules the linter enforces with teeth:
- **Never `cmd && echo "ok"` in tools scripts** — under `set -e` that
  pattern does NOT stop the script when `cmd` fails. Put the command
  and its echo on separate lines. (This bit us: 15 checks once passed
  silently on failure.)
- **The version lives in two places** — `app.zon` `.version` and the
  OpenAPI document in `src/server.zig` — and they must match.

## Submitting a change

1. **External contributors**: fork, then branch. **Maintainers**:
   branch on the repo. Either way, branch from `main` using the
   naming above.
2. Make the change; add/extend tests in `src/tests.zig` for behavior
   changes (a fix without a regression test isn't done).
3. Run all four checks above.
4. Open a PR against `main` and fill in the template. The PR title
   becomes the commit subject on `main` (we squash-merge), so write
   it like a commit.
5. CI must be green (lint + tests + markup check). Fork PRs run CI
   safely — no secrets are used — but a first-time contributor's run
   may need a maintainer approval click.
6. Review, then **squash merge**. `main` stays linear: one commit per
   PR, imperative subject, why-focused body.

Direct pushes to `main` are disabled for everyone, maintainers
included — every change takes this road.

## Releasing

1. Bump the version in **both** places (the linter blocks a mismatch):
   `app.zon` `.version` and the `"version"` inside `openapi_json` in
   `src/server.zig`.
2. PR + squash-merge as usual.
3. Tag and push:
   ```sh
   git tag -a vX.Y.Z -m "TalkBox vX.Y.Z — <one-line summary>"
   git push origin vX.Y.Z
   ```
4. The Release workflow builds `TalkBox.app` (via
   `tools/package-app.sh`), and publishes a GitHub Release with
   `TalkBox.app.zip` attached. A tag that disagrees with `app.zon`'s
   version is refused by the workflow's first step.
5. Sanity-check the published asset: download, unzip once, right-click
   → Open (ad-hoc signed), confirm it speaks.

## Proposing features / reporting bugs

Open an issue with the matching template. For features, lead with the
problem, not the solution — and note which surface it touches (queue,
settings, replies, tray, HTTP API). The API has a hard design rule
worth knowing before proposing: **replies are UI-only** — there is
deliberately no HTTP route to answer a reply, because the whole point
is a human-in-the-loop check an agent can't perform on itself.
