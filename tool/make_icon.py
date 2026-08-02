#!/usr/bin/env python3
"""Generate the app icon: the WHOOP mark — a ring enclosing a `\\/\\/` glyph.

Redrawn as geometry rather than upscaled. The supplied reference was 240x240,
and a 4x bicubic upsample of a 240 px source to a 1024 px app icon is visibly
soft on the ring — an icon is the one asset that has to be crisp at every size.
So the strokes below were MEASURED off that reference (run-length scan per row,
centre of each stroke tracked down the glyph) and are re-emitted at any size.

Geometry is expressed in the reference's own 240 px space and scaled, so the
numbers here can be checked directly against the source image.

Usage:  python3 tool/make_icon.py
"""

import os
import subprocess

from PIL import Image, ImageDraw

# ── measured from the 240 px reference ───────────────────────────────────────
REF = 240.0
CX = CY = 119.5
R_OUT = 90.0          # outer edge of the ring
RING_W = 8.0          # ring stroke
GLYPH_W = 8.6         # glyph stroke (perpendicular width)

# The four strokes, (x0, y0) → (x1, y1).
#
# NOTE THE ASYMMETRY, which is real and not a measurement error: the right pair
# meets at a clean vertex (143.5, 161) while the left `\` stops short at y=133.
# That uneven left stroke is the mark's distinguishing feature — "correcting" it
# to a symmetric W produces a different logo.
STROKES = [
    ((72.0, 88.0), (86.5, 133.0)),    # \  short, top-left
    ((119.5, 88.0), (96.0, 161.0)),   # /  full
    ((127.7, 113.0), (143.5, 161.0)), # \  lower, meets the next at its vertex
    ((167.0, 88.0), (143.5, 161.0)),  # /  full
]

BG = (0, 0, 0)
FG = (255, 255, 255)

# Draw at 4x then downsample: PIL has no antialiased stroking, so supersampling
# is what keeps the ring and the diagonals from stair-stepping.
SS = 4


def render(size: int) -> Image.Image:
    n = size * SS
    k = n / REF
    im = Image.new("RGB", (n, n), BG)
    d = ImageDraw.Draw(im)

    # Ring — drawn as an outline circle centred on the stroke's midline.
    r_mid = (R_OUT - RING_W / 2) * k
    d.ellipse(
        [CX * k - r_mid, CY * k - r_mid, CX * k + r_mid, CY * k + r_mid],
        outline=FG,
        width=max(1, round(RING_W * k)),
    )

    # Glyph — round joints so the vertex where two strokes meet reads as a
    # point rather than a notch.
    for (x0, y0), (x1, y1) in STROKES:
        d.line(
            [x0 * k, y0 * k, x1 * k, y1 * k],
            fill=FG,
            width=max(1, round(GLYPH_W * k)),
            joint="curve",
        )

    return im.resize((size, size), Image.LANCZOS)


def main() -> None:
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

    # In-app asset (share cards, splash).
    assets = os.path.join(root, "assets", "images")
    os.makedirs(assets, exist_ok=True)
    render(1024).save(os.path.join(assets, "icon.png"))

    # iOS app icon set. Sizes come from the existing Contents.json filenames so
    # nothing is missed and nothing extra is written.
    appicon = os.path.join(
        root, "ios", "Runner", "Assets.xcassets", "AppIcon.appiconset"
    )
    written = 0
    for name in sorted(os.listdir(appicon)):
        if not name.endswith(".png"):
            continue
        # "Icon-App-83.5x83.5@2x.png" → 83.5 * 2 = 167
        stem = name[len("Icon-App-"):-len(".png")]
        dims, _, scale = stem.partition("@")
        px = round(float(dims.split("x")[0]) * int(scale.rstrip("x")))
        render(px).save(os.path.join(appicon, name))
        written += 1

    # Android, if the project carries launcher icons.
    android = os.path.join(root, "android", "app", "src", "main", "res")
    if os.path.isdir(android):
        for folder, px in (
            ("mipmap-mdpi", 48),
            ("mipmap-hdpi", 72),
            ("mipmap-xhdpi", 96),
            ("mipmap-xxhdpi", 144),
            ("mipmap-xxxhdpi", 192),
        ):
            p = os.path.join(android, folder)
            if os.path.isdir(p):
                render(px).save(os.path.join(p, "ic_launcher.png"))

    print(f"wrote assets/images/icon.png + {written} iOS icons")

    # iOS rejects an alpha channel on app icons; these are RGB already, but a
    # future edit could reintroduce one silently.
    out = subprocess.run(
        ["file", os.path.join(appicon, "Icon-App-1024x1024@1x.png")],
        capture_output=True,
        text=True,
    ).stdout
    assert "RGBA" not in out, f"app icon must not carry alpha: {out}"


if __name__ == "__main__":
    main()
