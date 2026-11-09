#!/usr/bin/env python3
"""Give every topping on a server its pieces, from the photos in "Food Images/".

The server is where the app gets every topping's pieces (the owner uploads a pieces sheet in
/admin; the app bundles none). This seeds it: it cuts the sources with cut_toppings.py, picks
each server topping's set (its style, or for "generic"/"chicken" toppings a word in its name,
so "Harissa chicken" gets harissa chicken and a "Basil" left generic gets basil leaves), lays
that topping's pieces out on a transparent sheet with a gap around each, and uploads the sheet
through the admin API (PUT /api/admin/toppings/{id}/pieces), just as the owner would in /admin.
The server cuts it back into the same pieces.

Toppings that already have pieces are left alone (the owner may have uploaded their own),
unless --replace. Cheese and toppings that match no set get nothing.

    cd ios && python3 tools/seed_server_pieces.py http://127.0.0.1:8765 [--replace] [--dry-run]

Needs Pillow. Talks only to the server named on the command line.
"""
from __future__ import annotations

import argparse
import io
import json
import sys
import urllib.error
import urllib.request
from itertools import chain, zip_longest
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
from cut_toppings import MAX_PER_SET, PIECE_PX, cut_sets  # noqa: E402

# Name words, checked in order (first match wins), like guess_style in server/main.py.
NAME_WORDS = [
    ("harissa", ["chicken-harissa"]), ("chipotle", ["chicken-chipotle"]), ("chipolte", ["chicken-chipotle"]),
    ("chicken", ["chicken-chipotle", "chicken-harissa"]),
    ("pepperoni", ["pepperoni"]), ("salami", ["pepperoni"]), ("chorizo", ["pepperoni"]),
    ("ham", ["ham"]), ("bacon", ["ham"]),
    ("mushroom", ["mushroom"]), ("onion", ["onion"]), ("pineapple", ["pineapple"]),
    ("chilli", ["chilli"]), ("chili", ["chilli"]), ("jalape", ["chilli"]),
    ("pepper", ["pepper"]), ("olive", ["olive"]),
    ("basil", ["basil"]), ("spinach", ["basil"]), ("rocket", ["basil"]),
    ("sweetcorn", ["sweetcorn"]), ("corn", ["sweetcorn"]),
    ("tomato", ["tomato"]), ("sausage", ["sausage"]), ("meatball", ["sausage"]),
]


def sets_for_style(style: str) -> list[str]:
    if style == "chicken":
        return ["chicken-chipotle", "chicken-harissa"]
    if style in ("cheese", "generic"):
        return []  # cheese is drawn melted; generic has no set of its own
    return [style]


def sets_for(name: str, style: str) -> list[str]:
    # The owner's chosen style wins over a name guess, except to tell the chickens apart.
    if style not in ("generic", "chicken"):
        return sets_for_style(style)
    lower = name.lower()
    return next((found for word, found in NAME_WORDS if word in lower), sets_for_style(style))


def sheet_of(pieces: list[Image.Image]) -> bytes:
    """The pieces in a grid on transparency, a clear gap around each (the server finds each
    separate opaque area again)."""
    cols, cell = 4, PIECE_PX + 48
    rows = (len(pieces) + cols - 1) // cols
    sheet = Image.new("RGBA", (cols * cell, rows * cell), (0, 0, 0, 0))
    for i, piece in enumerate(pieces):
        x = (i % cols) * cell + (cell - piece.width) // 2
        y = (i // cols) * cell + (cell - piece.height) // 2
        sheet.alpha_composite(piece, (x, y))
    buf = io.BytesIO()
    sheet.save(buf, format="PNG", optimize=True)
    return buf.getvalue()


def request(method: str, url: str, body: bytes | None = None, content_type: str | None = None):
    req = urllib.request.Request(url, data=body, method=method)
    if content_type:
        req.add_header("Content-Type", content_type)
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("server", help="e.g. http://127.0.0.1:8765")
    ap.add_argument("--replace", action="store_true", help="also replace pieces a topping already has")
    ap.add_argument("--dry-run", action="store_true", help="say what would be uploaded, upload nothing")
    args = ap.parse_args()
    base = args.server.rstrip("/")

    toppings = request("GET", f"{base}/api/admin/toppings")
    sets = cut_sets()
    for t in toppings:
        names = sets_for(t["name"], t["style"])
        # Several sets (chicken): take from each in turn, so both kinds show.
        found = [p for p in chain.from_iterable(zip_longest(*(sets.get(n, []) for n in names))) if p]
        found = found[:MAX_PER_SET]
        label = f"{t['name']} ({t['style']})"
        if not found:
            print(f"{label}: no set for it in Food Images, skipped")
            continue
        if t.get("piece_urls") and not args.replace:
            print(f"{label}: already has {len(t['piece_urls'])} pieces, kept (use --replace)")
            continue
        if args.dry_run:
            print(f"{label}: would upload {len(found)} pieces from {', '.join(names)}")
            continue
        try:
            after = request("PUT", f"{base}/api/admin/toppings/{t['id']}/pieces", sheet_of(found), "image/png")
        except urllib.error.HTTPError as e:
            print(f"{label}: upload failed, {e.code} {e.read().decode(errors='replace')}")
            continue
        got = len(after["piece_urls"])
        print(f"{label}: {got} pieces from {', '.join(names)}" + ("" if got == len(found) else f" (sent {len(found)}!)"))


if __name__ == "__main__":
    main()
