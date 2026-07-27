# Sprite Package Formats

> **Audience:** sprite authors, and anyone adding a format runner.
> **Prerequisites:** none. Test a package with `MOTIVE_SPRITE=path swift run motive-demo`.
> **Source of truth:** `Sources/MotiveSprite/` — `MotiveRunner.swift`, `SpriteDefinition.swift`.

A sprite package is a directory containing a manifest plus one or more atlas images.
`motive/1` (`motive.json`, loaded by `MotiveRunner`) is the only built-in format.
Consumers can register additional runners with `SpriteRunnerRegistry.register`.

Drawing one rather than looking one up? This is the reference;
[guides/SPRITE-DESIGN.md](guides/SPRITE-DESIGN.md) is the walkthrough, and it
starts by copying a package out of [../Kit/](../Kit/).

The format's posture: **tolerant decode, loud validation** — unknown keys pass
(forward compatibility); invalid values fail with messages naming the valid
vocabulary. Every package load goes through the validator. Atlas paths must be relative
and stay inside the package. Sprites are data, never code.

## motive/1 (`motive.json`)

Everything is explicit — no default contract, no synthesized vocabulary. Frame
layouts need not be rows, a state may draw from multiple atlases, durations have a
shorthand, and metadata is a first-class block.

```jsonc
{
  "format": "motive/1",                            // required, exactly "motive/1"
  "metadata": {                                    // all fields optional
    "id": "winston", "name": "Winston", "description": "…",
    "author": "…", "license": "MIT", "version": "1.0.0",
    "voice": { "voice": "Daniel", "rate": 1.0, "talkingState": "idle" }
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

## The voice block

`metadata.voice` is an optional block decoding to a `VoicePreferences`:

| Field | Meaning |
| --- | --- |
| `voice` | Voice identifier or display name, as the host platform knows it (`"Daniel"`, `"Samantha"`). Omitted or unknown falls back to the system default. |
| `rate` | Speed multiplier; `1.0` is normal. |
| `talkingState` | The state to hold while an utterance plays, so the mouth moves for exactly the audio and not a guessed duration. |

This is a *declaration, not a setting*. Loading a package with a voice block does
not make the companion speak — nothing speaks until the host app installs a
`SpeechOutput` (see [concepts/VOICE.md](concepts/VOICE.md)). What the block gives
the host is a sensible starting point: the demo uses `metadata.voice.voiceID` as
the default value of its `voice.output.voice` capability, so the sprite author's
intent is what a user hears first, and a user's own choice wins from then on.

Unknown voice names do not fail validation. A package authored on a machine with
a voice you have not downloaded should still load and animate; the worst outcome
is the system default reading the lines.

## Migrating from codex/1 (`pet.json`)

Motive used to ship a second built-in runner for `codex/1`, the Codex/Fido
`pet.json` contract. It is gone — `motive/1` does everything it did, and carrying
two formats meant two vocabularies for one idea. Rewrite a `pet.json` as a
`motive.json` field by field:

| codex/1 | motive/1 |
| --- | --- |
| *(no format field)* | `"format": "motive/1"` — required |
| `id`, `displayName`, `description` at top level | the same, under `metadata` (`displayName` → `name`) |
| `voice` at top level | `metadata.voice` |
| `spritesheetPath` | an entry in `atlases` with an explicit `cell` and `grid` |
| state `atlas` | unchanged (still defaults to `"sprite"`) |
| state `row` / `frames` / `from` | `frames: { row, count, from }` |
| `ms: [100, 100, …]` | `ms: 100` when uniform, or keep the array |
| `loop`, `then`, `interrupt` | unchanged |
| `aliases`, `triggers`, `transitions` | unchanged |

Two behaviors have no equivalent, by design. The bare four-field manifest that
resolved to the classic 8×9 @ 192×208 grid must now name its atlas explicitly, and
the synthesized defaults (aliases `working→running`, `done→review`, `error→failed`;
`wave`/`jump` triggers; `after-loop` on `waving`/`jumping`) must be declared. Both
were guesses about what a package meant; `motive/1` asks it to say so.

If you have packages you cannot re-author, `SpriteRunner` and
`SpriteRunnerRegistry.register` are still public — a `codex/1` runner can live in
your own app and be registered at startup. Motive simply no longer ships one.
