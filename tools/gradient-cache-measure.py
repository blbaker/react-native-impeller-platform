#!/usr/bin/env python3
"""ENG-48 measurer for fixtures/eng48-gradient-cache (stdlib only, Mac-safe).

Slot P is surface x 20..84, slot Q is x 120..184 (dp, scale 1). A column's
colour is its mean over y 30..110 (inside the 100-tall rect, clear of edges).

  slot  <ppm> P|Q            -> "<label> cols=[(r,g,b) x3]" on the Mac's
                                three columns (local x 2, 32, 62)
  match <ppmA> <slotA> <ppmB> <slotB> [tol]
                             -> compares 16 columns (local x 2..62 step 4);
                                exit 0 when every channel is within tol
                                (default 4), else 1. Prints the max diff.
"""
import sys

SLOT_X0 = {"P": 20, "Q": 120}
Y0, Y1 = 30, 110
MAC_COLS = (2, 32, 62)
CMP_COLS = tuple(range(2, 63, 4))


def read_ppm(path):
    with open(path, "rb") as f:
        data = f.read()
    # P6 header: magic, width, height, maxval, each whitespace separated.
    fields, pos = [], 0
    while len(fields) < 4:
        while data[pos:pos + 1].isspace():
            pos += 1
        if data[pos:pos + 1] == b"#":
            while data[pos:pos + 1] not in (b"\n", b""):
                pos += 1
            continue
        start = pos
        while not data[pos:pos + 1].isspace():
            pos += 1
        fields.append(data[start:pos])
    if fields[0] != b"P6":
        raise SystemExit("not a P6 ppm: %s" % path)
    w, h = int(fields[1]), int(fields[2])
    return w, h, data[pos + 1:]


def column(img, x):
    w, h, px = img
    if x >= w or Y1 > h:
        raise SystemExit("ppm %dx%d too small for x=%d y<%d" % (w, h, x, Y1))
    acc = [0, 0, 0]
    for y in range(Y0, Y1):
        i = (y * w + x) * 3
        for c in range(3):
            acc[c] += px[i + c]
    n = Y1 - Y0
    return tuple(int(round(v / n)) for v in acc)


def cols(img, slot, xs):
    x0 = SLOT_X0[slot]
    return [column(img, x0 + x) for x in xs]


def label(cs):
    inks = [255 - min(c) for c in cs]
    if max(inks) < 20:
        return "blank"
    r, g, b = cs[inks.index(max(inks))]
    if r - max(g, b) > 40:
        hue = "red"
    elif b - max(r, g) > 40:
        hue = "blue"
    elif g - max(r, b) > 40:
        hue = "green"
    else:
        hue = "grey"
    d = inks[-1] - inks[0]
    if d > 100:
        shape = "rising"
    elif d < -100:
        shape = "falling"
    else:
        shape = "flat"
    return hue + "-" + shape


def main(argv):
    if len(argv) >= 3 and argv[0] == "slot":
        cs = cols(read_ppm(argv[1]), argv[2], MAC_COLS)
        print("%s cols=%s" % (label(cs), cs))
        return 0
    if len(argv) >= 5 and argv[0] == "match":
        tol = int(argv[5]) if len(argv) > 5 else 4
        a = cols(read_ppm(argv[1]), argv[2], CMP_COLS)
        b = cols(read_ppm(argv[3]), argv[4], CMP_COLS)
        diff = max(abs(p - q) for ca, cb in zip(a, b) for p, q in zip(ca, cb))
        print("maxdiff=%d tol=%d" % (diff, tol))
        return 0 if diff <= tol else 1
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
