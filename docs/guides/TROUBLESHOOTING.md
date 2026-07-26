# Troubleshooting

> **Audience:** anyone with a companion that will not start, will not connect, or will not talk.
> **Prerequisites:** none.
> **Source of truth:** the error types named in each entry.

Symptom first, then the cause, then the fix.

## Starting up

**`motive-demo: no sprite package found.`**
Nothing in the lookup chain contained a `motive.json`. The demo checks
`$MOTIVE_SPRITE`, then the first command-line argument, then `./Sprites/winston`,
then `winston` in the app bundle's resources. Run from the repo root, pass a
path, or set `MOTIVE_SPRITE`.

**`sprite package not found at …` / `no sprite manifest found in … — expected motive.json`**
`SpriteLoadError`. The path is wrong, or the directory has no `motive.json` at
its top level. Point at the directory, not at the manifest file inside it. If the
package is an old `codex/1` (`pet.json`) one, see
[../FORMATS.md](../FORMATS.md#migrating-from-codex1-petjson).

**`invalid sprite manifest: …`**
The manifest parsed but failed validation — a state naming a missing `then`
target, a `ms` array whose length does not match the frame count, an atlas path
escaping the package. The message names what is wrong and what would be valid.
This is deliberate: loaders are tolerant of unknown *keys* (so new manifest
features do not break old loaders) and loud about invalid *values* (so a typo
does not silently animate the wrong row).

**The app launches, nothing appears on screen.**
Check the menu bar for the paw. The demo runs as an accessory — no Dock icon, no
main window — and the sprite box may be behind another window if *Always on top*
was turned off, or hidden from a previous session. Menu bar → *Show Winston*.

**Downloaded `.app` refuses to open.**
It is not notarized yet. Right-click → **Open**, then confirm. A double-click
gets you Gatekeeper's refusal with no override.

## Connecting

**`curl: (7) Failed to connect`**
Either the app is not running, or the control plane is off (Settings → Control
Plane → REST API), or you are using the wrong port. 7877 is *preferred*, not
guaranteed: a collision falls back to an ephemeral port and `server.json` records
the truth. Always read the port rather than assuming it:

```sh
PORT=$(python3 -c "import json;print(json.load(open('$HOME/.motive/runtime/server.json'))['port'])")
```

**`401` on every request.**
The token rotated. It regenerates on every server start — and *also* on every
restart caused by changing a Control Plane setting. Re-read
`~/.motive/runtime/token`. If you copied a connect prompt into an agent, copy it
again.

**`~/.motive/runtime/` is empty or missing.**
Those files exist only while a server is running; `stop()` deletes both. If a
previous run was killed hard they may be stale instead — a `server.json` whose
`pid` is gone is a leftover. Durable state lives in `~/.motive/history/`, which
is a sibling of `runtime/` precisely so the shutdown sweep cannot touch it.

**Two instances fighting over the same files.**
Give each its own runtime home:

```sh
MOTIVE_HOME=$(pwd)/.motive-home swift run motive-demo
```

Everything honors it — the app, the MCP shim, `scripts/demo-curl.sh`. See
[../reference/ENVIRONMENT.md](../reference/ENVIRONMENT.md).

**`rate_limited`**
The shared token bucket refills at 30 requests/second with a burst of 60. Back
off; the limit is per-server, not per-client.

**`payload_too_large`**
Bodies are capped at 64 KB. If you are sending a script that large, you are past
the 64-step queue cap anyway.

**`unknown_state` / `unknown_trigger` / `invalid_items`**
The response carries a `valid` array listing what *would* have worked — the
surface is designed so a caller can self-correct from the error alone. `GET
/v1/schema` is the full vocabulary of the loaded sprite. Remember that aliases
count: Winston accepts `working` for `running`.

## Agents

**Claude Desktop does not see the companion.**
The shim is a separate binary from the app. Build it (`swift build -c release`),
point `claude_desktop_config.json` at `.build/release/motive-mcp` by absolute
path, and restart Claude Desktop. The shim rediscovers the running app on every
call, so it survives app restarts — but it still needs an app to find.

**The Claude Desktop row in Agent Skills does nothing.**
It could not locate `motive-mcp` on your `PATH` or next to the app, so it went
non-actionable rather than installing a broken config. Build the shim, or copy it
somewhere on your `PATH`.

**An agent keeps polling a question that never resolves.**
Only a human at the keyboard can answer, by design — no REST route and no MCP
tool resolves a question as answered. If the window is hidden, the human never
saw it. Menu bar → *Show Winston*, or check the queue window, where every
outstanding question is listed and answerable out of order.

**`unknown_question` on a poll.**
Either the id is wrong or the app restarted. Outstanding questions do not survive
a restart — only resolved ones are recorded — so treat `unknown_question` exactly
as you would `cancelled`.

## Voice

**Nothing is spoken.**
Settings → Voice → *Speak out loud* is off by default. Turning it on also changes
queue timing: a spoken line then holds the queue for as long as its audio.

**The microphone option is unavailable.**
Almost always because you are running `swift run` rather than a bundle. macOS
does not return an error to a process that requests speech recognition without
the right `Info.plist` usage descriptions — it *kills* it. So Motive preflights
and refuses instead, which is why there is no public initializer for speech input
and why the factory returns a `Result`. Settings → Voice names the exact missing
keys and **Copy fix** gives you the snippet. Build the bundle with
`scripts/build-demo-app.sh` to use it.

`MOTIVE_VOICE_DISABLED` also turns the whole thing off wholesale; check it if
voice vanished unexpectedly, especially in CI.

**Permission was denied once and now nothing asks again.**
That is a TCC denial, not a Motive state — recoverable only in System Settings →
Privacy & Security. `MotiveVoice.inputAvailability()` reports it as `.denied`
with the reason, distinct from `.unavailable` (this build *cannot*).

## Building and testing

**The build succeeds and then the test suite fails to link, or crashes with
SIGBUS / SIGSEGV part-way through.**
You added or reordered a defaulted parameter on a public actor's `init` or
method, and stale test objects are left behind. `swift package clean` fixes it.
Do not go hunting for a memory bug — this one has cost real hours.

**`swift test` fails on `testBundlePlistMatchesVersionConstant`.**
A version bump touched one of the two places instead of both:
`MotiveVersion.current` and `Resources/Info.plist` must agree.

**`swift test` fails on `testEveryStandardVerbHasATool`.**
A new verb landed in `standardVerbs` without a matching MCP tool. Add the tool;
`cancel-script` and `events` are the only documented exemptions.

**Adding the official MCP swift-sdk breaks the build.**
Known: at 0.9.0 it does not compile under strict-concurrency toolchains, which is
why `MotiveMCP` hand-rolls newline-delimited JSON-RPC. Check that it builds
before adding the dependency back.

## Still stuck

`GET /v1/activity` is the durable record of everything the companion and the human did
— commands accepted, questions asked, how each resolved — with monotonic
sequence numbers that survive restarts. It is the right first stop for "what
actually happened", and better than SSE for it, because SSE has no replay.

Then [open an issue](https://github.com/Salable/motive/issues) with your macOS
version, your Swift version, and — for sprite problems — the manifest.
