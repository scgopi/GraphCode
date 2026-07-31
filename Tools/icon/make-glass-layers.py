#!/usr/bin/env python3
"""Derive the Liquid Glass icon package from the master artwork.

`graphcode/Resources/AppIcon.icon` is the Icon Composer package macOS 26+ renders
with glass depth; the appiconset stays as the fallback for older systems. Two
lessons from the first attempt shape how it's built:

- The glass layer is drawn from geometry measured off the master, not matted out
  of it. A luma matte can't separate the graph from the tile's inner rim highlight
  or the bright top of the gradient — both leaked in as a ghost rectangle around
  the icon. Node centers and stroke width are detected from the master each run,
  so the two renditions still can't drift; only the edge topology is stated here.
- Layers render edge-to-edge in the icon shape, so everything is mapped from
  master coordinates to the tile's own bounds. Leaving the master's margins in
  place shrank the graph by ~20%.

The background is the fill in icon.json — a linear gradient sampled from the tile
and darkened with the render pipeline's darken() at the same factor as the
appiconset. A background image layer would render as a glass slab with a visible
edge; a fill can't.

Usage:
    python3 Tools/icon/make-glass-layers.py
"""

import importlib.util
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
ICON_PACKAGE = ROOT / "graphcode/Resources/AppIcon.icon"

# The graph's topology; node positions and sizes are measured from the master.
EDGES = [(0, 1), (0, 2), (0, 3), (1, 3), (2, 3)]
NODE_LUMA = 0.8
EDGE_LUMA = 0.42
NODE_COLOR = (248, 249, 251)
EDGE_COLOR = (145, 148, 155)
SUPERSAMPLE = 4


def load(name: str):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), HERE / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

render = load("render-appicon")


def luma(px: np.ndarray) -> np.ndarray:
    return (0.2126 * px[..., 0] + 0.7152 * px[..., 1] + 0.0722 * px[..., 2]) / 255.0


def find_nodes(lum: np.ndarray) -> list[tuple[int, int, float]]:
    """Bright connected components -> (cx, cy, r), left-to-right by first sighting."""
    bright = lum > NODE_LUMA
    seen = np.zeros_like(bright)
    nodes = []
    ys, xs = np.where(bright)
    for y0, x0 in zip(ys[::50], xs[::50]):
        if seen[y0, x0]:
            continue
        stack, pts = [(y0, x0)], []
        while stack:
            y, x = stack.pop()
            if 0 <= y < lum.shape[0] and 0 <= x < lum.shape[1] and bright[y, x] and not seen[y, x]:
                seen[y, x] = True
                pts.append((y, x))
                stack += [(y + 1, x), (y - 1, x), (y, x + 1), (y, x - 1)]
        if len(pts) > 3000:
            pys, pxs = [p[0] for p in pts], [p[1] for p in pts]
            nodes.append(((min(pxs) + max(pxs)) / 2, (min(pys) + max(pys)) / 2,
                          (max(pxs) - min(pxs)) / 2))
    if len(nodes) != 4:
        raise SystemExit(f"expected 4 nodes in master, found {len(nodes)}")
    # stable order: top-left, right, bottom-left, bottom-mid (by y then x)
    nodes.sort(key=lambda n: (round(n[1] / 200), n[0]))
    return nodes


def measure_stroke(lum: np.ndarray, nodes) -> float:
    """Width of the horizontal bottom edge, scanned midway between its endpoints."""
    (ax, ay, _), (bx, by, _) = nodes[2], nodes[3]
    x = int((ax + bx) / 2)
    y0 = int(min(ay, by)) - 60
    col = np.where(lum[y0:y0 + 120, x] > EDGE_LUMA)[0]
    return float(col.max() - col.min() + 1)


def srgb(rgb) -> str:
    return "srgb:" + ",".join(f"{v / 255:.3f}" for v in rgb) + ",1.0"


def main() -> None:
    master = Image.open(HERE / "icon-master-1024.png").convert("RGBA")
    px = np.asarray(master, dtype=np.float32)
    lum = luma(px)
    inside = px[..., 3] > 240
    ys, xs = np.where(inside)
    top, bottom, left, right = ys.min(), ys.max(), xs.min(), xs.max()
    scale = 1024 / (right - left)

    nodes = find_nodes(lum)
    stroke = measure_stroke(lum, nodes)

    ss = SUPERSAMPLE
    layer = Image.new("RGBA", (1024 * ss, 1024 * ss), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    tiled = [((cx - left) * scale, (cy - top) * scale, r * scale) for cx, cy, r in nodes]
    for a, b in EDGES:
        ax, ay, _ = tiled[a]
        bx, by, _ = tiled[b]
        draw.line([(ax * ss, ay * ss), (bx * ss, by * ss)],
                  fill=(*EDGE_COLOR, 255), width=round(stroke * scale) * ss)
    for cx, cy, r in tiled:
        draw.ellipse([(cx - r) * ss, (cy - r) * ss, (cx + r) * ss, (cy + r) * ss],
                     fill=(*NODE_COLOR, 255))
    layer = layer.resize((1024, 1024), Image.LANCZOS)
    (ICON_PACKAGE / "Assets").mkdir(parents=True, exist_ok=True)
    layer.save(ICON_PACKAGE / "Assets/graph.png")

    # gradient endpoints: tile colors at top/bottom center, darkened like the appiconset
    cx = (left + right) // 2
    ends = Image.new("RGBA", (1, 2))
    ends.putpixel((0, 0), tuple(int(v) for v in px[top + 8, cx]))
    ends.putpixel((0, 1), tuple(int(v) for v in px[bottom - 8, cx]))
    ends = render.darken(ends, render.DEFAULT_DARKEN)
    fill_top, fill_bottom = ends.getpixel((0, 0))[:3], ends.getpixel((0, 1))[:3]

    icon = {
        "fill": {"linear-gradient": [srgb(fill_top), srgb(fill_bottom)]},
        "groups": [
            {
                "layers": [{"image-name": "graph.png", "name": "graph"}],
                "shadow": {"kind": "neutral", "opacity": 0.4},
                "translucency": {"enabled": True, "value": 0.4},
            }
        ],
        "supported-platforms": {"squares": "shared"},
    }
    (ICON_PACKAGE / "icon.json").write_text(json.dumps(icon, indent=2) + "\n")

    stale = ICON_PACKAGE / "Assets/background.png"
    if stale.exists():
        stale.unlink()
    print(f"wrote graph layer + icon.json to {ICON_PACKAGE.relative_to(ROOT)}"
          f" (gradient {srgb(fill_top)} -> {srgb(fill_bottom)})")


if __name__ == "__main__":
    main()
