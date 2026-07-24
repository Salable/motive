#!/usr/bin/env python3
"""Generate Resources/AppIcon.icns from Salli's first idle frame.

Deterministic: crops cell (0,0) of the sprite atlas, pads to square on a
rounded-rect background, and emits every icns size via iconutil.
"""
import pathlib
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw

ROOT = pathlib.Path(__file__).resolve().parent.parent
SHEET = ROOT / "Sprites/salli/spritesheet.png"
OUT = ROOT / "Resources/AppIcon.icns"
CELL = (192, 208)
BACKGROUND = (245, 236, 224, 255)  # warm paper
CORNER_RADIUS_FRACTION = 0.22

def build_master(size: int = 1024) -> Image.Image:
    frame = Image.open(SHEET).convert("RGBA").crop((0, 0, CELL[0], CELL[1]))
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    # Rounded-rect background per macOS icon conventions.
    bg = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(bg)
    draw.rounded_rectangle((0, 0, size, size), radius=int(size * CORNER_RADIUS_FRACTION), fill=BACKGROUND)
    canvas.alpha_composite(bg)
    # Sprite centered at ~78% of the tile.
    target_h = int(size * 0.78)
    target_w = int(target_h * CELL[0] / CELL[1])
    sprite = frame.resize((target_w, target_h), Image.NEAREST)
    canvas.alpha_composite(sprite, ((size - target_w) // 2, (size - target_h) // 2))
    return canvas

def main() -> None:
    OUT.parent.mkdir(parents=True, exist_ok=True)
    master = build_master()
    with tempfile.TemporaryDirectory() as tmp:
        iconset = pathlib.Path(tmp) / "AppIcon.iconset"
        iconset.mkdir()
        for points in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                px = points * scale
                suffix = "" if scale == 1 else "@2x"
                master.resize((px, px), Image.LANCZOS).save(iconset / f"icon_{points}x{points}{suffix}.png")
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(OUT)], check=True)
    print(OUT)

if __name__ == "__main__":
    sys.exit(main())
