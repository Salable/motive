# Quickstart

> **Audience:** first-time users. You want a pet on your desktop and a command that moves her.
> **Prerequisites:** macOS 13+. From a checkout, Swift 5.10+ (Xcode 15.3+).
> **Source of truth:** `Sources/MotiveDemo/main.swift`, `scripts/demo-curl.sh`.

Five minutes, three steps: get Winston on screen, find the door into her, drive
her from a terminal. Everything after that is variations on step three.

## 1. Run her

From a checkout:

```sh
git clone https://github.com/Salable/motive.git
cd motive
swift run motive-demo
```

The first build takes a couple of minutes; after that it is seconds. Or download
`MotiveDemo-<version>.zip` from [Releases](https://github.com/Salable/motive/releases)
and unzip it — the app is not notarized yet, so the first launch needs
**right-click → Open** rather than a double-click.

Winston — a shaggy black labradoodle pup — appears on your desktop and walks
through a tour of what Motive does. There is no window chrome and no Dock icon;
she is just a sprite and her speech bubbles. Look for the **paw in your menu
bar**, which is the app's only permanent UI.

Hover over her mid-scene for skip (⏭) and stop (✕) controls. Stopping returns her
to idle. The tour only plays on first launch; *Replay onboarding* in the paw menu
brings it back.

## 2. Find the door

When the demo starts it prints its address and a ready-to-paste command:

```
motive-demo 0.4.0: Winston is on your desktop (menu-bar paw to quit).
Control plane: http://127.0.0.1:7877  (token: /Users/you/.motive/runtime/token)
```

Two files under `~/.motive/runtime/` are the whole handshake. `server.json`
records the port actually bound — 7877 is only *preferred*, and a collision falls
back to an ephemeral port — and `token` holds a bearer token regenerated on every
start. Both are owner-only, and both are deleted when the app quits.

```sh
PORT=$(python3 -c "import json;print(json.load(open('$HOME/.motive/runtime/server.json'))['port'])")
TOKEN=$(cat ~/.motive/runtime/token)
```

If you started the app before, re-read the token: it rotated.

## 3. Drive her

```sh
curl -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
     -d '{"state": "running"}' "http://127.0.0.1:$PORT/v1/state"
```

She starts tearing through paperwork, and stays there — a state set with no
duration persists until something changes it. Three more to try:

```sh
# A gesture: plays once, then returns to whatever she was doing.
curl -H "Authorization: Bearer $TOKEN" -d '{"name": "jump"}' \
     "http://127.0.0.1:$PORT/v1/trigger"

# A speech bubble, gone after 5 seconds.
curl -H "Authorization: Bearer $TOKEN" -d '{"text": "Build is green", "ttl": 5000}' \
     "http://127.0.0.1:$PORT/v1/say"

# Back to idle, with a 3-second detour through "review" first.
curl -H "Authorization: Bearer $TOKEN" -d '{"state": "review", "duration": 3000}' \
     "http://127.0.0.1:$PORT/v1/state"
```

Winston's vocabulary is `idle`, `running`, `waiting`, `review`, `failed`,
`waving`, `jumping`, `running-left`, `running-right`, with `working`, `done`, and
`error` as aliases; her gestures are `wave`, `jump`, `dash-left`, `dash-right`.
You do not have to memorise that — ask her:

```sh
curl -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/v1/schema"
```

`/v1/schema` describes the loaded sprite, whichever sprite that is, with prose
explaining what each state is *for*. It is what agents read on connect, and
getting a state name wrong returns the valid list rather than a bare 400.

`./scripts/demo-curl.sh` walks the whole surface in one go if you would rather
watch than type.

## What just happened

Every one of those calls became an item on a queue, and the queue is the honest
account of why the pet is doing what she is doing. Direct verbs like the ones
above play *next* — they cut the current scene's remaining hold but do not
discard what was lined up behind it. Open the queue window from the paw menu and
run them again to watch it happen. [concepts/QUEUE.md](../concepts/QUEUE.md) is
the full model.

## Where to go next

- **Explore the app** — [DEMO.md](DEMO.md): every menu item, every setting, and
  what each one actually changes.
- **Let an agent drive** — [../INTEGRATIONS.md](../INTEGRATIONS.md). Fastest
  path: Settings → Control Plane Status → *Copy prompt*, paste into any agent
  chat.
- **Build your own pet** — [FIRST-PET.md](FIRST-PET.md).
- **The full wire protocol** — [../API.md](../API.md).
- **Something went wrong** — [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
