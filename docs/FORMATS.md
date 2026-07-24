# Sprite Package Formats

A sprite package is a directory containing a manifest plus one or more atlas images.
Format detection is by manifest file: `motive.json` → `motive/1` (MotiveRunner) wins,
otherwise `pet.json` → `codex/1` (CodexRunner). Consumers can register additional
runners with `SpriteRunnerRegistry.register`.

Both formats follow the same posture: **tolerant decode, loud validation** — unknown
keys pass (forward compatibility); invalid values fail with messages naming the valid
vocabulary. Every package load goes through the validator. Atlas paths must be relative
and stay inside the package. Sprites are data, never code.

## codex/1 (`pet.json`)

Compatible with the Codex/Fido pet contract. Fixed-grid sprite-sheet atlases; each
animation state occupies (part of) one row.

```jsonc
{
  "id": "winston",
  "displayName": "Winston",
  "description": "…",
  "atlases": {
    "sprite": { "path": "spritesheet.png", "cell": [192, 208], "grid": [25, 9] }
  },
  "states": {
    "idle":    { "atlas": "sprite", "row": 0, "frames": 25, "ms": [100, "…"], "loop": true },
    "running": { "atlas": "sprite", "row": 7, "frames": 12, "from": 13, "ms": [70, "…"] }
  },
  "aliases":     { "working": "running" },          // optional
  "triggers":    { "wave": { "state": "waving", "once": true } },  // optional
  "transitions": [{ "from": "*", "to": "*", "ms": 180 }]           // optional
}
```

- `cell` `[w, h]` and `grid` `[columns, rows]` define the atlas; per state, `row` is
  authoritative (layouts differ per sprite), `frames` counts columns, `from` offsets the
  starting column, `ms` gives per-frame durations, `loop` defaults true.
- A bare four-field manifest (`id`/`displayName`/`description`/`spritesheetPath`)
  resolves to the classic 8×9 @ 192×208 Codex contract with its default row order.
- Synthesized defaults: aliases `working→running`, `done→review`, `error→failed`
  (when the targets exist); triggers `wave`/`jump` when `waving`/`jumping` rows exist
  and no triggers are declared; `waving`/`jumping` enter `after-loop`.

## motive/1 (`motive.json`)

The Motive-native format. Everything is explicit — no default contract, no synthesized
vocabulary. Improvements over codex/1: frame layouts that aren't rows, multiple atlases
per state, duration shorthand, and a full metadata block.

```jsonc
{
  "format": "motive/1",                            // required, exactly "motive/1"
  "metadata": {                                    // all fields optional
    "id": "winston", "name": "Winston", "description": "…",
    "author": "…", "license": "MIT", "version": "1.0.0"
  },
  "atlases": {                                     // at least one required
    "sprite":  { "path": "spritesheet.png", "cell": [192, 208], "grid": [25, 9] },
    "closeup": { "path": "closeup.png", "cell": [512, 512], "grid": [4, 2] }
  },
  "states": {
    // Frame layout: exactly ONE of row / cells / rects.
    "idle":  { "frames": { "row": 0, "count": 25, "from": 0 }, "ms": 100 },
    "blink": { "frames": { "cells": [[0, 0], [3, 2], [1, 1]] }, "ms": [80, 120, 80] },
    "hero":  { "frames": { "rects": [
                 { "x": 0, "y": 0, "w": 192, "h": 208 },
                 { "x": 0, "y": 0, "w": 512, "h": 512, "atlas": "closeup" }
               ] }, "ms": 200 },
    "intro": { "frames": { "row": 1, "count": 4 }, "loop": false, "then": "idle",
               "interrupt": "never", "purpose": "played once at launch" }
  },
  "aliases":     { "working": "running" },
  "triggers":    { "wave": { "state": "waving", "once": true, "purpose": "…" } },
  "transitions": [{ "from": "*", "to": "*", "ms": 180 }]
}
```

Per state:

| Field | Meaning |
| --- | --- |
| `atlas` | Default atlas key for the state (default `"sprite"`); `rects` entries may override per frame. |
| `frames.row` | Row layout: `count` frames starting at column `from` (default 0). `count` may be omitted when `ms` is a per-frame array. |
| `frames.cells` | Explicit `[column, row]` cell list — non-contiguous and reordered frames. |
| `frames.rects` | Explicit pixel rectangles `{x, y, w, h, atlas?}` — arbitrary layouts, mixed atlases. |
| `ms` | Scalar (uniform per frame) or per-frame array (length must match). Default 150. |
| `loop` | Default `true`. Non-looping states hold their last frame. |
| `then` | State entered when a non-looping state finishes. Must exist. |
| `interrupt` | How this state *enters*: `immediate` (default), `after-loop`, `never`. |
| `purpose` | Prose for agents/settings UIs (surfaced in the control-plane schema). |

Triggers are one-shot gestures: `once: true` (default) returns to the prior state after
one loop. Transitions declare crossfade durations; specificity order is exact
`from`/`to`, then `from:*`, then `*:to`, then `*:*`.
