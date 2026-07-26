# TalkBox

A native macOS desktop app (Native SDK) that plays a speech queue out
loud: POST text to a local REST API and a supervised speaker sidecar
(AVSpeechSynthesizer) speaks each item in turn, with a configurable
gap between them. Items are reorderable and removable while queued.
**No audio file is ever created** — the only artifact is a tiny job
JSON, deleted by the sidecar on pickup.

```
POST /speak {"text":"…","position":"last|next"} → 202 {"job_id":N} instantly
        ▼
  pending queue (in the Model: reorder / remove / clear here)
        ▼  one at a time, when autoplay + gap delay allow
  spool file → speaker sidecar → AVSpeechSynthesizer → 🔊 speakers
        ▼  NDJSON status (speaking → done|skipped|failed)
  recent history · GET /jobs/{id} · GET /state
```

A note can also ask for a reply: `{"text":"…","expects_response":true}`
pauses the whole queue once it finishes speaking, until the human
types an answer, speaks one (transcribed on-device), or declines — the
agent just keeps polling `GET /jobs/{id}` for `response_state`. See
**Replying to a note** below.

## The window

TalkBox implements the "TalkBox v2" design (`docs/design-import/`) —
an appliance-like two-pane layout, in light and dark (Settings →
Appearance follows the macOS appearance by default, or pins either
scheme):

- **Speaker bay** (left) — the Pacifico wordmark, a baked icon of the
  wall-mount speaker plate (dot-grid grille + screws + inset panel)
  with a live LED lens overlaid on top (green playing / amber paused /
  blue awaiting your reply / gray idle), and three 44px circular
  transport buttons (play, pause/resume, skip — skip doubles as
  **Decline** while a reply is awaited). This column is the window's
  drag region — hidden-inset chrome puts the traffic lights over its
  top-left corner.
- **Queue / Settings** (right) — a segmented tab control (white
  active pill on a gray track) switches between:
  - **Queue** — a speaking card (EQ-bars icon, badge, progress bar)
    that becomes a **reply composer** once a note that asked for one
    finishes (a text field, a mic button when voice replies are
    enabled, Decline/Send), pastel-tinted pending rows (click to
    select, ↑/↓ move it, ⌘↑/⌘↓ reorder, Delete removes, right-click
    for Move to Top/Up/Down/Remove), Autoplay switch, Clear (asks first — and
    also resolves a stuck awaiting reply), and a HISTORY list with
    done/skipped chips, adaptive durations ("2.5 s"/"900 ms"), and a
    link-style Requeue.
  - **Settings** — SPEECH (voice picker, speaking-rate and gap
    presets), SERVER (editable port + Make-public switch, both of
    which **restart the HTTP listener live** — no relaunch needed —
    a "Restart server" button that forces the same stop+rebind with
    no settings change (recovers a listener wedged by e.g. a Mac
    sleep/wake cycle), plus a Copy AGENTS.md button), GENERAL
    (Appearance: System/Light/Dark, Launch at login, Test mode),
    REPLIES (a Voice replies switch — off by
    default, so the mic/speech-recognition permission prompt only
    ever appears for someone who turns it on).
- **Menu bar** — Toggle Playback, Skip ⌘E, Clear Queue ⌘K, Settings
  ⌘,.
- **Menu-bar status item** — the icon itself carries state: a
  square-in-square outline (light band between the edges) when idle,
  the same frame with a filled play triangle when something is
  queued and playable, and a bold dot when a reply is awaited; ♪/⏸/"?"
  appear as text for speaking/paused/awaiting. The dropdown has up to
  four verbs: **Reply** (only while awaited — raises the window onto
  the composer), **Play** (only when queued and nothing is awaited),
  **Show Queue**, **View Settings** (the last two switch tabs *and*
  raise the window to the front).
- **Dock icon** — the hero speaker plate itself (squircle, screws,
  inset panel, grille, green LED).
- **Persistence** — queue + settings survive restarts
  (`~/Library/Application Support/TalkBox/state.json`, debounced
  writes); a restored queue is *held* silently until you act.

## Replying to a note

An agent asks for a reply the same way it queues anything else, plus
one flag:

```sh
curl -s -X POST localhost:4667/speak -d '{"text":"Ready to deploy — go ahead?","expects_response":true}'
```

Once that note finishes speaking, the **whole queue pauses** — nothing
else plays until the human types an answer, speaks one (transcribed
on-device via Apple's Speech framework, no audio file ever written),
or explicitly declines. The agent just polls `GET /jobs/{id}`:

```
{"response_state":"awaiting", ...}                                    # still deciding
{"response_state":"answered","response":"go ahead","response_via":"typed"}  # or "voice"
{"response_state":"declined", ...}                                    # said no
```

There is **no endpoint for an agent to submit a reply itself** — only
the app's own UI can, by design: the whole point is a genuine
human-in-the-loop check, and no server-side timeout exists (an
unanswered job just stays `"awaiting"`, so an agent decides its own
patience). Full contract and a worked example: `GET
/agent-instructions`. The voice half is transcribed by its own
sidecar, built by `tools/build-listener.sh`.

**The voice path needs a packaged .app — see Packaging below.**
macOS doesn't gracefully deny a process that requests
microphone/speech-recognition access without the right Info.plist
keys — it kills it outright (confirmed directly: the listener sidecar
crashed with `TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION` the instant it
asked, unpackaged). Typed replies are unaffected and work everywhere.

## Requirements

- **macOS.** This is a native macOS app (AppKit + Metal); it doesn't
  build or run on other platforms.
- **Xcode Command Line Tools** — for `swiftc` (builds the two
  sidecars). `xcode-select --install` if `which swiftc` comes up empty.
- **Node.js + the Native SDK CLI** — `npm install -g @native-sdk/cli`
  gives you the `native` command everything below uses. Zig itself is
  fetched and managed automatically by `native` on first build — no
  separate Zig install needed.
- `native doctor` sanity-checks your toolchain (codesign, notarytool,
  webview backends, etc.). One known false-flag on some setups: it
  looks for a bare `zig` on PATH even though `native` never needs
  that — every command in this README goes through `native`, never
  `zig` directly, so this specific check doesn't need to pass.

## Quick start

```sh
# one-time: the dynamic-tray-icon SDK patch — WITHOUT THIS THE BUILD
# FAILS (StatusItemState.icon_path doesn't exist in the stock CLI)
patch -p1 -d "$(npm root -g)/@native-sdk/cli" < docs/sdk-patches/dynamic-tray-icon.patch

tools/build-speaker.sh         # one-time: swiftc builds the sidecar
native test                    # headless tests (fake effect executor)
native dev -Dautomation=true   # run (window opens, API on :4667)
```

Drive it from any process:

```sh
curl -s -X POST localhost:4667/speak -d '{"text":"First"}'
curl -s -X POST localhost:4667/speak -d '{"text":"Urgent","position":"next"}'
curl -s -X POST localhost:4667/queue/reorder -d '{"id":2,"move":"down"}'
curl -s -X POST localhost:4667/settings -d '{"delay_ms":500,"rate":1.5}'
curl -s localhost:4667/state | jq '.now_playing, .queue'
curl -s localhost:4667/llms.txt       # the agent guide
tools/verify.sh                       # the full end-to-end checklist
```

## Download a release

Grab the latest `TalkBox.app.zip` from the
[Releases page](https://github.com/nealriley/talkbox/releases), unzip,
and move `TalkBox.app` to `/Applications`. It's ad-hoc signed (not
notarized yet), so the **first** launch needs one extra step past
Gatekeeper — otherwise macOS silently refuses or App-Translocates it:

- **right-click → Open** (then confirm), or
- `xattr -d com.apple.quarantine /Applications/TalkBox.app`

After that first approval it opens normally. Proper Developer ID
signing + notarization (which removes this step entirely) is future
work. Releases are cut by pushing a `v*` tag.

## Packaging a real .app

```sh
tools/package-app.sh    # -> zig-out/package/TalkBox.app
```

Always use this script, not `native package` directly — the raw
command has two footguns the script closes: it silently bundles
whatever (possibly stale) binary `zig-out/bin` already holds instead
of rebuilding, and it omits both the Swift sidecars and the
mic/speech-recognition Info.plist keys. The script builds everything
fresh, copies the sidecars into `Contents/MacOS/` (where the app's
bundle-mode path resolution expects them — a packaged app launches
with cwd `/`, so the dev tree's relative paths are detected and
replaced at boot: sidecars beside the executable, job spool under
`~/Library/Application Support/TalkBox/jobs`), patches the
plist, and re-signs (ad-hoc by default).

The **Release** workflow builds this exact `.app` on a `v*` tag and
publishes it (see Download a release above); `workflow_dispatch` runs
it on demand and uploads the `.app` as an artifact without cutting a
Release.

One sharing note: the dev instance and a packaged app are the same
app id, so they share `state.json` and the port — don't run both at
once, and expect settings to carry across.

## The interface

| | |
|---|---|
| `POST /speak` `{"text","position"?,"expects_response"?}` | 202 `{"job_id":N,"poll":"/jobs/N"}` — id allocated before anything plays; `expects_response` pauses the queue on finish until the reply resolves |
| `GET /jobs/{id}` | `queued \| speaking \| done \| failed \| skipped` + `duration_ms` + `response_state`/`response`/`response_via` |
| `POST /queue/play` | play next now (autoplay off, held restore, or cut the gap short) |
| `POST /queue/pause` · `/queue/resume` | pause/resume the current utterance (idempotent) |
| `POST /queue/skip` | stop the current utterance immediately |
| `POST /queue/clear` · `/queue/remove {"id"}` · `/queue/reorder {"id","move":"up\|down"}` | pending-item surgery |
| `POST /settings` `{autoplay?,delay_ms?,rate?,voice?,port?,public?,launch_at_login?,test_mode?,voice_replies_enabled?,appearance?}` | partial update — port/public **rebind the listener live** (reconnect on the new host:port); test_mode restarts the sidecar silent/live; appearance (`system\|light\|dark`) re-themes the window |
| `GET /state` | settings, now_playing (+elapsed_ms), paused, gap countdown, held, queue[], recent[], speaker health (~100ms republish) |
| `GET /healthz` · `/openapi.json` · `/llms.txt` · `/agent-instructions` | liveness · OpenAPI 3.1 · agent guides |

Port 4667 default (`TALKBOX_PORT` env, or the persisted/API
`port` setting on the next bind). `TALKBOX_FAKE=1` pins the
sidecar to silent simulated timing for the whole session (headless
CI); the same behavior is available live via the **Test mode**
setting / `POST /settings {"test_mode":true}` without restarting the
app.

**Security posture, stated plainly: the API has no authentication.**
The default bind (127.0.0.1) trusts every process on your Mac —
that's the design: any local agent can drive it. "Make public"
(0.0.0.0) extends that trust to every device that can reach the
port: they can speak through your Mac, clear your queue, read reply
text, and change settings. Only turn it on within a network where
that's acceptable (e.g. a personal tailnet) — never on untrusted
Wi-Fi, and don't port-forward it.

## Architecture notes

- **The queue lives in the Model, not the spool.** Exactly one item is
  in flight with the sidecar at any moment; everything else stays in
  the app where reordering is a memory swap. The autoplay engine is
  three small functions (`maybeDispatch` / `dispatchNext` /
  `finishCurrent`) driven by sidecar status lines and one-shot gap
  timers.
- **An awaiting reply is the same "current" item, not a new field.**
  `finishCurrent` gives a `.done` item that asked for a reply a
  `response_state` of `.awaiting` and leaves it in `model.current`
  instead of archiving it — `maybeDispatch`'s existing
  `current != null` guard blocks the rest of the queue for free, and
  `GET /jobs/{id}`/`GET /state` keep reporting it with zero new
  plumbing. `resolveAwaitingReply` (Send/Decline) is the mirror-image
  close: fills in the response, defers the archive, resumes autoplay.
- **Threading rule**: the Model is touched only on the loop thread;
  the HTTP thread talks to `src/bridge.zig` (spin-locked command queue
  + snapshot + jobs mirror), drained by a 100ms tick. Job ids come
  from an atomic counter so `POST /speak` answers immediately, and an
  allocated-but-unmirrored id polls as `queued`.
- **Skip and graceful stop** both use sentinel files the sidecar polls
  (`fx.cancel` is SIGKILL — never an option for anything stateful).
  Jobs queued while the sidecar is crashed wait in the app and resume
  after the supervisor respawns it (backoff 500ms→8s, give-up after 5,
  `ready` refills the budget).
- **Bind changes are live**: `applyBind` stops the running
  `*server.Server` and rebinds it in the same update — no relaunch.
  The Settings port/public fields edit *drafts*; a "Save and restart"
  row appears only when a draft differs from what's actually bound.
- **Only `<panel>` paints** background/border/radius in this SDK's
  markup — `row`/`column`/`stack` are pure layout. Every tinted
  surface in `app.native` is a panel wrapping its layout.
- **Dynamic tray icon** required a small SDK patch (the platform only
  supported a static tray icon + live title/menu) — without it,
  `src/main.zig`'s `StatusItemState.icon_path` field doesn't exist and
  the build fails. The patch targets relative paths (`src/...`) inside
  the CLI package, so it applies the same way regardless of where npm
  installed it:
  ```sh
  patch -p1 -d "$(npm root -g)/@native-sdk/cli" < docs/sdk-patches/dynamic-tray-icon.patch
  ```
  Needed once per machine/CI runner, and again after any
  `@native-sdk/cli` update. CI (`.github/workflows/ci.yml`) runs this
  automatically after installing the CLI.
- Settings changes route through one `applySettings` for UI and API
  alike — turning autoplay on from either side wakes a waiting queue.
- **The voice-reply sidecar is ephemeral, not persistent.** Unlike the
  supervised, always-running speaker, `listener-sidecar` is spawned
  fresh per recording attempt and never respawned — a denial or crash
  just resets the UI to idle so the user can tap the mic again. It
  streams mic input straight into on-device speech recognition (no
  audio file, ever, at any point) and is controlled by the same
  sentinel-file trick as the speaker's skip/transport, since
  `fx.cancel` is still SIGKILL-only.

## Files

- `src/main.zig` — shell config, tray/menu wiring, font + icon
  registration, `main()` wires bridge → server → runtime
- `src/model.zig` — the queue engine, supervision, settings, live
  bind, snapshot encoder/decoder
- `src/app.native` — the desktop layout (hot-reloads under `native
  dev`)
- `src/theme.zig` — the TalkBox theme, light + dark registers
  (colors, radii, the Pacifico wordmark font id)
- `src/bridge.zig` — thread boundary (commands, job ids, jobs mirror)
- `src/server.zig` — routes, `openapi.json`, `llms.txt`
- `src/ndjson.zig` — speaker protocol parser
- `src/icons/` — custom `app:` icons (speaker grille, full plate, EQ
  bars) in the SDK's flat SVG dialect
- `src/fonts/` — the Pacifico (OFL) wordmark face
- `src/tests.zig` — headless tests: markup, queue engine, selection/
  keys, pause/resume, persistence, command routing, tray routing +
  bring-to-front, live bind rebind, test mode, supervision, loopback
  HTTP, and the whole reply feature (blocking, typed/voice resolution,
  escape hatches, persistence round-trip)
- `sidecar/speaker.swift` — the TTS sidecar (spool jobs, rate, skip)
- `sidecar/listener.swift` — the ephemeral reply-transcription sidecar
  (streaming, on-device, no audio file ever)
- `tools/build-speaker.sh` / `tools/build-listener.sh` — swiftc builds
- `tools/package-app.sh` — THE packaging entry point: fresh build +
  bundle + sidecars + plist keys + re-sign (see Packaging above)
- `tools/patch-info-plist.sh` — adds the mic/speech-recognition
  Info.plist keys `native package` doesn't emit, to a packaged .app
- `assets/icon.svg` — the dock icon (the hero speaker plate)
- `assets/tray-logo.png` / `assets/tray-play.png` / `assets/tray-reply.png`
  — the dynamic menu-bar icon's three states
- `docs/design-import/DESIGN-DELTAS.md` — the full design-fidelity
  log (every gap found against the reference render and how/whether
  it was closed)
- `docs/sdk-patches/dynamic-tray-icon.patch` — the SDK patch enabling
  live tray-icon swaps

## Contributing

Conventions, the lint gate (`tools/lint.sh`), the PR → squash-merge
flow, and the release process all live in
[CONTRIBUTING.md](CONTRIBUTING.md). Short version: branch as
`feat|fix|docs|chore|refactor/<slug>`, run `tools/lint.sh` +
`native test` + `native check --strict` (+ `tools/verify.sh` for
behavior changes) before pushing, and every change — maintainer
included — lands on `main` through a PR with green CI.
