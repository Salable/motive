# The Demo App

> **Audience:** anyone running `motive-demo`, and embedders reading it as the reference composition.
> **Prerequisites:** [QUICKSTART.md](QUICKSTART.md).
> **Source of truth:** `Sources/MotiveDemo/` — `main.swift`, `DemoSettingsSections.swift`, `OnboardingScript.swift`.

`motive-demo` is not a product with a framework hiding inside it. It is the
reference composition: every Motive product wired together in about 400 lines,
with Winston as the sprite. Everything described here is something your own app
can do, and the file that does it is named in each section.

## Launching

```sh
swift run motive-demo                                    # from a checkout
swift run motive-demo path/to/sprite-package             # a different sprite
MOTIVE_SPRITE=path/to/package swift run motive-demo      # same, via environment
MOTIVE_HOME=$(pwd)/.motive-home swift run motive-demo    # isolated runtime
```

There are no flags — one optional positional argument, the sprite package path.
The demo looks for a package in this order and takes the first directory
containing a `motive.json`: `$MOTIVE_SPRITE`, the argument, `./Sprites/winston`
(so a checkout just works), then `winston` inside the app bundle's resources (so
the shipped `.app` just works). Finding none, it exits 1 and names all three
routes rather than starting to an empty desktop.

The app runs as an **accessory**: menu bar only, no Dock icon, no main window.
`app.setActivationPolicy(.accessory)` is the one line that does it, and
`LSUIElement` in `Resources/Info.plist` is its bundle equivalent.

## The sprite box

The window is deliberately bare — sprite and speech bubbles, nothing else. Drag
her anywhere; she floats above other windows by default.

Hovering during a scene reveals two controls:

| Control | Effect |
| --- | --- |
| ⏭ skip | End the current queue item now; the next pending item plays. |
| ✕ stop | Flush the queue and return to the default state (`idle`). |

`SpriteBoxWindow.Options` also supports a chat input field and a row of action
buttons under the sprite. The demo turns both off on purpose: it wants every
interaction to go through the control plane, so what you see is what an agent
can do. Your own app enables them with `chatEnabled: true` and the `actions`
array (see [../EMBEDDING.md](../EMBEDDING.md)).

When a question is outstanding, the bubble grows answer affordances — buttons for
a `confirm` or `choice`, a text field for `text`. Those are the *only* way a
question gets answered; see [concepts/QUESTIONS.md](../concepts/QUESTIONS.md) for
why no API can do it.

## The menu bar

The paw icon is the app's permanent UI.

| Item | What it does |
| --- | --- |
| **Show / Hide Winston** | Close and reopen the sprite box. Hiding does not pause the engine — she keeps playing, invisibly. |
| **Queue…** | Open the queue window (below). |
| **Ask me something** | Asks a real question — `"Ready to deploy to production?"`, confirm form, buttons "Ship it" / "Hold off" — after moving her to `waiting`. This is the identical path a REST or MCP caller takes, so you can exercise the human-in-the-loop affordance without wiring up an agent first. |
| **Replay onboarding** | Replays the tour. |
| **View on GitHub** | Opens the repository. |
| **Settings…** (⌘,) | Opens Settings, refreshing all four live panes first. |
| **Quit** (⌘Q) | Stops the server (2-second grace) and exits, deleting `runtime/token` and `runtime/server.json`. |

## The queue window

Every agent command, every script step, every REST call lands on one queue, and
this window is that queue made visible: the running item with its countdown, the
pending items behind it, and skip / clear controls.

It is worth leaving open while the tour plays or while an agent is working — it
is the fastest way to build an intuition for the thing that most surprises
people, which is that a direct `say` or `set-state` jumps to the *front* of the
queue rather than the back. The window ticks five times a second while visible
and not at all while hidden.

Questions appear here too, which is how a human answers a question that is not
the one currently on screen: a second question waits behind the first, and
answering it in the queue window resolves it in place without disturbing the
bubble.

## Settings

The settings window is generated. Nothing in it is hand-built UI — components
register `CapabilityDescriptor`s and `SettingsWindow` renders whatever is
registered, grouped by component. The nine below are all declared in
`main.swift`, which is worth reading as the template for adding your own.

### Sprite Box

| Setting | Default | Effect |
| --- | --- | --- |
| Sprite size | 160 pt (range 96–320, step 16) | Display size. |
| Always on top | on | Float above other windows. |
| Pixelated rendering | off | Nearest-neighbor scaling, for a crisp retro look on low-resolution atlases. |

### Voice

| Setting | Default | Effect |
| --- | --- | --- |
| Speak out loud | **off** | Read speech bubbles aloud. |
| Voice | the sprite's declared voice, else the first system voice | System voices installed on this Mac. |
| Speaking rate | the sprite's declared rate, else 1.0 (range 0.5–2.0) | 1.0 is normal speed. |
| Answer questions out loud | **off** | Speak your answer to a question instead of typing it. |

Turning on *Speak out loud* changes queue timing rather than filtering audio on
the way out: a spoken line then holds the queue for exactly as long as its audio,
instead of a guessed hold. Long lines take longer, and the pet stops looking like
she is talking over herself.

*Answer questions out loud* is off by default and deliberately so — the macOS
permission prompt should only ever be reachable by someone who asked for it. It
also **will not work under `swift run`**: speech recognition needs a packaged app
with usage-description keys, and macOS terminates a process that requests it
without them. Motive refuses rather than dying, so the microphone simply stays
hidden and the Voice diagnostics pane explains why. Build the bundle
(`scripts/build-demo-app.sh`) to use it.

### Control Plane

| Setting | Default | Effect |
| --- | --- | --- |
| REST API | on | The local HTTP API. Off means no port, no token file, no agents. |
| Port | 7877 | Preferred port, clamped to 1024–65535. If taken, an ephemeral port is used and Settings shows the real one. |
| Public (all interfaces) | off | Bind `0.0.0.0` instead of `127.0.0.1`. |

Changing any of these restarts the server, which **rotates the token** — anything
holding the old one must re-read it. Restarts are debounced by 500 ms and
latest-wins, so typing a port number does not thrash.

*Public* is the one setting worth thinking about. Token auth is unchanged and
still required for every request, but the port becomes reachable from your
network and macOS will likely ask to allow incoming connections. Turn it on for
driving a pet from another machine on a network you trust; leave it off
otherwise.

### The four live panes

Below the generated settings sit four custom sections, each an example of
`SettingsSection` with your own SwiftUI inside — the escape hatch for anything
the capability system cannot express.

- **Control Plane Status** — the live address, the token path, current queue
  depth, and **Copy prompt**. That button is the fastest agent hookup there is:
  it produces markdown embedding the live port and token that walks any agent
  chat through ping → schema → a visible wave-and-say. Re-copy after a restart.
- **Agent Skills** — one-click install/remove for Claude Code, Codex, OpenCode,
  and Claude Desktop. The Claude Desktop row needs the `motive-mcp` shim on your
  `PATH` or next to the app; without it the row goes non-actionable rather than
  failing on click.
- **Questions** — how many questions are stored, how many are outstanding, and
  Refresh / Keep last 100 / Clear. Question history and the activity log are one
  store, so clearing here clears both.
- **Voice** — whether speech input is available on this build, why not if not,
  and **Copy fix** for the exact plist snippet that would resolve it.

## The onboarding tour

First launch plays a ~35-step script through nine sections: welcome, what Motive
is, the components, states, triggers, messages and the queue, questions, agents
and the control plane, and a sign-off. It is a plain `ScriptRun` built in
`OnboardingScript.swift` — the same `ScriptStep` vocabulary any agent can send —
so reading it is a decent way to learn the queue model.

Completion is recorded when the tour *starts*, under the `UserDefaults` key
`motive.demo.onboarding-completed`. Driving the sprite mid-tour cancels it, and
that counts as choosing to skip rather than as a reason to replay it every
launch. *Replay onboarding* is always there.

`MotiveDemoTests` validates the script against the real Winston package, so a
tour step naming a state Winston does not have fails CI rather than shipping a
dead scene.

## Running two at once

Give each instance its own runtime home so their tokens and discovery files do
not collide:

```sh
MOTIVE_HOME=$(pwd)/.motive-home swift run motive-demo
```

Port collisions resolve themselves — the second instance falls back to an
ephemeral port, and each home's `server.json` records the truth. See
[../reference/ENVIRONMENT.md](../reference/ENVIRONMENT.md).

## Building the app bundle

```sh
scripts/build-demo-app.sh                 # dist/MotiveDemo.app
scripts/build-demo-app.sh --universal     # arm64 + x86_64 via lipo
scripts/build-demo-app.sh --zip           # also dist/MotiveDemo-<version>.zip
```

The bundle is what you need for speech input, and what you send to other people.
It is ad-hoc signed by default; set `MOTIVE_SIGN_IDENTITY` for a real one. See
[../reference/CLI.md](../reference/CLI.md) for the other scripts.
