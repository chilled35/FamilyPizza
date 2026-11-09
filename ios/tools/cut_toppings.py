#!/usr/bin/env python3
"""Cut the topping photos in "Food Images/" into sets of single pieces for the pizza picture.

Each source image holds a few separate pieces of one topping (or, for the two collection
sheets, a grid of tiles with a few pieces of each topping). This script:
  1. removes the background: real transparency where the PNG has it, otherwise the light
     grey/white "checkerboard" that image generators paint in place of transparency;
  2. finds each separate piece (connected opaque area);
  3. trims each piece and scales it to at most PIECE_PX on its longest side, into a named
     set (pepperoni, basil, chicken-harissa, ...; at most MAX_PER_SET used per set).

The app doesn't bundle the pieces: seed_server_pieces.py uploads each topping's set to the
server, and the app gets them from there. Run this on its own to check the cutting by eye:

    cd ios && python3 tools/cut_toppings.py [contact-sheet.png]

The cutting is in server/topping_pieces.py, shared with the server (which cuts the pieces
sheets the owner uploads in /admin the same way). Needs Pillow (pip install Pillow).
Writes a contact sheet of every piece on a sauce-red ground to /tmp/topping_pieces.png
(or the path given as the first argument) for checking by eye.
"""
from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
# The cutting itself is shared with the server, which cuts the owner's pieces sheets the same way.
sys.path.insert(0, str(ROOT / "server"))
import topping_pieces as shared  # noqa: E402
from topping_pieces import HOLES, PIECE_PX, WORK_PX, pieces  # noqa: E402

SOURCES = ROOT / "Food Images"

# PIECE_PX, WORK_PX, HOLES and the piece-finding thresholds live in server/topping_pieces.py.
SHEET_PX = 1600       # collection sheets keep full size (their pieces are small)
MAX_PER_SET = shared.MAX_PIECES  # keeps the app small; singles first, then the collection sheets

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


def cut_out(path: Path, topping_at, size: int = WORK_PX) -> Image.Image:
    """The image with a clean alpha channel, scaled to `size`.
    `topping_at(x, y)` (fractions of the image) names the topping there, for HOLES."""
    im = Image.open(path)
    im.thumbnail((size, size), Image.LANCZOS)
    return shared.cut_out(im, lambda x, y: HOLES.get(topping_at(x, y)))


def looks_green(piece: Image.Image) -> bool:
    """A green olive among black ones."""
    r = g = b = n = 0
    for (pr, pg, pb, pa) in piece.get_flattened_data():
        if pa > 200:
            r, g, b, n = r + pr, g + pg, b + pb, n + 1
    return n > 0 and g / n > 90  # black and kalamata olives are much darker


def cut_sets() -> dict[str, list[Image.Image]]:
    """Every set's pieces, in order (singles first, then the collection sheets), uncapped.
    Also used by seed_server_pieces.py."""
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
    return sets


def main() -> None:
    sets = cut_sets()
    for name, found in sorted(sets.items()):
        print(f"{name}: {min(len(found), MAX_PER_SET)} pieces (of {len(found)})")

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
