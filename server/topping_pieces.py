"""Cut a sheet of topping pieces into single pieces for the app's pizza picture.

A "pieces sheet" is an image holding a few separate pieces of one topping (pepperoni slices,
basil leaves, ...) on real transparency or on a plain white / light-grey background (or the
grey-and-white checkerboard image generators paint in place of transparency). Cutting it:
  1. clears the background: real transparency is kept as it is; otherwise light, colourless
     areas that touch the edge of the image (and, for toppings with holes, large enclosed
     ones) become transparent;
  2. finds each separate opaque area (one piece each);
  3. trims each piece and scales it to at most PIECE_PX on its longest side.

Shared by the server (owner uploads a sheet in /admin, see main.py) and by
ios/tools/cut_toppings.py (cuts the photos in "Food Images/" for seeding the server). Needs Pillow only.
"""
from __future__ import annotations

import io
from collections import deque
from typing import Callable

from PIL import Image, ImageFilter, ImageOps

PIECE_PX = 144        # longest side of a saved piece (drawn at ~20-45 pt, so about 3x)
WORK_PX = 900         # a single-topping sheet is scaled down to this before cutting
MAX_PIECES = 12       # pieces kept per topping (keeps the app and the API small)
MIN_PIECE = 0.004     # a piece must cover this fraction of the (scaled) image
# Enclosed background is a hole (cleared) only in these toppings, and only when it covers at
# least this fraction of the image: elsewhere pale flesh (onion, mushroom) would be cut away.
# Keyed by the app's topping style (main.TOPPING_STYLES) / the cut_toppings.py set name.
HOLES = {"chilli": 0.00004, "olive": 0.00004, "onion": 0.0004}

# Server-side guard against huge or hostile uploads (decompression bombs).
MAX_SOURCE_PIXELS = 4096 * 4096


class SheetError(ValueError):
    """The upload is not a usable pieces sheet (message is shown to the owner)."""


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


def cut_out(im: Image.Image, hole_at: Callable[[float, float], float | None] = lambda x, y: None) -> Image.Image:
    """The image with a clean alpha channel (already scaled to working size).
    `hole_at(x, y)` (fractions of the image) gives the minimum hole size (a fraction of the
    image, see HOLES) for the topping there, or None where enclosed background is not a hole."""
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
            min_hole = hole_at((i % w) / w, (i // w) / h)
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


def pieces(im: Image.Image, piece_px: int = PIECE_PX) -> list[tuple[Image.Image, tuple[float, float]]]:
    """Each separate piece, trimmed and scaled, with its centre (fractions of the image),
    in reading order (rows, then left to right)."""
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
        piece.thumbnail((piece_px, piece_px), Image.LANCZOS)
        found.append((piece, ((box[0] + box[2]) / 2 / w, (box[1] + box[3]) / 2 / h)))
    found.sort(key=lambda f: (round(f[1][1] * 4), f[1][0]))  # rows, then left to right
    return found


def png_bytes(piece: Image.Image) -> bytes:
    buf = io.BytesIO()
    piece.save(buf, format="PNG", optimize=True)
    return buf.getvalue()


def cut_sheet(data: bytes, style: str = "generic") -> list[bytes]:
    """Cut an uploaded sheet (PNG/JPEG/WebP bytes) into at most MAX_PIECES PNG pieces.
    `style` is the topping's drawing style; it decides whether enclosed background is a hole.
    Raises SheetError when the image can't be read or has no separate pieces."""
    try:
        im = Image.open(io.BytesIO(data))
        if im.width * im.height > MAX_SOURCE_PIXELS:
            raise SheetError(f"Image too large ({im.width}x{im.height}); at most 4096x4096")
        im = ImageOps.exif_transpose(im)
        im.load()
    except SheetError:
        raise
    except Exception as e:  # Pillow raises many kinds for broken files
        raise SheetError("Couldn't read that image") from e
    if im.mode not in ("RGB", "RGBA"):
        im = im.convert("RGBA" if "A" in im.getbands() or "transparency" in im.info else "RGB")
    im.thumbnail((WORK_PX, WORK_PX), Image.LANCZOS)
    min_hole = HOLES.get(style)
    found = pieces(cut_out(im, lambda x, y: min_hole))
    if not found:
        raise SheetError("No separate pieces found: use a transparent or plain white/light-grey "
                         "background with a gap around each piece")
    return [png_bytes(piece) for piece, _ in found[:MAX_PIECES]]
