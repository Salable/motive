# Starter Sprite Kit

> **Audience:** anyone drawing a companion for their own app.
> **Prerequisites:** none. Run one with `MOTIVE_SPRITE=Sprites/starter/pip swift run motive-demo`.
> **Source of truth:** `scripts/make-starter-sprites.py` generates both packages; `docs/FORMATS.md` is the manifest spec.

Two sprite packages you are meant to take apart. Both are MIT-licensed, both
share one grid, and both declare the same vocabulary — the nine states in
[docs/reference/STATE-PROFILES.md](../../docs/reference/STATE-PROFILES.md) —
so you can swap art without touching the manifest.

| Package | What it is | Use it to |
| --- | --- | --- |
| `pip/` | A complete, animated companion. Plain shapes, flat colors, no shading. | Have something moving on your desktop in one command, then repaint it cell for cell. |
| `template/` | The same grid drawn as guides: safe area, centre line, ground line, and each cell's `state` + frame number. | Draw your own art in any editor with the frame boundaries already correct. |

Both atlases are 1024×1152 PNGs: **8 columns × 9 rows of 128×128 cells**, one
state per row, in the order the manifests declare. The character stands on a
ground line at y=114 in every cell, which is why it does not jitter as the row
loops — keep your own art on that line.

## Use one as-is

```sh
MOTIVE_SPRITE=$(pwd)/Sprites/starter/pip swift run motive-demo
MOTIVE_SPRITE=$(pwd)/Sprites/starter/template swift run motive-demo
```

The template package animates too. That is the point: loading it shows you
which row is playing and which frame you are on, so a manifest that names the
wrong row is obvious in a second instead of a debugging session.

## Make it yours

```sh
cp -R Sprites/starter/pip ~/sprites/mycompanion
```

Then, in `motive.json`, change `metadata.id`, `metadata.name`, and
`metadata.description`, and repaint `spritesheet.png`. Keep the grid and every
state name and you are done; change either and read
[docs/FORMATS.md](../../docs/FORMATS.md) first.

You do not owe anyone nine states. Delete the rows you will not draw and delete
their entries from `states` — a manifest that names a row it does not have
fails to load, loudly, naming what is wrong. The five that earn their keep in
almost every app are `idle`, `working`, `waiting`, `review`, and `failed`;
[docs/guides/SPRITE-DESIGN.md](../../docs/guides/SPRITE-DESIGN.md) is the
walkthrough and [docs/reference/STATE-PROFILES.md](../../docs/reference/STATE-PROFILES.md)
is the per-host lookup.

## Regenerating

Neither package is hand-drawn:

```sh
python3 scripts/make-starter-sprites.py     # needs Pillow
```

Editing the PNGs directly is fine for your own copy, but edits inside this
directory are overwritten the next time the script runs. Change the script.
