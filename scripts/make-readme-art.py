#!/usr/bin/env python3
"""Generate the README's Winston GIFs from the sprite atlas.

Deterministic: reads rows, timings, and aliases from motive.json (so the art
regenerates correctly if the sprite changes), computes crops from the frames'
alpha bounds, and emits looping GIFs onto warm-paper cards matching the app
icon. Committed under docs/images/; rerun manually after atlas changes.

  python3 scripts/make-readme-art.py
"""
import json
import pathlib
import sys

from PIL import Image, ImageDraw, ImageFont

ROOT = pathlib.Path(__file__).resolve().parent.parent
SHEET = ROOT / "Sprites/winston/spritesheet.webp"
MANIFEST = ROOT / "Sprites/winston/motive.json"
OUT_DIR = ROOT / "docs/images"

BACKGROUND = (245, 236, 224, 255)  # warm paper, same as the app icon
INK = (60, 50, 40, 255)
BUBBLE_FILL = (255, 255, 255, 255)
FONT_CANDIDATES = [
    "/System/Library/Fonts/Supplemental/Arial Rounded Bold.ttf",
    "/System/Library/Fonts/MarkerFelt.ttc",
    "/System/Library/Fonts/Supplemental/Comic Sans MS.ttf",
]

HERO_STATE = "waving"
HERO_TEXT = "Woof! I'm Winston."
HERO_SCALE = 2
# The agent vocabulary — what a first-time viewer needs to recognize.
CARD_STATES = ["working", "waiting", "review", "failed"]
TOTAL_BUDGET_KIB = 2048


def load_manifest():
    """Read motive/1 and flatten each state to the row/frames/ms this script draws with.

    motive/1 nests the row under `frames` and allows a scalar `ms` standing for
    every frame; the drawing code below wants a row, a frame count, and one
    duration per frame.
    """
    manifest = json.loads(MANIFEST.read_text())
    cell = tuple(manifest["atlases"]["sprite"]["cell"])
    aliases = manifest.get("aliases", {})

    def resolve(name):
        state = manifest["states"][aliases.get(name, name)]
        frames = state["frames"]
        ms = state["ms"]
        count = frames.get("count", len(ms) if isinstance(ms, list) else None)
        if count is None:
            raise SystemExit(f"state '{name}': cannot infer frame count")
        return {
            "row": frames["row"],
            "frames": count,
            "ms": ms if isinstance(ms, list) else [ms] * count,
        }

    return manifest, cell, resolve


def load_font(size):
    for path in FONT_CANDIDATES:
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    print("warning: no candidate font found; using PIL default", file=sys.stderr)
    return ImageFont.load_default()


def union_bbox(sheet, cell, rows, frames):
    """Union of the frames' alpha bounds across the given rows (cell coords)."""
    cw, ch = cell
    left = top = 10_000
    right = bottom = 0
    for row in rows:
        for col in range(frames):
            box = sheet.crop((col * cw, row * ch, (col + 1) * cw, (row + 1) * ch))
            bounds = box.getchannel("A").getbbox()
            if bounds is None:
                continue
            left, top = min(left, bounds[0]), min(top, bounds[1])
            right, bottom = max(right, bounds[2]), max(bottom, bounds[3])
    margin = 8
    return (max(0, left - margin), max(0, top - margin),
            min(cw, right + margin), min(ch, bottom + margin))


def frames_for(sheet, cell, row, crop, count, scale=1):
    cw, ch = cell
    out = []
    for col in range(count):
        frame = sheet.crop((col * cw + crop[0], row * ch + crop[1],
                            col * cw + crop[2], row * ch + crop[3]))
        if scale != 1:
            frame = frame.resize((frame.width * scale, frame.height * scale), Image.NEAREST)
        out.append(frame)
    return out


def card(width, height, radius):
    canvas = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    ImageDraw.Draw(canvas).rounded_rectangle(
        (0, 0, width - 1, height - 1), radius=radius, fill=BACKGROUND)
    return canvas


def encode_gif(frames, ms_list, path):
    """One global palette (no inter-frame flicker), binary transparency for
    the rounded corners (index 255), no dither — flat pixel-art palettes band
    without it and it costs ~50% file size."""
    cols = min(len(frames), 6)
    contact = Image.new("RGBA", (frames[0].width * cols, frames[0].height), (0, 0, 0, 0))
    for i in range(cols):
        contact.alpha_composite(frames[i * len(frames) // cols], (i * frames[0].width, 0))
    master = contact.convert("RGB").quantize(colors=255, method=Image.MEDIANCUT)

    paletted = []
    for frame in frames:
        p = frame.convert("RGB").quantize(colors=255, palette=master, dither=Image.NONE)
        mask = frame.getchannel("A").point(lambda a: 255 if a < 128 else 0)
        p.paste(255, mask=mask)
        paletted.append(p)

    paletted[0].save(
        path, save_all=True, append_images=paletted[1:],
        duration=ms_list, loop=0, optimize=True, transparency=255)
    return path.stat().st_size


def hero(sheet, cell, resolve, font):
    state = resolve(HERO_STATE)
    crop = union_bbox(sheet, cell, [state["row"]], state["frames"])
    sprites = frames_for(sheet, cell, state["row"], crop, state["frames"], scale=HERO_SCALE)
    sw, sh = sprites[0].size

    pad = 24
    bubble_pad = (18, 12)
    text_box = ImageDraw.Draw(Image.new("RGBA", (8, 8))).textbbox((0, 0), HERO_TEXT, font=font)
    bw = text_box[2] - text_box[0] + 2 * bubble_pad[0]
    bh = text_box[3] - text_box[1] + 2 * bubble_pad[1]
    tail = 18

    width = max(sw, bw) + 2 * pad
    height = pad + bh + tail + 8 + sh + pad
    base = card(width, height, radius=40)

    bx, by = (width - bw) // 2, pad
    draw = ImageDraw.Draw(base)
    draw.rounded_rectangle((bx, by, bx + bw, by + bh), radius=bh // 2,
                           fill=BUBBLE_FILL, outline=INK, width=3)
    cx = width // 2
    draw.polygon([(cx - 12, by + bh - 2), (cx + 12, by + bh - 2), (cx, by + bh + tail)],
                 fill=BUBBLE_FILL, outline=INK)
    draw.text((bx + bubble_pad[0] - text_box[0], by + bubble_pad[1] - text_box[1]),
              HERO_TEXT, font=font, fill=INK)

    out = []
    for sprite in sprites:
        frame = base.copy()
        frame.alpha_composite(sprite, ((width - sw) // 2, height - pad - sh))
        out.append(frame)
    return out, state["ms"]


def state_card(sheet, cell, resolve, font, name, crop):
    state = resolve(name)
    sprites = frames_for(sheet, cell, state["row"], crop, state["frames"])
    sw, sh = sprites[0].size

    pad = 12
    caption_h = 34
    width, height = sw + 2 * pad, sh + pad + caption_h
    base = card(width, height, radius=24)

    draw = ImageDraw.Draw(base)
    text_box = draw.textbbox((0, 0), name, font=font)
    draw.text(((width - (text_box[2] - text_box[0])) // 2 - text_box[0],
               height - caption_h + (caption_h - (text_box[3] - text_box[1])) // 2 - text_box[1]),
              name, font=font, fill=INK)

    out = []
    for sprite in sprites:
        frame = base.copy()
        frame.alpha_composite(sprite, (pad, pad))
        out.append(frame)
    return out, state["ms"]


def main():
    _manifest, cell, resolve = load_manifest()
    sheet = Image.open(SHEET).convert("RGBA")
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    total = 0
    hero_font = load_font(28)
    frames, ms = hero(sheet, cell, resolve, hero_font)
    total += encode_gif(frames, ms, OUT_DIR / "winston-hello.gif")
    print(f"{OUT_DIR / 'winston-hello.gif'}  {frames[0].width}x{frames[0].height}")

    # One shared crop so all four dogs stand on the same baseline.
    card_rows = [resolve(name)["row"] for name in CARD_STATES]
    card_frames = min(resolve(name)["frames"] for name in CARD_STATES)
    shared_crop = union_bbox(sheet, cell, card_rows, card_frames)

    caption_font = load_font(22)
    for name in CARD_STATES:
        frames, ms = state_card(sheet, cell, resolve, caption_font, name, shared_crop)
        path = OUT_DIR / f"state-{name}.gif"
        total += encode_gif(frames, ms, path)
        print(f"{path}  {frames[0].width}x{frames[0].height}")

    print(f"total: {total // 1024} KiB")
    if total > TOTAL_BUDGET_KIB * 1024:
        print(f"error: assets exceed {TOTAL_BUDGET_KIB} KiB budget", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
