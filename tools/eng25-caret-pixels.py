"""ENG-25 pixel oracle for tools/ci-multiline-caret.sh. Reads raw P6 PPMs.

  bbox A B x0 y0 x1 y1 [brighter]
      Bounding box of pixels inside [x0,x1) x [y0,y1) where A and B differ
      (sum |dR|+|dG|+|dB| > 60). With `brighter`, only pixels where A is
      BRIGHTER than B (A has the white caret there, B does not).
      Prints "X0 Y0 X1 Y1 N" (inclusive) or NONE.
  rows A B x0 y0 x1 y1
      Differing-pixel count and leftmost differing x in the region.
      Prints "N LEFTX" (LEFTX = -1 when N = 0).
  ink A x0 y0 x1 y1
      Text-ink extent (luma > 128) in the region. Prints
      "TOPY BOTTOMY RIGHTX" for the whole region, or NONE.

The caret is a solid white bar (the gate runs with RNI_CARET_BLINK_MS=0) on a
#222 field, so two screenshots of the SAME text that differ only in focus or
caret position differ only in the caret's pixels.
"""
import sys


def read_ppm(path):
    d = open(path, "rb").read()
    assert d[:2] == b"P6", "not a raw PPM (P6): %r" % d[:2]
    i = 2
    vals = []
    while len(vals) < 3:
        while d[i : i + 1].isspace():
            i += 1
        if d[i : i + 1] == b"#":
            while d[i : i + 1] != b"\n":
                i += 1
            continue
        s = i
        while not d[i : i + 1].isspace():
            i += 1
        vals.append(int(d[s:i]))
    i += 1
    w, h, _ = vals
    return w, h, d[i:]


def px(p, w, x, y):
    o = (y * w + x) * 3
    return p[o], p[o + 1], p[o + 2]


def region(w, h, a):
    x0, y0, x1, y1 = (int(v) for v in a)
    return max(0, x0), max(0, y0), min(w, x1), min(h, y1)


def main():
    cmd = sys.argv[1]
    if cmd in ("bbox", "rows"):
        wa, ha, pa = read_ppm(sys.argv[2])
        wb, hb, pb = read_ppm(sys.argv[3])
        if (wa, ha) != (wb, hb):
            print("DIM_MISMATCH")
            return 1
        x0, y0, x1, y1 = region(wa, ha, sys.argv[4:8])
        brighter = len(sys.argv) > 8 and sys.argv[8] == "brighter"
        bx0 = by0 = 10 ** 9
        bx1 = by1 = -1
        n = 0
        for y in range(y0, y1):
            for x in range(x0, x1):
                ra, ga, ba = px(pa, wa, x, y)
                rb, gb, bb = px(pb, wb, x, y)
                if brighter:
                    hit = (ra + ga + ba) - (rb + gb + bb) > 60
                else:
                    hit = abs(ra - rb) + abs(ga - gb) + abs(ba - bb) > 60
                if hit:
                    n += 1
                    bx0, by0 = min(bx0, x), min(by0, y)
                    bx1, by1 = max(bx1, x), max(by1, y)
        if cmd == "rows":
            print("%d %d" % (n, bx0 if n else -1))
        elif n == 0:
            print("NONE")
        else:
            print("%d %d %d %d %d" % (bx0, by0, bx1, by1, n))
        return 0
    if cmd == "ink":
        w, h, p = read_ppm(sys.argv[2])
        x0, y0, x1, y1 = region(w, h, sys.argv[3:7])
        top, bot, right = None, None, -1
        for y in range(y0, y1):
            for x in range(x0, x1):
                r, g, b = px(p, w, x, y)
                if 0.299 * r + 0.587 * g + 0.114 * b > 128:
                    top = y if top is None else top
                    bot = y
                    right = max(right, x)
        print("NONE" if top is None else "%d %d %d" % (top, bot, right))
        return 0
    print("usage: bbox|rows|ink ...", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
