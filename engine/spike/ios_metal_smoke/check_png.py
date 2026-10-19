#!/usr/bin/env python3
"""Check a simulator screenshot for the ios_metal_smoke frame.

Stdlib only (runs on the Mac's /usr/bin/python3, no Pillow). Decodes an 8-bit
RGB/RGBA PNG and reports how much of the screen is the expected orange fill
and the green middle-third rect that main.mm draws through Impeller.

Usage: check_png.py shot.png
Prints IOS_METAL_SMOKE_PASS (...) / IOS_METAL_SMOKE_FAIL (...), exit 0 / 1.
"""
import struct
import sys
import zlib

ORANGE = (255, 128, 0)
GREEN = (0, 192, 128)
TOL = 16  # per channel; covers encoder/color-space rounding, not a hue change


def decode_png(path):
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    pos, idat, meta = 8, [], []
    while pos < len(data):
        n, typ = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        pos += 12 + n
        if typ == b"IHDR":
            w, h, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", body)
        elif typ == b"IDAT":
            idat.append(body)
        elif typ in (b"sRGB", b"iCCP", b"cHRM", b"gAMA"):
            meta.append(typ.decode() + (":" + body.split(b"\0")[0].decode() if typ == b"iCCP" else ""))
        elif typ == b"IEND":
            break
    assert depth == 8 and ctype in (2, 6) and interlace == 0, (depth, ctype, interlace)
    bpp = 3 if ctype == 2 else 4
    raw = zlib.decompress(b"".join(idat))
    stride = w * bpp
    rows, prev = [], bytearray(stride)
    for y in range(h):
        f = raw[y * (stride + 1)]
        cur = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        if f == 1:
            for i in range(bpp, stride):
                cur[i] = (cur[i] + cur[i - bpp]) & 255
        elif f == 2:
            for i in range(stride):
                cur[i] = (cur[i] + prev[i]) & 255
        elif f == 3:
            for i in range(stride):
                left = cur[i - bpp] if i >= bpp else 0
                cur[i] = (cur[i] + ((left + prev[i]) >> 1)) & 255
        elif f == 4:
            for i in range(stride):
                a = cur[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                cur[i] = (cur[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(cur)
        prev = cur
    return w, h, bpp, rows, meta


def near(px, ref):
    return all(abs(px[k] - ref[k]) <= TOL for k in range(3))


def main():
    w, h, bpp, rows, meta = decode_png(sys.argv[1])
    n_or = n_gr = n = 0
    distinct = set()
    for y in range(0, h, 2):           # every 2nd pixel each way: plenty for fractions
        r = rows[y]
        for x in range(0, w, 2):
            px = tuple(r[x * bpp:x * bpp + 3])
            n += 1
            n_or += near(px, ORANGE)
            n_gr += near(px, GREEN)
            distinct.add(px)
    center = tuple(rows[h // 2][(w // 2) * bpp:(w // 2) * bpp + 3])
    corner = tuple(rows[h // 10][(w // 10) * bpp:(w // 10) * bpp + 3])
    f_or, f_gr = n_or / n, n_gr / n
    # Expected: orange 8/9 (88.9%), green 1/9 (11.1%), center green, corner orange.
    ok = f_or >= 0.80 and 0.08 <= f_gr <= 0.15 and near(center, GREEN) and near(corner, ORANGE)
    tag = "IOS_METAL_SMOKE_PASS" if ok else "IOS_METAL_SMOKE_FAIL"
    print("%s (%dx%d orange=%.1f%% green=%.1f%% center=%s corner=%s distinct_colors=%d png_color=%s)"
          % (tag, w, h, 100 * f_or, 100 * f_gr, center, corner, len(distinct), ",".join(meta) or "none"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
