#!/usr/bin/env python3
"""Image checks for the iOS simulator gates (stdlib only: the Mac's Python has no Pillow).

  ios_image_check.py rrect <img.ppm|png> X Y W H R
      A dark rounded rect (X,Y,W,H, corner radius R, pixels) on white. Prints
      `rrect colors=<n> corner_aa=<0|1> corner_partial=<a,b,c,d> corner_levels=<n>
      corner_px=<bg|ink> fill_ok=<0|1>`; exit 0 only when colors >= 5, corner_aa=1
      (every corner box carries >= R/2 partial-coverage pixels, >= 3 grey levels
      over all four), the corner pixel itself is background and centre/outside
      are ink/background (the same AA test tools/ci-metal.sh makes on darwin).
      Why 5 and not ci-metal.sh's 10: one grey shape on white under Impeller's
      4x MSAA has exactly 2 + 3 colors (ink, background, coverage 1/4, 2/4, 3/4;
      measured: readback colors=5, corner_levels=3). ci-metal.sh's 10 is for
      multi-colour fixtures. A plain rect has 2.
  ios_image_check.py smoke <img.png> <geometry.js> <scale>
      The iOS M1 fixture (fixtures/ios-smoke) as rendered: every box's (and child's)
      centre is its exact color (+-8 per channel), the rounded box's corner pixel is
      background, a background pixel is background, and the label band has ink.
      Prints `smoke box_rgb_match=<0|1> boxes=<ok>/<n> corner_bg=<0|1> bg_ok=<0|1>
      label_ink=<px> colors=<n>`; exit 0 only when all hold.
"""
MIN_COLORS = 5
import struct
import sys
import zlib


def read_ppm(path):
    data = open(path, "rb").read()
    parts, pos = [], 0
    while len(parts) < 4:  # P6 w h maxval, whitespace separated
        while data[pos:pos + 1].isspace():
            pos += 1
        start = pos
        while not data[pos:pos + 1].isspace():
            pos += 1
        parts.append(data[start:pos])
    assert parts[0] == b"P6" and parts[3] == b"255", parts
    w, h = int(parts[1]), int(parts[2])
    pix = data[pos + 1:pos + 1 + w * h * 3]
    rows = [pix[y * w * 3:(y + 1) * w * 3] for y in range(h)]
    return w, h, 3, rows


def read_png(path):
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    pos, idat, ihdr = 8, [], None
    while pos < len(data):
        n, typ = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        pos += 12 + n
        if typ == b"IHDR":
            ihdr = struct.unpack(">IIBBBBB", body)
        elif typ == b"IDAT":
            idat.append(body)
        elif typ == b"IEND":
            break
    w, h, depth, ctype, _, _, interlace = ihdr
    assert depth == 8 and ctype in (2, 6) and interlace == 0, ihdr
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
    return w, h, bpp, rows


def read_image(path):
    return read_png(path) if path.endswith(".png") else read_ppm(path)


def px(img, x, y):
    w, h, bpp, rows = img
    r = rows[y]
    return tuple(r[x * bpp:x * bpp + 3])


def lum(p):
    return (p[0] * 299 + p[1] * 587 + p[2] * 114) // 1000


def rrect(path, x, y, w, h, r):
    img = read_image(path)
    iw, ih, bpp, rows = img
    distinct = set()
    for yy in range(0, ih, 2):
        row = rows[yy]
        for xx in range(0, iw, 2):
            distinct.add(bytes(row[xx * bpp:xx * bpp + 3]))
    ink, bg = lum(px(img, x + w // 2, y + h // 2)), lum(px(img, max(0, x - 4), max(0, y - 4)))
    lo, hi = ink + 12, bg - 12
    boxes = [(x, y), (x + w - r, y), (x, y + h - r), (x + w - r, y + h - r)]
    partial, levels = [], set()
    for bx, by in boxes:
        n = 0
        for yy in range(by, by + r):
            for xx in range(bx, bx + r):
                v = lum(px(img, xx, yy))
                if lo < v < hi:
                    n += 1
                    levels.add(v)
        partial.append(n)
    corner_aa = int(min(partial) >= r / 2 and len(levels) >= 3)
    corner_bg = lum(px(img, x + 1, y + 1)) >= hi
    fill_ok = int(ink < 80 and bg > 200)
    ok = len(distinct) >= MIN_COLORS and corner_aa and corner_bg and fill_ok
    print("rrect colors=%d corner_aa=%d corner_partial=%s corner_levels=%d corner_px=%s fill_ok=%d "
          "size=%dx%d" % (len(distinct), corner_aa, ",".join(map(str, partial)), len(levels),
                          "bg" if corner_bg else "ink", fill_ok, iw, ih))
    return 0 if ok else 1


def hex_rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def load_geometry(path):
    text = open(path).read()
    body = text.split("\nmodule.exports =", 1)[1].strip().rstrip(";").strip()
    import json
    return json.loads(body)


def smoke(path, geometry_path, scale):
    img = read_image(path)
    iw, ih, bpp, rows = img
    g = load_geometry(geometry_path)
    near = lambda p, q: all(abs(p[k] - q[k]) <= 8 for k in range(3))
    at = lambda x, y: px(img, min(iw - 1, int(x * scale)), min(ih - 1, int(y * scale)))
    checks, details = [], []
    for box in g["boxes"]:
        ox, oy = box["x"], box["y"]
        c = at(ox + box["width"] / 2, oy + box["height"] / 2)
        if box.get("child"):  # probe the parent away from its child
            c = at(ox + box["width"] - 10, oy + box["height"] - 10)
        checks.append(near(c, hex_rgb(box["color"])))
        details.append("%s=%s" % (box["id"], c))
        ch = box.get("child")
        if ch:
            cc = at(ox + ch["x"] + ch["width"] / 2, oy + ch["y"] + ch["height"] / 2)
            checks.append(near(cc, hex_rgb(ch["color"])))
            details.append("%s=%s" % (ch["id"], cc))
    bg = hex_rgb(g["background"])
    corner_bg = all(near(at(b["x"] + 1, b["y"] + 1), bg) for b in g["boxes"] if b.get("radius"))
    bg_ok = near(at(10, 760), bg)
    lx, ly, lw, lh = g["label"]["inkBand"]
    ink = 0
    for y in range(int(ly * scale), int((ly + lh) * scale), 2):
        for x in range(int(lx * scale), int((lx + lw) * scale), 2):
            if sum(px(img, x, y)) < 200:
                ink += 1
    distinct = set()
    for y in range(0, ih, 4):
        r = rows[y]
        for x in range(0, iw, 4):
            distinct.add(bytes(r[x * bpp:x * bpp + 3]))
    ok_boxes = sum(checks)
    match = int(ok_boxes == len(checks))
    ok = match and corner_bg and bg_ok and ink >= 50
    print("smoke box_rgb_match=%d boxes=%d/%d corner_bg=%d bg_ok=%d label_ink=%d colors=%d size=%dx%d %s"
          % (match, ok_boxes, len(checks), corner_bg, bg_ok, ink, len(distinct), iw, ih,
             " ".join(details)))
    return 0 if ok else 1


def main(argv):
    if len(argv) == 8 and argv[1] == "rrect":
        return rrect(argv[2], *map(int, argv[3:8]))
    if len(argv) == 5 and argv[1] == "smoke":
        return smoke(argv[2], argv[3], float(argv[4]))
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
