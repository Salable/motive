# Design a Companion

> **Audience:** anyone drawing the art for a Motive app — no Swift required.
> **Prerequisites:** a checkout (to run the demo as your preview window) and any image editor that can export PNG with transparency.
> **Source of truth:** `docs/FORMATS.md` for the manifest, `Sources/MotiveSprite/MotiveRunner.swift` for what the validator accepts, `scripts/make-kit-art.py` for the kit art.

A companion is a grid of pictures and a JSON file. That is genuinely all it is —
sprites are data, never code — so the hard parts are not technical: choosing
what your character can *say* without words, and making a four-second loop that
someone can stand having on screen all day.

This is the front-to-back version. [../FORMATS.md](../FORMATS.md) is the
manifest reference, and
[../reference/STATE-PROFILES.md](../reference/STATE-PROFILES.md) is the lookup
table for which states a given host can actually drive.

## Step 1: steal the grid

```sh
cp -R Kit/packs/pip/sprite ~/sprites/mycompanion
MOTIVE_SPRITE=~/sprites/mycompanion swift run motive-demo
```

There is your companion, on the desktop, moving. Everything below is changing
it into yours — which is a much better place to start than an empty canvas and
a spec.

The kit's grid is **8 columns × 9 rows of 128×128 cells**, one state per row.
`Kit/components/sprites/grid-template` is the same grid with the art replaced by
guides: safe area, centre line, ground line, and each cell's state name and
frame number. Open it as a bottom layer in your editor and draw over it.

Choosing your own grid instead? Three constraints and one habit:

- **Every cell is the same size.** The manifest declares one `cell: [w, h]` per
  atlas; frames are cut from a lattice.
- **The sprite is drawn at 96–320 points** (the demo's `sprite-box.scale`
  capability, default 160). 128 or 192 pixels square is the sweet spot: crisp at
  the default size, cheap to draw.
- **Transparent background.** PNG or WebP. The companion floats over whatever is
  behind it; a white background reads as a sticker.
- **Pick a ground line and keep to it.** The single most common wobble in
  homemade sprite sheets is a character whose feet drift a few pixels between
  frames. The template draws the line for you.

## Step 2: choose the vocabulary before you draw

Every state is a row of art you will have to draw, animate, and keep in style
with the others. So decide the list first, from what will actually drive it:

| Building for | Draw |
| --- | --- |
| your own app's job lifecycle | `idle`, `working`, `waiting`, `review`, `failed` |
| Claude Code / Codex CLI sessions | the above, plus `thinking` and `sleeping` |
| Claude Desktop / ChatGPT Desktop | the above, plus a `wave` and a `jump` gesture |

[../reference/STATE-PROFILES.md](../reference/STATE-PROFILES.md) has the
event-by-event mapping for each, and the list of states not to bother with.

Five states, eight frames each, is forty drawings. That is the real budget
question, and the honest answer for a first companion is: draw three, ship it,
and add the rest once you have watched it run.

## Step 3: draw the loop

Each row is a loop. Frame 7 is followed by frame 0, forever, so the last frame
has to lead back into the first — a sine wave, not a ramp.

- **Silhouette first.** At 160 points on a busy desktop, colour and detail
  vanish and shape survives. If two states have the same outline they are the
  same state to the person glancing at them.
- **Squash and stretch beats displacement.** A body that swells and settles
  reads as breathing; a body that slides up and down reads as broken. Pip's
  entire idle loop is a two-pixel change in height.
- **One idea per state.** `working` leans forward and has one orbiting spark.
  Adding a second moving element does not double the information, it halves
  the legibility.
- **Frame 0 has to work alone.** Under macOS *Reduce Motion*, Motive draws
  frame 0 and nothing else — a still companion rather than a slow one. Make
  every row's first frame a pose you would be happy to see all day.
- **Mind the hold time.** `working` may be on screen for ten minutes; `review`
  for five seconds. Spend your frames accordingly.

Export the sheet as one flat PNG with the rows in the order your manifest will
declare.

## Step 4: write the manifest

`motive.json`, beside the sheet:

```jsonc
{
  "format": "motive/1",
  "metadata": {
    "id": "mycompanion", "name": "Bracket",
    "description": "A friendly bracket who watches your builds.",
    "license": "MIT", "version": "1.0.0"
  },
  "atlases": {
    "sprite": { "path": "spritesheet.png", "cell": [128, 128], "grid": [8, 9] }
  },
  "states": {
    "idle":    { "frames": { "row": 0, "count": 8 }, "ms": 130,
                 "purpose": "nothing is running" },
    "working": { "frames": { "row": 2, "count": 8 }, "ms":  80,
                 "purpose": "a task is in flight" },
    "waving":  { "frames": { "row": 6, "count": 8 }, "ms":  90,
                 "interrupt": "after-loop", "purpose": "greeting" }
  },
  "aliases":  { "running": "working", "done": "review", "error": "failed" },
  "triggers": { "wave": { "state": "waving", "once": true,
                          "purpose": "say hello without changing mood" } },
  "transitions": [{ "from": "*", "to": "*", "ms": 180 }]
}
```

Four fields decide how it *feels*, and they are worth more thought than the
geometry:

| Field | Get it wrong and… |
| --- | --- |
| `ms` | too fast reads as anxious, too slow as frozen. 60–90ms for effort, 120–200ms for rest. |
| `interrupt` | a gesture cut in half looks like a bug. Gestures get `after-loop`; `failed` stays `immediate`, because a mood that arrives late is a lie. |
| `purpose` | an agent picks the wrong state. This string is surfaced verbatim in `GET /v1/schema` — it is the only description of your art the model will ever read. |
| `transitions` | 180ms of crossfade hides the seam between two unrelated loops. Drop it to 0 for a deliberate hard cut. |

Write `purpose` for a reader who cannot see the picture: *"blocked on the human
— use this whenever you have asked a question"*, not *"expectant puppy eyes"*.

## Step 5: run it, and read the complaints

```sh
MOTIVE_SPRITE=~/sprites/mycompanion swift run motive-demo
```

Loading is tolerant of keys it does not recognise and loud about values it does.
The messages name the fix:

| Message | Cause |
| --- | --- |
| `motive.json must declare "format": "motive/1"` | missing or misspelled `format` |
| `atlas 'sprite' image not found: spritesheet.png` | the `path` is relative to the package directory, and must stay inside it |
| `state 'working' row 9 is outside atlas 'sprite' (0..<9)` | rows are zero-indexed; a `grid` of `[8, 9]` has rows 0–8 |
| `state 'working' frames 4..<14 exceed atlas columns (8)` | `from` + `count` ran off the right edge |
| `state 'idle' ms array does not match 8 frames` | a per-frame `ms` array must be exactly as long as the row |
| `alias 'done' points to unknown state 'review'` | you declared the alias but deleted the row |

Then drive it through the whole vocabulary and watch, rather than reading the
JSON again:

```sh
PORT=$(python3 -c "import json;print(json.load(open('$HOME/.motive/runtime/server.json'))['port'])")
TOKEN=$(cat ~/.motive/runtime/token)
for state in idle thinking working waiting review failed; do
  curl -s -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d "{\"state\": \"$state\"}" "http://127.0.0.1:$PORT/v1/state" >/dev/null
  sleep 3
done
```

`scripts/demo-curl.sh` does the same for the rest of the verbs.

## Step 6: the checks people skip

- **Over a dark window and a light one.** A companion outlined in black
  disappears against a terminal. Outline in a colour, or carry a rim of the
  body's own tone.
- **At the smallest size.** Settings → Sprite size → 96. If the eyes vanish,
  the eyes are too small.
- **With *Reduce Motion* on.** System Settings → Accessibility → Display. Every
  state becomes its frame 0.
- **With pixelated rendering on and off.** Settings → *Pixelated rendering*
  switches to nearest-neighbour. Pixel art needs it; smooth art hates it.
- **Left alone for an hour.** The one test nobody runs, and the one that decides
  whether anybody keeps the app installed.

## Step 7: ship it

A sprite package is a directory: copy it into your app's resources and load it
with `SpriteRunnerRegistry.standard.load(url)`
([FIRST-APP.md](FIRST-APP.md#step-2-a-sprite)). Nothing in it executes, so a
package is safe to share and safe to accept — put a `license` in `metadata` and
people will.

| Next | Page |
| --- | --- |
| the full manifest vocabulary — multi-atlas, pixel rects, per-frame timing | [../FORMATS.md](../FORMATS.md) |
| which states a given agent host can drive | [../reference/STATE-PROFILES.md](../reference/STATE-PROFILES.md) |
| why `after-loop` behaves like that | [../concepts/STATES.md](../concepts/STATES.md) |
| making the companion speak the lines | [../concepts/VOICE.md](../concepts/VOICE.md) |
| building the app around it | [FIRST-APP.md](FIRST-APP.md) |
