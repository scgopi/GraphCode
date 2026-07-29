#!/usr/bin/env python3
"""Render the app icon set from the master artwork.

The artwork itself (`icon-master-1024.png`) is the source of truth and is never
written to — every PNG in `AppIcon.appiconset` is derived from it here, so the sizes
can't drift apart and a tweak means re-running this rather than editing seven files.

The one adjustment this applies is darkening the icon's body. It is deliberately not a
flat multiply: the nodes are near-white and their glow fades through the midtones, so
scaling every pixel would grey the nodes and leave a dirty ring where the glow sits.
Instead the darkening is weighted by how dark a pixel already is — the body takes it in
full, the glow takes a fraction, the nodes take none. See `background_weight`.

Usage:
    python3 Tools/icon/render-appicon.py                # default darkening
    python3 Tools/icon/render-appicon.py --darken 1.0   # regenerate unchanged
    python3 Tools/icon/render-appicon.py --preview      # write a before/after strip
"""

import argparse
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
MASTER = Path(__file__).resolve().parent / "icon-master-1024.png"
APPICONSET = ROOT / "graphcode/Resources/Assets.xcassets/AppIcon.appiconset"

# Every pixel size the appiconset references.
SIZES = [16, 32, 64, 128, 256, 512, 1024]

# Luminance below this is pure body colour and is darkened in full; above the upper
# bound is node white and is left alone. Between them the weight eases off, which is
# what keeps the glow from banding.
BODY_LUMA = 0.10
NODE_LUMA = 0.62

# How much of the body's brightness to keep. Chosen so the gradient's dark end lands
# near the canvas fill the nodes are drawn against in-app, rather than going flat black.
DEFAULT_DARKEN = 0.58


def background_weight(luma: float) -> float:
    """How much of the darkening a pixel at this luminance should take, 0..1."""
    if luma <= BODY_LUMA:
        return 1.0
    if luma >= NODE_LUMA:
        return 0.0
    t = (luma - BODY_LUMA) / (NODE_LUMA - BODY_LUMA)
    # Smoothstep, so the transition through the glow has no visible edge.
    return 1.0 - (t * t * (3.0 - 2.0 * t))


def darken(image: Image.Image, factor: float) -> Image.Image:
    if factor >= 1.0:
        return image
    out = image.copy()
    pixels = out.load()
    width, height = out.size
    for y in range(height):
        for x in range(width):
            r, g, b, a = pixels[x, y]
            if a == 0:
                continue
            luma = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0
            weight = background_weight(luma)
            if weight == 0.0:
                continue
            scale = 1.0 - weight * (1.0 - factor)
            pixels[x, y] = (round(r * scale), round(g * scale), round(b * scale), a)
    return out


def sample(image: Image.Image, label: str) -> None:
    points = {"top": (512, 120), "middle": (160, 512), "bottom": (512, 900), "node": (370, 330)}
    parts = [f"{name} rgb{image.getpixel(point)[:3]}" for name, point in points.items()]
    print(f"  {label:9s} " + "  ".join(parts))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--darken", type=float, default=DEFAULT_DARKEN)
    parser.add_argument(
        "--preview",
        nargs="?",
        const="/tmp/icon-preview.png",
        help="write a before/after strip here instead of updating the appiconset")
    args = parser.parse_args()

    master = Image.open(MASTER).convert("RGBA")
    rendered = darken(master, args.darken)

    print(f"darken factor {args.darken}")
    sample(master, "before")
    sample(rendered, "after")

    if args.preview:
        strip = Image.new("RGBA", (master.width * 2, master.height), (0, 0, 0, 0))
        strip.paste(master, (0, 0))
        strip.paste(rendered, (master.width, 0))
        strip.thumbnail((1024, 512), Image.LANCZOS)
        out = Path(args.preview)
        strip.save(out)
        print(f"preview: {out}")
        return

    for size in SIZES:
        resized = rendered if size == master.width else rendered.resize((size, size), Image.LANCZOS)
        resized.save(APPICONSET / f"icon_{size}.png")
    print(f"wrote {len(SIZES)} PNGs to {APPICONSET.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
