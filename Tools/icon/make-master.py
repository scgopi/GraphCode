#!/usr/bin/env python3
"""Draw the master icon artwork from the design spec's numbers.

`icon-master-1024.png` used to be a hand-produced PNG that nothing could regenerate —
so every adjustment was a round trip through an image editor and the numbers behind it
lived nowhere. This draws it, which means the spec *is* the source and a change is a
diff rather than a re-export.

All coordinates are on the 1024 canvas, taken from the handoff's "App icon" section:

- Body 824x824 at (100,100), radius 185.4.
- Mark bounding box 556x560 at (232,228) — 68% of the body. The previous artwork ran
  ~79% and pressed the top-right node against the glass; this ratio change is most of
  what reads as "more polished".
- Nodes r 88 at (320,316) - (700,372) - (320,640) - (620,700); the top-left one — the
  entry — carries the aqua gradient. One coloured node is the whole Dock-identity fix:
  at 16 px it is the only thing still identifying the app.
- Five edges, stroke 40, round caps, drawn under the nodes, with a user-space gradient
  from (243,284) to (777,732).

Two things that are deliberate rather than incidental:

- The nodes' outer white glow is gone, replaced by a drop shadow (dy 12, blur 14,
  black .42). The glow bloomed at 32 px and turned the mark into three grey blobs.
- Every gradient here is evaluated in *user space*. An object-bounding-box gradient on
  a vertical stroke has a zero-width box and silently doesn't paint, which is why the
  left edge vanished in the first mock.

Usage:
    python3 Tools/icon/make-master.py
    python3 Tools/icon/make-master.py --out /tmp/preview.png
"""

import argparse
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

HERE = Path(__file__).resolve().parent
OUT = HERE / "icon-master-1024.png"
SMALL_OUT = HERE / "icon-master-small-1024.png"

CANVAS = 1024
SS = 4  # supersample factor; every coordinate below is multiplied by this

BODY_XY = (100, 100)
BODY_SIZE = 824
BODY_RADIUS = 185.4

NODES = [(320, 316), (700, 372), (320, 640), (620, 700)]
NODE_RADIUS = 88
ACCENT_NODE = 0
EDGES = [(0, 1), (0, 2), (0, 3), (1, 3), (2, 3)]
EDGE_STROKE = 40
EDGE_GRADIENT = ((243, 284), (777, 732))

# The 16 and 32 px renders come from a simplified three-node variant: below ~48 px the
# four-node graph mushes into noise, with the edges thinning to sub-pixel. Radii and
# stroke are chosen so a node stays ~2.5 px across and a stroke ~1 px at 16.
#
# It is *drawn*, not derived from the full master. It used to be recovered by
# interpolating the tile's gradient across the artwork, which assumed the gradient was
# vertical — against this master's diagonal lighting that leaves visible bands, and it
# also threw away the one thing the small size most needs: the accent node.
SMALL_NODES = [(500, 330), (322, 664), (688, 652)]
SMALL_RADII = [132, 116, 122]
SMALL_EDGES = [(0, 1), (0, 2), (1, 2)]
SMALL_EDGE_STROKE = 62

SHADOW_DY = 12
SHADOW_BLUR = 14
SHADOW_ALPHA = 0.42


def hex_rgb(value: str) -> tuple[float, float, float]:
    value = value.lstrip("#")
    return tuple(int(value[i : i + 2], 16) / 255.0 for i in (0, 2, 4))


def ramp(stops: list[tuple[float, tuple[float, float, float]]], t: np.ndarray) -> np.ndarray:
    """Interpolate a multi-stop colour ramp over `t` (already clamped to 0...1)."""
    out = np.zeros(t.shape + (3,), dtype=np.float32)
    for index in range(len(stops) - 1):
        (t0, c0), (t1, c1) = stops[index], stops[index + 1]
        span = max(t1 - t0, 1e-6)
        local = np.clip((t - t0) / span, 0.0, 1.0)
        segment = (index == 0) | (t >= t0)
        for channel in range(3):
            value = c0[channel] + (c1[channel] - c0[channel]) * local
            out[..., channel] = np.where(segment, value, out[..., channel])
    return out


def linear_t(size: int, start: tuple[float, float], end: tuple[float, float]) -> np.ndarray:
    """Projection of every pixel onto the start->end axis, in user space."""
    ys, xs = np.mgrid[0:size, 0:size].astype(np.float32)
    dx, dy = end[0] - start[0], end[1] - start[1]
    denominator = dx * dx + dy * dy
    return np.clip(((xs - start[0]) * dx + (ys - start[1]) * dy) / denominator, 0.0, 1.0)


def radial_t(
    size: int, centre: tuple[float, float], radius: float
) -> np.ndarray:
    ys, xs = np.mgrid[0:size, 0:size].astype(np.float32)
    return np.clip(np.hypot(xs - centre[0], ys - centre[1]) / radius, 0.0, 1.0)


def mask(size: int, draw_fn) -> np.ndarray:
    layer = Image.new("L", (size, size), 0)
    draw_fn(ImageDraw.Draw(layer))
    return np.asarray(layer, dtype=np.float32) / 255.0


def over(base: np.ndarray, colour: np.ndarray, alpha: np.ndarray) -> np.ndarray:
    """Source-over composite in straight alpha, colour only (alpha tracked separately)."""
    return base * (1 - alpha[..., None]) + colour * alpha[..., None]


def build(size: int, small: bool = False) -> Image.Image:
    nodes = SMALL_NODES if small else NODES
    radii = SMALL_RADII if small else [NODE_RADIUS] * len(NODES)
    edges = SMALL_EDGES if small else EDGES
    stroke = SMALL_EDGE_STROKE if small else EDGE_STROKE
    scale = size / CANVAS

    def s(value: float) -> float:
        return value * scale

    body_box = (
        s(BODY_XY[0]),
        s(BODY_XY[1]),
        s(BODY_XY[0] + BODY_SIZE),
        s(BODY_XY[1] + BODY_SIZE),
    )
    body_mask = mask(
        size, lambda d: d.rounded_rectangle(body_box, radius=s(BODY_RADIUS), fill=255)
    )

    # 1 — the body's own gradient, lit from the upper left.
    axis = linear_t(size, (s(0.18 * CANVAS), 0), (s(0.6 * CANVAS), size))
    rgb = ramp(
        [(0.0, hex_rgb("#3E3E47")), (0.52, hex_rgb("#26262C")), (1.0, hex_rgb("#17171B"))],
        axis,
    )

    # 2 — the hotspot. A soft highlight, not a shape: it is what keeps the tile from
    # reading as flat paint at large sizes.
    hotspot = 1.0 - radial_t(size, (s(0.42 * CANVAS), s(0.32 * CANVAS)), s(0.68 * CANVAS))
    rgb = over(rgb, np.ones_like(rgb), hotspot * 0.09)

    # 3 — edges, under the nodes, with the gradient evaluated in user space.
    edge_mask = mask(
        size,
        lambda d: [
            d.line(
                [s(nodes[a][0]), s(nodes[a][1]), s(nodes[b][0]), s(nodes[b][1])],
                fill=255,
                width=int(round(s(stroke))),
                joint="curve",
            )
            for a, b in edges
        ],
    )
    # Round caps: PIL has none, so the ends get a disc of the stroke's own radius.
    cap_mask = mask(
        size,
        lambda d: [
            d.ellipse(
                [
                    s(nodes[i][0]) - s(stroke) / 2,
                    s(nodes[i][1]) - s(stroke) / 2,
                    s(nodes[i][0]) + s(stroke) / 2,
                    s(nodes[i][1]) + s(stroke) / 2,
                ],
                fill=255,
            )
            for i in range(len(nodes))
        ],
    )
    edges = np.clip(edge_mask + cap_mask, 0, 1)
    edge_axis = linear_t(
        size,
        (s(EDGE_GRADIENT[0][0]), s(EDGE_GRADIENT[0][1])),
        (s(EDGE_GRADIENT[1][0]), s(EDGE_GRADIENT[1][1])),
    )
    edge_alpha = edges * (0.5 + (0.26 - 0.5) * edge_axis)
    rgb = over(rgb, np.ones_like(rgb), edge_alpha)

    # 4 — the nodes' shadow. This is what replaced the outer white glow.
    node_mask = mask(
        size,
        lambda d: [
            d.ellipse(
                [
                    s(x) - s(radii[i]),
                    s(y) - s(radii[i]),
                    s(x) + s(radii[i]),
                    s(y) + s(radii[i]),
                ],
                fill=255,
            )
            for i, (x, y) in enumerate(nodes)
        ],
    )
    shadow = Image.fromarray((node_mask * 255).astype(np.uint8))
    shadow = shadow.transform(
        (size, size), Image.AFFINE, (1, 0, 0, 0, 1, -s(SHADOW_DY)), resample=Image.BILINEAR
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(s(SHADOW_BLUR)))
    shadow_alpha = (np.asarray(shadow, dtype=np.float32) / 255.0) * SHADOW_ALPHA
    rgb = over(rgb, np.zeros_like(rgb), shadow_alpha)

    # 5 — the nodes themselves, each with its own radial gradient. One is the accent.
    for index, (x, y) in enumerate(nodes):
        radius = radii[index]
        disc = mask(
            size,
            lambda d, x=x, y=y, r=radius: d.ellipse(
                [s(x) - s(r), s(y) - s(r), s(x) + s(r), s(y) + s(r)],
                fill=255,
            ),
        )
        centre = (s(x - radius * 0.32), s(y - radius * 0.48))
        t = radial_t(size, centre, s(radius * 1.7))
        stops = (
            [(0.0, hex_rgb("#4FE3AC")), (0.55, hex_rgb("#22B681")), (1.0, hex_rgb("#0F7A55"))]
            if index == ACCENT_NODE
            else [
                (0.0, hex_rgb("#FFFFFF")),
                (0.55, hex_rgb("#F2F2F6")),
                (1.0, hex_rgb("#D2D2DC")),
            ]
        )
        rgb = over(rgb, ramp(stops, t), disc)

    # 6 — the rim. A specular top edge and a dark bottom edge are what make it read as
    # glass rather than as a rounded rectangle.
    inset = s(1)
    rim_outer = mask(
        size,
        lambda d: d.rounded_rectangle(
            (
                body_box[0] + inset,
                body_box[1] + inset,
                body_box[2] - inset,
                body_box[3] - inset,
            ),
            radius=s(BODY_RADIUS) - inset,
            outline=255,
            width=max(int(round(s(2))), 1),
        ),
    )
    vertical = np.clip((np.mgrid[0:size, 0:size][0].astype(np.float32) - body_box[1])
                       / max(body_box[3] - body_box[1], 1), 0.0, 1.0)
    rim_white = np.clip(0.22 + (0.05 - 0.22) * (vertical / 0.45), 0.0, 0.22)
    rim_black = np.clip((vertical - 0.45) / 0.55, 0.0, 1.0) * 0.30
    rgb = over(rgb, np.ones_like(rgb), rim_outer * np.where(vertical < 0.45, rim_white, 0))
    rgb = over(rgb, np.zeros_like(rgb), rim_outer * rim_black)

    out = np.zeros(rgb.shape[:2] + (4,), dtype=np.uint8)
    out[..., :3] = np.clip(rgb * 255.0, 0, 255).astype(np.uint8)
    out[..., 3] = np.clip(body_mask * 255.0, 0, 255).astype(np.uint8)
    return Image.fromarray(out, mode="RGBA")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path)
    parser.add_argument(
        "--variant", choices=["full", "small", "both"], default="both",
        help="which master to draw; `both` writes the pair the render step expects")
    args = parser.parse_args()

    wanted = ["full", "small"] if args.variant == "both" else [args.variant]
    for variant in wanted:
        small = variant == "small"
        destination = args.out or (SMALL_OUT if small else OUT)
        image = build(CANVAS * SS, small=small).resize((CANVAS, CANVAS), Image.LANCZOS)
        image.save(destination)
        print(f"wrote {destination}")


if __name__ == "__main__":
    main()
