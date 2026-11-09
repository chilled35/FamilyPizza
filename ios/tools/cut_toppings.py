#!/usr/bin/env python3
"""Cut the topping photos in "Food Images/" into single pieces for the pizza picture.

Each source image holds a few separate pieces of one topping (or, for the two collection
sheets, a grid of tiles with a few pieces of each topping). This script:
  1. removes the background: real transparency where the PNG has it, otherwise the light
     grey/white "checkerboard" that image generators paint in place of transparency;
  2. finds each separate piece (connected opaque area);
  3. writes each piece, trimmed and scaled to at most PIECE_PX on its longest side, into
     the app's asset catalog as `piece-<set>-<nn>` (FamilyPizza/Assets.xcassets/Toppings).

The app finds pieces by name (ToppingPieces.swift), so adding or removing images here needs no
code change. Re-run after changing the sources:

    cd ios && python3 tools/cut_toppings.py

Needs Pillow (pip install Pillow). Writes a contact sheet of every piece on a sauce-red ground
to /tmp/topping_pieces.png (or the path given as the first argument) for checking by eye.
"""
from __future__ import annotations

import json
import shutil
import sys
from collections import deque
from pathlib import Path

from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "Food Images"
OUT = ROOT / "ios" / "FamilyPizza" / "Assets.xcassets" / "Toppings"

PIECE_PX = 144        # longest side of a saved piece (drawn at ~20-45 pt, so about 3x)
WORK_PX = 900         # single-topping sources are scaled down to this before cutting
SHEET_PX = 1600       # collection sheets keep full size (their pieces are small)
MAX_PER_SET = 12      # keeps the app small; singles first, then the collection sheets
MIN_PIECE = 0.004     # a piece must cover this fraction of the (scaled) image
# Enclosed background is a hole (cleared) only in these toppings, and only when it covers at
# least this fraction of the image: elsewhere pale flesh (onion, mushroom) would be cut away.
HOLES = {"chilli": 0.00004, "olive": 0.00004, "onion": 0.0004}

# (file, set)
SINGLES = [
    ("Four Glossy Pepperoni Slices-1.png", "pepperoni"),
    ("Photorealistic Pepperoni Slices Grid-3.png", "pepperoni"),
    ("Glossy Ham Slices Grid-5.png", "ham"),
    ("Four Glossy Ham Slices-6.png", "ham"),
    ("Four Sliced Mushrooms on Transparent Background-7.png", "mushroom"),
    ("Four Glossy Mushroom Slices-8.png", "mushroom"),
    ("Four Purple-Red Onion Slices-9.png", "onion"),
    ("Glossy Purple Onion Slices-10.png", "onion"),
    ("Glossy Bell Pepper Slice Grid-11.png", "pepper"),
    ("Glossy Bell Pepper Slices Grid-12.png", "pepper"),
    ("Glossy Pineapple Chunks Grid-13.png", "pineapple"),
    ("Four Glossy Pineapple Chunks-14.png", "pineapple"),
    ("Glossy Red Chili Slices Grid-1.png", "chilli"),
    ("Four Glossy Olive Rings-2.png", "olive"),
    ("Four Glossy Basil Leaves-3.png", "basil"),
    ("Glossy Yellow Corn Kernels Grid-4.png", "sweetcorn"),
    ("Juicy Sliced Tomato Quartet-5.png", "tomato"),
    ("Four Photorealistic Sausage Pieces-6.png", "sausage"),
    ("Glazed Chipotle Chicken Pieces-1.png", "chicken-chipotle"),
    ("Spicy Harissa-Grilled Chicken Pieces-2.png", "chicken-harissa"),
]

ROW1 = ["pepperoni", "ham", "mushroom", "onion", "pepper"]
ROW2 = ["pineapple", "chilli", "olive", "basil", "sweetcorn"]
# (file, [(row top, row bottom as fractions of height, tiles left to right; None = empty)])
SHEETS = [
    ("Pizza Topping Sprite Sheet Collection-2.png", [
        (0.00, 0.33, ROW1), (0.33, 0.65, ROW2),
        (0.65, 1.00, ["tomato", "sausage", "chicken-chipotle", "chicken-harissa"]),
    ]),
    ("Photorealistic Pizza Topping Tile Collection-4.png", [
        (0.00, 0.33, ROW1), (0.33, 0.65, ROW2),
        (0.65, 1.00, ["tomato", "sausage", "chicken-chipotle", "chicken-harissa", None]),
    ]),
]


def is_backdrop(p: tuple[int, int, int]) -> bool:
    """White or light grey with no colour: the painted checkerboard."""
    lo, hi = min(p), max(p)
    return lo > 200 and hi - lo < 18


def components(mask: bytearray, w: int, h: int) -> list[list[int]]:
    """4-connected areas of set pixels, as lists of flat indices."""
    seen = bytearray(w * h)
    out = []
    for start in range(w * h):
        if not mask[start] or seen[start]:
            continue
        seen[start] = 1
        q, area = deque([start]), []
        while q:
            i = q.popleft()
            area.append(i)
            x = i % w
            for j in (i + 1 if x + 1 < w else -1, i - 1 if x > 0 else -1, i + w, i - w):
                if 0 <= j < w * h and mask[j] and not seen[j]:
                    seen[j] = 1
                    q.append(j)
        out.append(area)
    return out


def cut_out(path: Path, topping_at, size: int = WORK_PX) -> Image.Image:
    """The image with a clean alpha channel, scaled to `size`.
    `topping_at(x, y)` (fractions of the image) names the topping there, for HOLES."""
    im = Image.open(path)
    im.thumbnail((size, size), Image.LANCZOS)
    if im.mode == "RGBA" and im.getchannel("A").getextrema()[0] < 20:
        return im  # real transparency
    rgb = im.convert("RGB")
    w, h = rgb.size
    px = rgb.load()
    backdrop = bytearray(1 if is_backdrop(px[i % w, i // w]) else 0 for i in range(w * h))
    alpha = bytearray([255]) * (w * h)
    for area in components(backdrop, w, h):
        touches_edge = any(i % w in (0, w - 1) or i // w in (0, h - 1) for i in area)
        if not touches_edge:
            i = area[len(area) // 2]
            min_hole = HOLES.get(topping_at((i % w) / w, (i // w) / h))
            touches_edge = min_hole is not None and len(area) >= min_hole * w * h
        if touches_edge:
            for i in area:
                alpha[i] = 0
    mask = Image.frombytes("L", (w, h), bytes(alpha))
    # Pull the edge in a pixel (drops the light fringe), then soften it.
    mask = mask.filter(ImageFilter.MinFilter(3)).filter(ImageFilter.GaussianBlur(0.8))
    out = rgb.convert("RGBA")
    out.putalpha(mask)
    return out


def pieces(im: Image.Image) -> list[tuple[Image.Image, tuple[float, float]]]:
    """Each separate piece, trimmed, with its centre (fractions of the image)."""
    w, h = im.size
    a = im.getchannel("A").tobytes()
    solid = bytearray(1 if v >= 100 else 0 for v in a)
    found = []
    for area in components(solid, w, h):
        if len(area) < MIN_PIECE * w * h:
            continue
        xs = [i % w for i in area]
        ys = [i // w for i in area]
        pad = 4
        box = (max(0, min(xs) - pad), max(0, min(ys) - pad), min(w, max(xs) + pad + 1), min(h, max(ys) + pad + 1))
        # Keep only this piece's pixels (plus its soft edge), not a neighbour poking into the box.
        keep = Image.new("L", (w, h), 0)
        kp = keep.load()
        for i in area:
            kp[i % w, i // w] = 255
        keep = keep.filter(ImageFilter.MaxFilter(5))
        piece = im.copy()
        piece.putalpha(Image.composite(im.getchannel("A"), Image.new("L", (w, h), 0), keep))
        piece = piece.crop(box)
        piece.thumbnail((PIECE_PX, PIECE_PX), Image.LANCZOS)
        found.append((piece, ((box[0] + box[2]) / 2 / w, (box[1] + box[3]) / 2 / h)))
    found.sort(key=lambda f: (round(f[1][1] * 4), f[1][0]))  # rows, then left to right
    return found


def looks_green(piece: Image.Image) -> bool:
    """A green olive among black ones."""
    r = g = b = n = 0
    for (pr, pg, pb, pa) in piece.get_flattened_data():
        if pa > 200:
            r, g, b, n = r + pr, g + pg, b + pb, n + 1
    return n > 0 and g / n > 90  # black and kalamata olives are much darker


def main() -> None:
    sets: dict[str, list[Image.Image]] = {}

    def add(name: str, piece: Image.Image) -> None:
        if name == "olive" and looks_green(piece):
            return
        sets.setdefault(name, []).append(piece)

    for file, name in SINGLES:
        for piece, _ in pieces(cut_out(SOURCES / file, lambda x, y, name=name: name)):
            add(name, piece)
        print(f"{file}: {name} -> {len(sets.get(name, []))}")
    for file, rows in SHEETS:
        def tile(x: float, y: float, rows=rows) -> str | None:
            for top, bottom, tiles in rows:
                if top <= y < bottom:
                    return tiles[min(int(x * len(tiles)), len(tiles) - 1)]
            return None

        im = cut_out(SOURCES / file, tile, size=SHEET_PX)
        for piece, (cx, cy) in pieces(im):
            if name := tile(cx, cy):
                add(name, piece)
        print(f"{file}: done")

    if OUT.exists():
        shutil.rmtree(OUT)
    OUT.mkdir(parents=True)
    (OUT / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    total = 0
    all_pieces = []
    for name, found in sorted(sets.items()):
        for n, piece in enumerate(found[:MAX_PER_SET], start=1):
            asset = f"piece-{name}-{n:02d}"
            folder = OUT / f"{asset}.imageset"
            folder.mkdir()
            piece.save(folder / f"{asset}.png", optimize=True)
            total += (folder / f"{asset}.png").stat().st_size
            (folder / "Contents.json").write_text(json.dumps({
                "images": [{"filename": f"{asset}.png", "idiom": "universal"}],
                "info": {"author": "xcode", "version": 1},
                # Photos: lossy compression in the built app keeps the download small.
                "properties": {"compression-type": "lossy"},
            }, indent=2) + "\n")
            all_pieces.append(piece)
        print(f"{name}: {min(len(found), MAX_PER_SET)} pieces (of {len(found)})")
    print(f"{len(all_pieces)} pieces, {total / 1e6:.1f} MB")

    # Contact sheet for checking by eye.
    cell, cols = PIECE_PX + 8, 12
    rows_n = sum((min(len(f), MAX_PER_SET) + cols - 1) // cols for f in sets.values())
    sheet = Image.new("RGBA", (cell * cols, cell * rows_n), (176, 52, 32, 255))
    y = 0
    for name, found in sorted(sets.items()):
        for n, piece in enumerate(found[:MAX_PER_SET]):
            sheet.alpha_composite(piece, ((n % cols) * cell + 4, y + (n // cols) * cell + 4))
        y += ((min(len(found), MAX_PER_SET) + cols - 1) // cols) * cell
    sheet.convert("RGB").save(sys.argv[1] if len(sys.argv) > 1 else "/tmp/topping_pieces.png")


if __name__ == "__main__":
    main()
