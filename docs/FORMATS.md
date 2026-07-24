# Sprite Package Formats

A sprite package is a directory containing a manifest plus one or more atlas images.
Format detection is by manifest file: `motive.json` → `motive/1` (MotiveRunner), otherwise
`pet.json` → `codex/1` (CodexRunner). Consumers can register additional runners.

## codex/1 (`pet.json`)

Compatible with the Codex/Fido pet contract. A single sprite-sheet atlas divided into a
fixed grid; each animation state occupies one row.

```jsonc
{
  "id": "salli",
  "displayName": "Salli",
  "atlases": {
    "sprite": { "path": "spritesheet.png", "cell": [192, 208], "grid": [25, 9] }
  },
  "states": {
    "idle":    { "atlas": "sprite", "row": 0, "frames": 25, "ms": [100, ...], "loop": true },
    "running": { "atlas": "sprite", "row": 7, "frames": 12, "from": 13, "ms": [70, ...], "loop": true }
  }
}
```

- `cell` — frame size in pixels `[w, h]`; `grid` — `[columns, rows]`.
- Per state: `row` (authoritative — layouts differ per sprite), `frames` (count),
  optional `from` (starting column), `ms` (per-frame durations), `loop`.

## motive/1 (`motive.json`)

The Motive-native format. Specified in milestone M5 — improvements over codex/1:
explicit frame cell-lists or pixel rects (non-row layouts), multiple atlases per state,
duration shorthand, first-class `interrupt`/`then`/`transitions`/`triggers`/`aliases`,
a metadata block (name/author/license/version), and anchor/scale hints.
