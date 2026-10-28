#!/usr/bin/env python3
"""mkregress.py -- hand-built hostile fonts for tools/fuzz/regress/font.

No fontTools needed: a minimal TrueType file is a table directory plus
head, hhea, maxp, hmtx, cmap, loca and glyf, about 400 bytes. The
committed outputs are what regress.sh runs; this script is how they
were made, and how to make another.

    python3 tools/fuzz/mkregress.py
"""
import os
import struct

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "regress", "font")


def sfnt(tables):
    n = len(tables)
    out = struct.pack(">IHHHH", 0x00010000, n, 0, 0, 0)
    off = 12 + 16 * n
    body = b""
    for tag, data in sorted(tables.items()):
        pad = data + b"\0" * (-len(data) % 4)
        out += tag.encode() + struct.pack(">III", 0, off + len(body), len(data))
        body += pad
    return out + body


def font(glyphs):
    """glyphs: list of glyf blobs; every code point 0..255 maps to glyph 1."""
    head = bytearray(54)
    struct.pack_into(">I", head, 12, 0x5F0F3CF5)
    struct.pack_into(">H", head, 18, 1000)          # unitsPerEm
    struct.pack_into(">h", head, 50, 1)             # long loca
    hhea = bytearray(36)
    struct.pack_into(">hhh", hhea, 4, 800, -200, 0)
    struct.pack_into(">H", hhea, 34, 1)
    maxp = struct.pack(">IH", 0x00010000, len(glyphs))
    hmtx = struct.pack(">Hh", 500, 0)
    cmap = struct.pack(">HHHHI", 0, 1, 0, 3, 12)    # platform 0 (Unicode BMP), format 0
    cmap += struct.pack(">HHH", 0, 262, 0) + bytes([1] * 256)
    glyf, loca = b"", b""
    for g in glyphs:
        loca += struct.pack(">I", len(glyf))
        glyf += g + b"\0" * (-len(g) % 4)
    loca += struct.pack(">I", len(glyf))
    return sfnt({"head": bytes(head), "hhea": bytes(hhea), "maxp": maxp,
                 "hmtx": hmtx, "cmap": cmap, "loca": loca, "glyf": glyf})


def composite(refs):
    """A composite glyph made of whole-glyph references, MORE_COMPONENTS set
    on all but the last. Flags 0x0002 = ARGS_ARE_XY_VALUES, byte arguments."""
    g = struct.pack(">hhhhh", -1, 0, 0, 100, 100)
    for i, idx in enumerate(refs):
        more = 0x0020 if i < len(refs) - 1 else 0
        g += struct.pack(">HHbb", 0x0002 | more, idx, 1, 1)
    return g


def main():
    os.makedirs(OUT, exist_ok=True)
    # Glyph 1 is 64 references to itself. Nothing it draws has any
    # points, so no size limit ever stops it: depth 6 of 64 calls each is
    # 64**6 (about 7e10) visits to draw one letter.
    with open(os.path.join(OUT, "composite-self.ttf"), "wb") as f:
        f.write(font([b"", composite([1] * 64)]))
    # Two glyphs referring to each other, 32 times each: the same, wider.
    with open(os.path.join(OUT, "composite-pair.ttf"), "wb") as f:
        f.write(font([b"", composite([2] * 32), composite([1] * 32)]))


if __name__ == "__main__":
    main()
