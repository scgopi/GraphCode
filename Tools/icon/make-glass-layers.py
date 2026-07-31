#!/usr/bin/env python3
"""Derive the Liquid Glass icon layers from the master artwork.

`graphcode/Resources/AppIcon.icon` is the Icon Composer package macOS 26+ renders
with glass depth; the appiconset stays as the fallback for older systems. Its two
image layers are derived from the same master as everything else:

- `background.png` — the tile gradient with the artwork inpainted out, cropped past
  the squircle corners and stretched to a full-bleed square (the system applies its
  own mask), then darkened with the render pipeline's darken() at the same factor as
  the appiconset so the two renditions can't drift apart.
- `graph.png` — the graph alone, alpha-matted, with no baked glow: the glass effect
  supplies depth and specular, and a baked halo would double up against it.

Usage:
    python3 Tools/icon/make-glass-layers.py
"""

import importlib.util
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
ICON_PACKAGE = ROOT / "graphcode/Resources/AppIcon.icon"


def load(name: str):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), HERE / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

render = load("render-appicon")
small = load("make-small-master")


def main() -> None:
    master = Image.open(HERE / "icon-master-1024.png").convert("RGBA")
    px = np.asarray(master, dtype=np.float32)
    luma = (0.2126 * px[..., 0] + 0.7152 * px[..., 1] + 0.0722 * px[..., 2]) / 255.0
    inside = px[..., 3] > 240

    # graph.png: artwork pixels matted onto transparency, edges antialiased
    mask = ((luma > 0.42) & inside).astype(np.uint8) * 255
    mask_im = Image.fromarray(mask).filter(ImageFilter.MaxFilter(3)).filter(ImageFilter.GaussianBlur(1.2))
    fg = np.dstack([px[..., :3], np.asarray(mask_im, dtype=np.float32)])
    Image.fromarray(fg.astype(np.uint8), "RGBA").save(ICON_PACKAGE / "Assets/graph.png")

    # background.png: inpainted tile interior stretched to full bleed, then darkened
    tile = small.recover_tile(master)
    tpx = np.asarray(tile)
    ys, xs = np.where(tpx[..., 3] > 240)
    inset = 60  # past the squircle corner radius, so no corner falloff is sampled
    interior = tile.crop((xs.min() + inset, ys.min() + inset, xs.max() - inset, ys.max() - inset))
    bg = interior.resize((1024, 1024), Image.LANCZOS).convert("RGBA")
    bg = render.darken(bg, render.DEFAULT_DARKEN).convert("RGB").convert("RGBA")
    bg.save(ICON_PACKAGE / "Assets/background.png")
    print(f"wrote 2 layers to {ICON_PACKAGE.relative_to(ROOT)}/Assets")


if __name__ == "__main__":
    main()
