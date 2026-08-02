#!/usr/bin/env python3
"""Generate the combined Session Tracker pixel-art app icon."""

from pathlib import Path
import shutil
import subprocess


ROOT = Path(__file__).parent
ICONSET = ROOT / "AppIcon.iconset"
BASE = ROOT / "icon_32_base.png"


def run(*arguments: str) -> None:
    subprocess.run(arguments, check=True)


def main() -> None:
    magick = shutil.which("magick")
    if not magick:
        raise SystemExit("ImageMagick is required (the `magick` command was not found).")

    ICONSET.mkdir(exist_ok=True)
    # Outer panel, inset background, GPT ring, then Claude sparkle.
    drawing = " ".join([
        "fill '#2f3d3d' roundrectangle 0,0 31,31 7,7",
        "stroke '#637676' stroke-width 1 line 3,1 28,1",
        "stroke none fill '#23272b' roundrectangle 3,3 28,28 5,5",
        "fill none stroke '#3a2115' stroke-width 5 path 'M 23.4,21.9 A 9,9 0 1,1 23.4,10.1'",
        "fill none stroke '#0fc984' stroke-width 3 path 'M 23.4,21.9 A 9,9 0 1,1 23.4,10.1'",
        "stroke none fill '#3a2115' polygon 16,9 18,14 23,16 18,18 16,23 14,18 9,16 14,14",
        "stroke none fill '#e08052' polygon 16,11 17,15 21,16 17,17 16,21 15,17 11,16 15,15",
    ])
    run(magick, "-size", "32x32", "xc:none", "-draw", drawing, str(BASE))

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
        run(
            magick,
            str(BASE),
            "-filter", "point",
            "-resize", f"{size}x{size}",
            str(ICONSET / filename),
        )

    print(f"Wrote base art + {len(targets)} sizes to {ICONSET}")


if __name__ == "__main__":
    main()
