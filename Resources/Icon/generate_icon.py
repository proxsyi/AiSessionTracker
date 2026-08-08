#!/usr/bin/env python3
"""
Generates the Session Pinger app icon as pixel art, following the house
icon-design rules (encapsulated square, rounded corners, darker greyish-teal
border panel with a soft top highlight, bright flat inner background, simple
outlined central symbol) using the app's own Claude-orange accent color.

Drawn at a native 32x32 pixel grid, then scaled up with nearest-neighbor
resampling (never smoothed) for every size macOS needs in an .iconset.
"""
from PIL import Image, ImageDraw
import os

BASE = 32

BORDER = (47, 61, 61, 255)          # dark greyish-teal border panel
BORDER_HIGHLIGHT = (99, 118, 118, 255)  # soft inner top-edge highlight
INNER_BG = (203, 101, 67, 255)      # Claude accent orange (from Theme.swift)
SYMBOL_FILL = (250, 241, 230, 255)  # warm cream
SYMBOL_OUTLINE = (58, 33, 21, 255)  # dark brown outline


def build_base_icon() -> Image.Image:
    img = Image.new("RGBA", (BASE, BASE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # Outer encapsulating panel: rounded square, darker greyish-teal.
    draw.rounded_rectangle([0, 0, BASE - 1, BASE - 1], radius=7, fill=BORDER)
    # Subtle depressed/button-like inner highlight along the top edge.
    draw.line([(3, 1), (BASE - 4, 1)], fill=BORDER_HIGHLIGHT)

    # Inner icon area: solid bright background, inset from the border.
    inset = 3
    draw.rounded_rectangle(
        [inset, inset, BASE - 1 - inset, BASE - 1 - inset], radius=5, fill=INNER_BG
    )

    # Central symbol: a stopwatch, standing in for scheduled session pings.
    cx, cy = BASE // 2, BASE // 2 + 1
    r = 8

    # Crown button on top.
    draw.rectangle([cx - 2, cy - r - 4, cx + 2, cy - r - 1], fill=SYMBOL_OUTLINE)
    draw.rectangle([cx - 1, cy - r - 3, cx + 1, cy - r - 2], fill=SYMBOL_FILL)

    # Watch body: dark outline circle with cream face.
    draw.ellipse([cx - r - 1, cy - r - 1, cx + r + 1, cy + r + 1], fill=SYMBOL_OUTLINE)
    draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=SYMBOL_FILL)

    # Clock hands, pointing up and to the right (a moment about to fire).
    draw.line([(cx, cy), (cx, cy - r + 2)], fill=SYMBOL_OUTLINE, width=1)
    draw.line([(cx, cy), (cx + r - 3, cy - 2)], fill=SYMBOL_OUTLINE, width=1)
    draw.point((cx, cy), fill=SYMBOL_OUTLINE)

    return img


def main() -> None:
    out_dir = os.path.join(os.path.dirname(__file__), "AppIcon.iconset")
    os.makedirs(out_dir, exist_ok=True)

    base = build_base_icon()
    base.save(os.path.join(os.path.dirname(__file__), "icon_32_base.png"))

    # macOS .iconset naming/sizes.
    targets = {
        "icon_16x16.png": 16,
        "icon_16x16@2x.png": 32,
        "icon_32x32.png": 32,
        "icon_32x32@2x.png": 64,
        "icon_128x128.png": 128,
        "icon_128x128@2x.png": 256,
        "icon_256x256.png": 256,
        "icon_256x256@2x.png": 512,
        "icon_512x512.png": 512,
        "icon_512x512@2x.png": 1024,
    }

    for filename, size in targets.items():
        scaled = base.resize((size, size), Image.NEAREST)
        scaled.save(os.path.join(out_dir, filename))

    print(f"Wrote base art + {len(targets)} sizes to {out_dir}")


if __name__ == "__main__":
    main()
