#!/usr/bin/env python3
"""Derive the simplified small-size master from the main master artwork.

Below ~48 px the four-node graph mushes into noise — the edges thin out to
sub-pixel and the node cluster reads as smudges. This script builds
`icon-master-small-1024.png`: the same tile with a three-node graph whose node
radii and stroke widths are chosen to stay legible after a 16 px downscale.

The tile background is recovered from the master itself rather than redrawn, so
the two masters can't drift apart: every pixel under the artwork is filled by
horizontal interpolation across the tile (the gradient is vertical, so rows
interpolate cleanly), then the simplified graph is drawn on top at 4x and
downsampled.

Usage:
    python3 Tools/icon/make-small-master.py
"""

from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

HERE = Path(__file__).resolve().parent
MASTER = HERE / "icon-master-1024.png"
OUT = HERE / "icon-master-small-1024.png"

# Three nodes, sized so that at 16 px a node is ~2.5 px across and a stroke ~1 px.
NODES = [(500, 330, 132), (322, 664, 116), (688, 652, 122)]
EDGES = [(0, 1), (0, 2), (1, 2)]
STROKE = 62
EDGE_COLOR = (168, 172, 179)
NODE_COLOR = (248, 249, 251)


def recover_tile(master: Image.Image) -> Image.Image:
    """Fill the artwork region of the tile by interpolating the gradient across it."""
    px = np.asarray(master, dtype=np.float32)
    luma = (0.2126 * px[..., 0] + 0.7152 * px[..., 1] + 0.0722 * px[..., 2]) / 255.0
    inside = px[..., 3] > 240

    artwork = Image.fromarray(((luma > 0.42) & inside).astype(np.uint8) * 255)
    artwork = artwork.filter(ImageFilter.MaxFilter(41))  # dilate past the glow skirt
    masked = np.asarray(artwork) > 0

    out = px.copy()
    for y in range(master.height):
        row_inside = np.flatnonzero(inside[y])
        if row_inside.size < 2:
            continue
        row_masked = masked[y] & inside[y]
        known = np.flatnonzero(inside[y] & ~row_masked)
        fill = np.flatnonzero(row_masked)
        if fill.size == 0 or known.size < 2:
            continue
        for c in range(3):
            out[y, fill, c] = np.interp(fill, known, px[y, known, c])
    return Image.fromarray(out.astype(np.uint8), "RGBA")


def draw_graph(tile: Image.Image) -> Image.Image:
    scale = 4
    layer = Image.new("RGBA", (tile.width * scale, tile.height * scale), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    for a, b in EDGES:
        ax, ay, _ = NODES[a]
        bx, by, _ = NODES[b]
        draw.line([(ax * scale, ay * scale), (bx * scale, by * scale)],
                  fill=(*EDGE_COLOR, 255), width=STROKE * scale)
    for x, y, r in NODES:
        draw.ellipse([(x - r) * scale, (y - r) * scale, (x + r) * scale, (y + r) * scale],
                     fill=(*NODE_COLOR, 255))
    layer = layer.resize(tile.size, Image.LANCZOS)
    out = tile.copy()
    out.alpha_composite(layer)
    return out


def main() -> None:
    master = Image.open(MASTER).convert("RGBA")
    small = draw_graph(recover_tile(master))
    small.save(OUT)
    print(f"wrote {OUT.relative_to(HERE.parent.parent)}")


if __name__ == "__main__":
    main()
