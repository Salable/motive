# Motive

Composable Swift package (SwiftPM, macOS 13+, Swift 5.10+) for building desktop
"pet" apps — animated sprite companions driven by AI agents over REST or MCP.
Not one app: seven library products consumers mix and match, plus two
executables. `motive-demo` (Winston the labradoodle) is the reference
composition of all of them; `motive-mcp` is the stdio MCP shim.

## Commands

```sh
swift build                # build everything
swift test                 # full suite — must pass before any PR
swift run motive-demo      # Winston on the desktop, from the checkout
MOTIVE_HOME=$(pwd)/.motive-home swift run motive-demo   # isolated runtime (side-by-side instances)
scripts/build-demo-app.sh  # dist/MotiveDemo.app bundle (--universal, --zip)
scripts/demo-curl.sh       # drive a running demo through every REST verb
scripts/worktree.sh new <name>   # feature branch + worktree in .worktrees/<name>
scripts/check-doc-links.py       # every relative link in the docs resolves
scripts/sync-wiki.py --out build/wiki   # preview the wiki mirror locally
swift package generate-documentation --target MotiveCore   # DocC archive
```

Drive a running pet (port and token live under `~/.motive/runtime/`, or
`$MOTIVE_HOME/runtime/`):

```sh
PORT=$(python3 -c "import json;print(json.load(open('$HOME/.motive/runtime/server.json'))['port'])")
TOKEN=$(cat ~/.motive/runtime/token)
curl -H "Authorization: Bearer $TOKEN" -d '{"state":"jumping"}' "http://127.0.0.1:$PORT/v1/state"
```

## Answering questions about the framework

Route by intent instead of re-deriving from source. `docs/README.md` is the full
map; `docs/DOCUMENTATION.md` explains how the tree is organised and what a new
feature must document. Every page names its **Source of truth** in a blockquote
at the top — go there to verify a claim rather than trusting the prose.

| Question | Page |
| --- | --- |
| "What does Motive offer?" | `docs/components/OVERVIEW.md`; layering in `docs/ARCHITECTURE.md` |
| "How do I run the demo?" / "What does this menu item do?" | `docs/guides/QUICKSTART.md`, `docs/guides/DEMO.md` |
| "Help me build my own pet." | `docs/guides/FIRST-PET.md` (tutorial) or `docs/EMBEDDING.md` (recipes). `Sources/MotiveDemo/main.swift` is the everything-at-once reference. |
| "What are the parameters of X?" | `docs/components/<PRODUCT>.md`, then the `///` comments |
| "Why does it behave like that?" | `docs/concepts/` — QUEUE, STATES, QUESTIONS, VOICE, RUNTIME |
| "Author a sprite?" | `docs/FORMATS.md`. Test with `MOTIVE_SPRITE=path swift run motive-demo`. |
| REST wire details | `docs/API.md` |
| Agent / MCP hookup | `docs/INTEGRATIONS.md` |
| Env vars, files, limits | `docs/reference/ENVIRONMENT.md` |
| Executables and scripts | `docs/reference/CLI.md` |
| Something is broken | `docs/guides/TROUBLESHOOTING.md` |
| Cutting a release | `docs/RELEASING.md` |

`docs/proposals/` is design record, not current behavior — read it for reasoning
and check the code before quoting it as fact.

## Documenting a change

`docs/DOCUMENTATION.md` is the contract. In short, before opening a PR ask which
of the four modes your change touches:

1. Changes the mental model → a `docs/concepts/` page
2. Changes a product's public surface → the matching `docs/components/` page,
   plus `///` comments so DocC picks it up
3. Changes the wire or the disk → `docs/API.md`, `docs/FORMATS.md`,
   `docs/INTEGRATIONS.md`, or `docs/reference/ENVIRONMENT.md`
4. Lets someone do something new → a recipe in `docs/EMBEDDING.md` and a
   `CHANGELOG.md` `[Unreleased]` line

A new verb is three code edits *and* two table edits — `standardVerbs`, REST
route, MCP tool, `docs/API.md`, `docs/INTEGRATIONS.md` — in one commit. The
tables are how an agent learns the verb exists.

New pages open with the metadata blockquote (audience, prerequisites, source of
truth) and are picked up by the wiki mirror automatically. Run
`scripts/check-doc-links.py` before pushing.

## Architecture invariants

Enforced in review; several are pinned by tests. Full rationale in
`docs/ARCHITECTURE.md`.

- **Layering:** `MotiveCore` depends on nothing; `MotiveSprite → Core`; servers
  (`MotiveHTTP`, `MotiveMCP`) depend on Core only — never UI. `MotiveUI` depends
  on Core + Sprite. Core/Sprite must never import AppKit or SwiftUI.
- **One command surface:** REST routes and MCP tools are 1:1 adapters over
  `MotiveControl` — no semantics of their own. New verb = `standardVerbs` entry
  + REST route + MCP tool together (`testEveryStandardVerbHasATool` enforces
  parity; `cancel-script` and `events` are the documented exemptions).
- **Every verb ships rendered:** no API surface for behavior the renderer
  doesn't honor.
- **Queue-first:** every action is a queue item. Direct verbs head-enqueue
  ("plays next", cuts the current *hold*); flows tail-enqueue; nothing is dropped
  except by explicit flush. Don't add bypass paths around `ActionQueue`. An
  item with `.external` completion (a question, later a spoken line) has no hold
  to cut — direct verbs queue behind it and play once it resolves.
- **Answers originate only from UI input.** No verb, REST route, or MCP tool may
  resolve a question as answered; `MotiveEngine.answerQuestion` is reachable from
  `MotiveUI` alone. We have token auth, so an endpoint would let any local
  process forge a human's answer and the human-in-the-loop guarantee would be
  theatre. Agents ask, read, and withdraw. Enforced by absence and pinned by
  `testNoVerbAnswersAQuestion`.
- **Sprites are data, never code.** Tolerant decode (unknown keys pass), loud
  validation (bad values fail naming the valid vocabulary).
- **Timer-free logic:** engine and state machine take explicit `now:` clocks.
  Tests drive time by hand — never sleep to make a Core test pass.

## Conventions

- Branch `feature/<name>` from `main`; merge via PR with CI green. Imperative
  commit subjects; body explains why (see `git log` for house style).
- Behavior changes need tests, and user-visible ones need a `CHANGELOG.md`
  `[Unreleased]` entry (Keep a Changelog format).
- Documentation ships with the feature — see "Documenting a change" above and
  `docs/DOCUMENTATION.md` for the contract.
- Version bumps touch **both** `MotiveVersion.current` and
  `Resources/Info.plist` — `testBundlePlistMatchesVersionConstant` fails until
  they agree.
- The demo tour must stay inside Winston's vocabulary —
  `MotiveDemoTests` validates it against `Sprites/winston`.

## Gotchas

- The official MCP swift-sdk (0.9.0) does not compile under strict-concurrency
  toolchains — `MotiveMCP` hand-rolls newline-delimited JSON-RPC. Don't add the
  SDK dependency back without checking it builds.
- Universal binaries: per-arch `swift build` + `lipo` (see
  `scripts/build-demo-app.sh`) — combined `--arch` mode exits nonzero on GitHub
  runners.
- `FIRST_ATTEMPT/`, `SPRITE_EXAMPLES/`, and `SPEC.md` are gitignored pre-rewrite
  reference material — never commit or cite them as current.
- Adding or reordering a defaulted parameter on a public actor's `init` (or on
  an actor method) leaves stale test objects behind: the build "succeeds" and
  then the suite fails to link, or crashes with SIGBUS/SIGSEGV part-way through.
  `swift package clean` fixes it; don't go hunting for a memory bug first.
- README GIFs are generated (`scripts/make-readme-art.py`, deterministic);
  rerun manually only when the Winston atlas or `motive.json` changes.
