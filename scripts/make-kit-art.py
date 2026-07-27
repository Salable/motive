#!/usr/bin/env python3
"""Generate the art in Kit/ — the packs' sprite sheets and the tracing grid.

Deterministic: every pixel comes from the tables below, so the kit is
regenerated after a vocabulary or palette change rather than retouched by hand.
Three packages, one grid, one vocabulary:

  Kit/packs/pip/sprite/                   a round companion for the general
                                          product lifecycle
  Kit/packs/caret/sprite/                 a terminal caret for CLI agent
                                          sessions — same states, other silhouette
  Kit/components/sprites/grid-template/   the same grid drawn as guides and
                                          labels: tracing paper for your own art

  python3 scripts/make-kit-art.py

Needs Pillow. Run it only when the vocabulary or a palette below changes;
nothing runs it automatically, and edits made straight to the committed PNGs are
overwritten by the next run. See docs/guides/SPRITE-DESIGN.md.

The two characters share every state drawing and differ only in their `Figure`
— that is the point. A pack is a silhouette and a personality over one
vocabulary, so the vocabulary lives in one place.
"""
import json
import math
import pathlib
import sys

from PIL import Image, ImageDraw, ImageFont

ROOT = pathlib.Path(__file__).resolve().parent.parent
KIT = ROOT / "Kit"

CELL = 128           # one frame, in pixels
COLUMNS = 8          # frames per state
SS = 4               # supersample factor; frames are drawn at CELL * SS
GROUND = 114         # the y the character stands on, in every cell

# Flat, high-contrast, and legible at 128px against both a light and a dark
# desktop — the two constraints that actually matter for a companion.
INK = (38, 34, 56, 255)
EYE_WHITE = (255, 255, 255, 255)
AMBER = (247, 181, 56, 255)
GREEN = (74, 187, 122, 255)
RED = (226, 96, 96, 255)
GUIDE = (140, 150, 175, 90)
GUIDE_STRONG = (140, 150, 175, 170)
LABEL = (90, 98, 122, 255)

PIP_BODY = (108, 124, 240, 255)
PIP_SHADE = (86, 100, 214, 255)
CARET_BODY = (86, 196, 140, 255)
CARET_SHADE = (58, 158, 110, 255)

FONT_CANDIDATES = [
    "/System/Library/Fonts/Supplemental/Arial Rounded Bold.ttf",
    "/System/Library/Fonts/SFNSRounded.ttf",
    "/System/Library/Fonts/Supplemental/Arial.ttf",
]

# Row order is the atlas contract: change it and every manifest below moves.
# `ms` is the per-frame duration the manifests declare for that row.
STATES = [
    ("idle",     0, 130, "resting loop: a slow breath and an occasional blink"),
    ("thinking", 1, 120, "considering something; nothing has happened yet"),
    ("working",  2,  80, "actively working — the long-running state"),
    ("waiting",  3, 140, "blocked on the human: a question is on screen"),
    ("review",   4,  90, "finished successfully; the work is ready to look at"),
    ("failed",   5, 110, "something went wrong and stayed wrong"),
    ("waving",   6,  90, "friendly greeting wave"),
    ("jumping",  7,  70, "excited bounce"),
    ("sleeping", 8, 200, "idle for a long time; nothing is running"),
]


def load_font(size):
    for path in FONT_CANDIDATES:
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    print("warning: no candidate font found; labels will use the PIL default",
          file=sys.stderr)
    return ImageFont.load_default()


# ------------------------------------------------------------------- bodies

def blob_body(d, x, feet, w, h, fill, shade):
    """Pip: a rounded mass, squashed and stretched by the caller."""
    d.rounded_rectangle((x - w / 2, feet - h, x + w / 2, feet),
                        radius=min(w, h) * 0.44, fill=fill, outline=INK,
                        width=3 * SS)
    # A darker sliver along the base so the shape has a bottom, not an edge.
    d.rounded_rectangle((x - w / 2 + 5 * SS, feet - 8 * SS,
                         x + w / 2 - 5 * SS, feet - 3 * SS),
                        radius=3 * SS, fill=shade)


def caret_body(d, x, feet, w, h, fill, shade):
    """Caret: the text cursor — a tall block standing on an underscore."""
    d.rounded_rectangle((x - w / 2, feet - h, x + w / 2, feet - 9 * SS),
                        radius=7 * SS, fill=fill, outline=INK, width=3 * SS)
    d.rounded_rectangle((x - w / 2 - 7 * SS, feet - 10 * SS,
                         x + w / 2 + 7 * SS, feet - 1 * SS),
                        radius=4 * SS, fill=shade, outline=INK, width=3 * SS)


class Figure:
    """Everything a state drawing needs to know about one character.

    Both characters run the same nine drawings; only these numbers differ, so a
    new pack is a silhouette and a palette rather than a second animation set.
    """

    def __init__(self, body, width, height, eye_spread, eye_line, mouth_drop,
                 arm_dx, accessory_dx, fill, shade):
        self.body = body
        self.width = width * SS
        self.height = height * SS
        self.eye_spread = eye_spread * SS
        self.eye_line = eye_line          # fraction of the body height, from the feet
        self.mouth_drop = mouth_drop * SS
        self.arm_dx = arm_dx * SS
        self.accessory_dx = accessory_dx * SS
        self.fill = fill
        self.shade = shade

    def draw(self, d, cx, feet, w, h, lean=0.0):
        self.body(d, cx + lean, feet, w, h, self.fill, self.shade)


FIGURES = {
    "pip": Figure(blob_body, 66, 64, 15, 0.62, 20, 28, 34, PIP_BODY, PIP_SHADE),
    "caret": Figure(caret_body, 48, 80, 11, 0.66, 17, 22, 32, CARET_BODY, CARET_SHADE),
}


# --------------------------------------------------------------------- face

def eyes(d, cx, cy, spread, style="open", look=(0.0, 0.0)):
    r = 9 * SS
    for side in (-1, 1):
        ex = cx + side * spread
        if style == "closed":
            d.arc((ex - r, cy - r, ex + r, cy + r), 200, 340, fill=INK, width=3 * SS)
            continue
        if style == "happy":
            d.arc((ex - r, cy - r * 0.6, ex + r, cy + r * 1.4), 200, 340,
                  fill=INK, width=3 * SS)
            continue
        if style == "sad":
            d.arc((ex - r, cy - r * 0.4, ex + r, cy + r * 1.6), 20, 160,
                  fill=INK, width=3 * SS)
            continue
        wide = r * (1.25 if style == "wide" else 1.0)
        d.ellipse((ex - wide, cy - wide, ex + wide, cy + wide),
                  fill=EYE_WHITE, outline=INK, width=2 * SS)
        p = wide * 0.45
        px, py = ex + look[0] * wide * 0.4, cy + look[1] * wide * 0.4
        d.ellipse((px - p, py - p, px + p, py + p), fill=INK)


def mouth(d, cx, cy, w, shape="flat"):
    if shape == "smile":
        d.arc((cx - w, cy - w * 0.8, cx + w, cy + w * 0.8), 20, 160,
              fill=INK, width=3 * SS)
    elif shape == "frown":
        d.arc((cx - w, cy - w * 0.4, cx + w, cy + w * 1.2), 200, 340,
              fill=INK, width=3 * SS)
    elif shape == "o":
        d.ellipse((cx - w * 0.4, cy - w * 0.5, cx + w * 0.4, cy + w * 0.5),
                  fill=INK)
    else:
        d.line((cx - w * 0.5, cy, cx + w * 0.5, cy), fill=INK, width=3 * SS)


def arm(d, cx, cy, angle_deg, length, figure, thickness=7):
    a = math.radians(angle_deg)
    ex, ey = cx + math.cos(a) * length, cy - math.sin(a) * length
    d.line((cx, cy, ex, ey), fill=figure.shade, width=thickness * SS)
    d.line((cx, cy, ex, ey), fill=INK, width=max(1, thickness - 4) * SS)
    d.ellipse((ex - 6 * SS, ey - 6 * SS, ex + 6 * SS, ey + 6 * SS),
              fill=figure.fill, outline=INK, width=2 * SS)


def bubble_text(d, cx, cy, text, font, color):
    d.text((cx, cy), text, font=font, fill=color, anchor="mm")


# ---------------------------------------------------------------- character

def character_frame(state, index, fonts, figure):
    """One 128×128 frame of a kit character, drawn at CELL * SS."""
    size = CELL * SS
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    u = SS                              # one source pixel
    cx, base = 64 * u, GROUND * u       # centre line, ground line
    phase = index / COLUMNS             # 0..1 around the loop
    wave = math.sin(phase * 2 * math.pi)

    w, h = figure.width, figure.height
    spread, drop = figure.eye_spread, figure.mouth_drop
    acc = figure.accessory_dx

    if state == "idle":
        breath = wave * 2 * u
        figure.draw(d, cx, base, w, h + breath)
        ey = base - (h + breath) * figure.eye_line
        eyes(d, cx, ey, spread, "closed" if index == 5 else "open")
        mouth(d, cx, ey + drop, 9 * u, "flat")

    elif state == "thinking":
        figure.draw(d, cx, base, w, h, lean=-2 * u)
        ey = base - h * figure.eye_line
        eyes(d, cx, ey, spread, "open", look=(0.4, -0.8))
        mouth(d, cx, ey + drop, 8 * u, "flat")
        for dot in range(3):
            lit = (index // 2) % 3 == dot
            r = (5 if lit else 3.5) * u
            dx = cx + (dot - 1) * 14 * u + 22 * u
            dy = 30 * u - (2 * u if lit else 0)
            d.ellipse((dx - r, dy - r, dx + r, dy + r),
                      fill=AMBER if lit else GUIDE_STRONG)

    elif state == "working":
        bob = abs(wave) * 4 * u
        figure.draw(d, cx, base - bob, w, h, lean=4 * u)
        ey = base - h * figure.eye_line - bob
        eyes(d, cx, ey, spread, "open", look=(0.5, 0.2))
        mouth(d, cx, ey + drop, 9 * u, "flat")
        arm(d, cx + figure.arm_dx, base - h * 0.45 - bob,
            -20 + wave * 35, 26 * u, figure)
        # An orbiting spark: motion that is legible even at one frame a second.
        a = phase * 2 * math.pi
        sx, sy = cx + math.cos(a) * 40 * u, 34 * u + math.sin(a) * 10 * u
        d.ellipse((sx - 5 * u, sy - 5 * u, sx + 5 * u, sy + 5 * u), fill=AMBER)

    elif state == "waiting":
        tilt = wave * 3 * u
        figure.draw(d, cx, base, w, h, lean=tilt)
        ey = base - h * figure.eye_line
        eyes(d, cx + tilt * 0.5, ey, spread, "wide", look=(0.0, -0.2))
        mouth(d, cx + tilt * 0.5, ey + drop, 8 * u, "o")
        bubble_text(d, cx + acc, 30 * u - abs(wave) * 4 * u, "?",
                    fonts["glyph"], AMBER)

    elif state == "review":
        hop = max(0.0, wave) * 8 * u
        figure.draw(d, cx, base - hop, w * 1.02, h)
        ey = base - h * figure.eye_line - hop
        eyes(d, cx, ey, spread, "happy")
        mouth(d, cx, ey + drop, 11 * u, "smile")
        rise = 34 * u - phase * 8 * u
        d.line((cx + acc - 8 * u, rise, cx + acc - u, rise + 8 * u),
               fill=GREEN, width=5 * u)
        d.line((cx + acc - u, rise + 8 * u, cx + acc + 12 * u, rise - 10 * u),
               fill=GREEN, width=5 * u)

    elif state == "failed":
        droop = min(index, 3) * 2 * u + abs(wave) * u
        figure.draw(d, cx, base, w + droop, h - droop)
        ey = base - (h - droop) * (figure.eye_line - 0.04)
        eyes(d, cx, ey, spread, "sad")
        mouth(d, cx, ey + drop, 10 * u, "frown")
        if index < 4:
            bubble_text(d, cx + acc, 32 * u, "!", fonts["glyph"], RED)

    elif state == "waving":
        lean = wave * 2 * u
        figure.draw(d, cx, base, w, h, lean=lean)
        ey = base - h * figure.eye_line
        eyes(d, cx + lean * 0.5, ey, spread, "happy")
        mouth(d, cx + lean * 0.5, ey + drop, 11 * u, "smile")
        arm(d, cx + figure.arm_dx - 2 * u, base - h * 0.55,
            55 + wave * 35, 34 * u, figure)

    elif state == "jumping":
        # A single arc across the row: up, hang, down, land squashed.
        t = index / (COLUMNS - 1)
        lift = math.sin(t * math.pi) * 30 * u
        squash = 0.0
        if index == 0:
            squash = 6 * u
        if index == COLUMNS - 1:
            squash = 8 * u
        figure.draw(d, cx, base - lift, w + squash, h - squash)
        ey = base - lift - (h - squash) * figure.eye_line
        eyes(d, cx, ey, spread, "happy" if lift > 6 * u else "open")
        mouth(d, cx, ey + drop, 11 * u, "smile")
        if lift > 6 * u:
            arm(d, cx - figure.arm_dx, base - lift - h * 0.5, 130, 24 * u, figure)
            arm(d, cx + figure.arm_dx, base - lift - h * 0.5, 50, 24 * u, figure)

    elif state == "sleeping":
        breath = wave * 3 * u
        settled = h * 0.72 + breath
        figure.draw(d, cx, base, w + 6 * u, settled)
        ey = base - settled * (figure.eye_line - 0.04)
        eyes(d, cx, ey, spread, "closed")
        mouth(d, cx, ey + drop - 2 * u, 7 * u, "flat")
        for i in range(3):
            step = (index + i * 3) % COLUMNS
            zy = 46 * u - step * 5 * u
            zx = cx + 26 * u + step * 2 * u
            bubble_text(d, zx, zy, "z", fonts["small"], GUIDE_STRONG)

    else:
        raise SystemExit(f"no drawing for state '{state}'")

    return img.resize((CELL, CELL), Image.LANCZOS)


# ----------------------------------------------------------------- template

def template_frame(state, index, fonts, _figure=None):
    """One guide cell: safe area, centre line, ground line, and its address."""
    img = Image.new("RGBA", (CELL, CELL), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rectangle((0, 0, CELL - 1, CELL - 1), outline=GUIDE, width=1)
    inset = 12
    d.rounded_rectangle((inset, inset, CELL - 1 - inset, CELL - 1 - inset),
                        radius=10, outline=GUIDE, width=1)
    d.line((CELL // 2, 6, CELL // 2, CELL - 6), fill=GUIDE, width=1)
    # The ground line the character stands on, so traced art lands at the same
    # height in every cell — the difference between a companion that stands
    # and one that bobs randomly.
    d.line((8, GROUND, CELL - 8, GROUND), fill=GUIDE_STRONG, width=1)
    d.text((CELL - 6, CELL - 5), str(index), font=fonts["label"], fill=LABEL,
           anchor="rs")
    d.text((6, CELL - 5), state, font=fonts["label"], fill=LABEL, anchor="ls")
    return img


# ------------------------------------------------------------------ packages

def sheet(draw_frame, fonts, figure=None):
    image = Image.new("RGBA", (COLUMNS * CELL, len(STATES) * CELL), (0, 0, 0, 0))
    for name, row, _ms, _purpose in STATES:
        for column in range(COLUMNS):
            image.alpha_composite(draw_frame(name, column, fonts, figure),
                                  (column * CELL, row * CELL))
    return image


def manifest(sprite_id, name, description):
    states = {}
    for state, row, ms, purpose in STATES:
        entry = {"frames": {"row": row, "count": COLUMNS}, "ms": ms,
                 "purpose": purpose}
        if state in ("waving", "jumping"):
            entry["interrupt"] = "after-loop"
        states[state] = entry
    return {
        "format": "motive/1",
        "metadata": {
            "id": sprite_id,
            "name": name,
            "description": description,
            "author": "Motive",
            "license": "MIT",
            "version": "1.0.0",
        },
        "atlases": {
            "sprite": {"path": "spritesheet.png", "cell": [CELL, CELL],
                       "grid": [COLUMNS, len(STATES)]}
        },
        "states": states,
        # The words an agent reaches for that this sprite spells differently.
        "aliases": {
            "running": "working",
            "busy": "working",
            "done": "review",
            "error": "failed",
            "blocked": "waiting",
            "asleep": "sleeping",
        },
        "triggers": {
            "wave": {"state": "waving", "once": True,
                     "purpose": "greet the human, then return to what you were doing"},
            "jump": {"state": "jumping", "once": True,
                     "purpose": "celebrate something small without claiming a mood"},
        },
        "transitions": [{"from": "*", "to": "*", "ms": 180}],
    }


def write_package(directory, image, document):
    directory.mkdir(parents=True, exist_ok=True)
    image.save(directory / "spritesheet.png", optimize=True)
    (directory / "motive.json").write_text(
        json.dumps(document, indent=2) + "\n")
    print(f"{directory.relative_to(ROOT)}: "
          f"{image.width}×{image.height}, "
          f"{(directory / 'spritesheet.png').stat().st_size // 1024} KiB")


def main():
    # The character is drawn supersampled, so its glyph sizes are in
    # SS-space; the template is drawn at cell scale and its labels are not.
    fonts = {
        "glyph": load_font(34 * SS),
        "small": load_font(16 * SS),
        "label": load_font(11),
    }

    write_package(
        KIT / "packs/pip/sprite",
        sheet(character_frame, fonts, FIGURES["pip"]),
        manifest("pip", "Pip",
                 "A round companion covering the whole lifecycle vocabulary. "
                 "Copy the package and repaint it cell for cell."))

    write_package(
        KIT / "packs/caret/sprite",
        sheet(character_frame, fonts, FIGURES["caret"]),
        manifest("caret", "Caret",
                 "A terminal caret with the same vocabulary as Pip, drawn for "
                 "companions that sit beside a CLI agent session."))

    write_package(
        KIT / "components/sprites/grid-template",
        sheet(template_frame, fonts),
        manifest("grid-template", "Grid Template",
                 "The kit grid as guides and labels instead of a character: "
                 "safe area, centre line, ground line, and each cell's "
                 "address. Draw over it."))


if __name__ == "__main__":
    main()
