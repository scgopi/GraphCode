#!/usr/bin/env python3
"""Render the app icon set from the master artwork.

The artwork (`icon-master-1024.png`, drawn by `make-master.py`) is the source of truth
and is never written to — every PNG in `AppIcon.appiconset` is derived from it here, so
the sizes can't drift apart and a tweak means re-running this rather than editing seven
files.

**Both adjustments below are off by default now.** They existed to compensate for the
previous hand-produced master: its halos decayed within 2-3% of the icon width and its
tile was twice as bright at the top as the bottom. The master is drawn from the design
spec's own numbers, so a pass that re-lights or re-darkens it is a pass that overrides
the colours the spec fixed — the body came out near-black (rgb 36,36,40 against a
specified #3E3E47) and the node glow the spec deliberately replaced with a drop shadow
came back. Both flags remain for re-tuning artwork that needs them.

The two adjustments, when enabled:

1. A glow pass. The master's halos decay within ~2-3% of the icon width and the tile
   gradient is twice as bright at the top as the bottom, so out of the box the upper
   nodes read as unlit and the glow vanishes entirely at Dock sizes. The pass screens
   three halos over the artwork — a tight rim and a wide bloom around the nodes, plus
   a faint glow along the edges — with the gain ramped up toward the top of the tile
   to cancel the gradient. See `glow`.

2. Darkening of the icon's body. It is deliberately not a flat multiply: the nodes are
   near-white and their glow fades through the midtones, so scaling every pixel would
   grey the nodes and leave a dirty ring where the glow sits. Instead the darkening is
   weighted by how dark a pixel already is — the body takes it in full, the glow takes
   a fraction, the nodes take none. See `background_weight`.

The 16 and 32 px renders come from `icon-master-small-1024.png` when it exists — a
simplified three-node variant whose strokes survive the downscale (the full four-node
graph mushes into noise below 48 px).

Usage:
    python3 Tools/icon/render-appicon.py                # the master, unaltered
    python3 Tools/icon/render-appicon.py --glow         # re-light a master with weak halos
    python3 Tools/icon/render-appicon.py --darken 0.45  # the old tuning
    python3 Tools/icon/render-appicon.py --preview      # write a before/after strip
"""

import argparse
from pathlib import Path

import numpy as np
from PIL import Image, ImageChops, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
MASTER = Path(__file__).resolve().parent / "icon-master-1024.png"
SMALL_MASTER = Path(__file__).resolve().parent / "icon-master-small-1024.png"
APPICONSET = ROOT / "graphcode/Resources/Assets.xcassets/AppIcon.appiconset"

# Every pixel size the appiconset references; sizes at or below SMALL_CUTOFF render
# from the simplified master.
SIZES = [16, 32, 64, 128, 256, 512, 1024]
SMALL_CUTOFF = 32

# Luminance below this is pure body colour and is darkened in full; above the upper
# bound is node white and is left alone. Between them the weight eases off, which is
# what keeps the glow from banding.
BODY_LUMA = 0.10
NODE_LUMA = 0.62

# How much of the body's brightness to keep. 0.58 matched the in-app canvas fill; 0.45
# trades a little of that match for halo contrast — it lifts the glow-to-background
# ratio from 1.36 to 1.43, which is where the nodes start to read as lit at Dock sizes
# without the squircle edge dissolving into a dark desktop (0.32 crosses that line).
DEFAULT_DARKEN = 1.0

# Halo gains, tuned so the top-left node's halo sits ~0.08 luminance above the tile
# where it used to sit ~0.03 (imperceptible), while the node edges stay hard.
GLOW_TIGHT = 0.34   # sigma 9, crisp rim around the nodes
GLOW_SOFT = 0.22    # sigma 34, wide bloom that survives Dock sizes
GLOW_EDGE = 0.12    # sigma 14, faint glow along the connecting edges
# The tile gradient runs ~0.32 luma at the top to ~0.14 at the bottom; ramping the
# glow gain 1.3x (top) -> 1.0x (bottom) cancels it so the halos read evenly.
GLOW_RAMP_TOP = 1.30


def glow(image: Image.Image) -> Image.Image:
    rgb = image.convert("RGB")
    gray = rgb.convert("L")

    nodes_mask = gray.point(lambda v: max(0, (v - 178)) * 3)   # luma > 0.7: nodes
    mid_mask = gray.point(lambda v: max(0, (v - 107)) * 2)     # luma > 0.42: + edges

    height = image.height
    ramp = Image.new("L", (1, height))
    for y in range(height):
        ramp.putpixel((0, y), round(255 * (GLOW_RAMP_TOP - (GLOW_RAMP_TOP - 1.0) * y / (height - 1)) / GLOW_RAMP_TOP))
    ramp = ramp.resize(image.size)

    def halo(mask: Image.Image, sigma: float, gain: float) -> Image.Image:
        h = mask.filter(ImageFilter.GaussianBlur(sigma))
        h = ImageChops.multiply(h, ramp)
        return h.point(lambda v: min(255, round(v * gain)))

    halos = ImageChops.add(
        ImageChops.add(halo(nodes_mask, 9, GLOW_TIGHT), halo(nodes_mask, 34, GLOW_SOFT)),
        halo(mid_mask, 14, GLOW_EDGE))

    # Keep the glow inside the tile; the semi-transparent drop shadow stays untouched.
    alpha = image.split()[3]
    halos = ImageChops.multiply(halos, alpha.point(lambda a: 255 if a > 240 else 0))

    out = ImageChops.screen(rgb, Image.merge("RGB", (halos, halos, halos)))
    return Image.merge("RGBA", (*out.split(), alpha))


def darken(image: Image.Image, factor: float) -> Image.Image:
    if factor >= 1.0:
        return image
    px = np.asarray(image, dtype=np.float32)
    rgb, a = px[..., :3], px[..., 3:]
    luma = (0.2126 * px[..., 0] + 0.7152 * px[..., 1] + 0.0722 * px[..., 2]) / 255.0
    # Smoothstep from full darkening at BODY_LUMA to none at NODE_LUMA, so the
    # transition through the glow has no visible edge.
    t = np.clip((luma - BODY_LUMA) / (NODE_LUMA - BODY_LUMA), 0.0, 1.0)
    weight = 1.0 - (t * t * (3.0 - 2.0 * t))
    weight[a[..., 0] == 0] = 0.0
    scale = 1.0 - weight * (1.0 - factor)
    out = np.concatenate([np.round(rgb * scale[..., None]), a], axis=-1)
    return Image.fromarray(out.astype(np.uint8), "RGBA")


def sample(image: Image.Image, label: str) -> None:
    points = {"top": (512, 120), "middle": (160, 512), "bottom": (512, 900), "node": (370, 330)}
    parts = [f"{name} rgb{image.getpixel(point)[:3]}" for name, point in points.items()]
    print(f"  {label:9s} " + "  ".join(parts))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--darken", type=float, default=DEFAULT_DARKEN)
    parser.add_argument(
        "--glow", action="store_true",
        help="re-light the nodes; only needed by a master whose halos decay too fast")
    parser.add_argument(
        "--preview",
        nargs="?",
        const="/tmp/icon-preview.png",
        help="write a before/after strip here instead of updating the appiconset")
    args = parser.parse_args()

    def render(path: Path) -> Image.Image:
        image = Image.open(path).convert("RGBA")
        if args.glow:
            image = glow(image)
        return darken(image, args.darken)

    master = Image.open(MASTER).convert("RGBA")
    rendered = render(MASTER)

    print(f"darken factor {args.darken}, glow {'on' if args.glow else 'off'}")
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

    small_rendered = None
    if SMALL_MASTER.exists():
        small_rendered = render(SMALL_MASTER)
        print(f"small sizes (<= {SMALL_CUTOFF}px) from {SMALL_MASTER.name}")

    for size in SIZES:
        source = small_rendered if small_rendered is not None and size <= SMALL_CUTOFF else rendered
        resized = source if size == source.width else source.resize((size, size), Image.LANCZOS)
        resized.save(APPICONSET / f"icon_{size}.png")
    print(f"wrote {len(SIZES)} PNGs to {APPICONSET.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
