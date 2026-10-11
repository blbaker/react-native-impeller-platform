#!/usr/bin/env python3
"""Counts selection-highlight pixels for tools/ci-select-keys.sh (item 4a).

Compares an UNFOCUSED frame with a frame that shows a selection, inside the
field's y-band. A pixel counts as highlight when it differs from the
unfocused frame AND its blue channel dominates red (the highlight is a blue
tint; the white glyphs and grey border are not blue-dominant).

Argv: <unfocused.ppm> <selected.ppm> <y0> <y1> <x_lo> <x_hi>
Prints: INSIDE=<n> OUTSIDE_LEFT=<n>
  INSIDE        highlight pixels with x in [x_lo, x_hi)
  OUTSIDE_LEFT  highlight pixels with x in [24, x_lo - 1), i.e. over text
                that is NOT selected (1px slack for anti-aliasing)
"""
import sys


def read_ppm(path):
    d = open(path, "rb").read()
    assert d[:2] == b"P6", "not a raw PPM (P6): %r" % d[:2]
    parts = d.split(b"\n", 3)
    w, h = (int(v) for v in parts[1].split())
    return w, h, parts[3]


def main():
    a_path, b_path = sys.argv[1], sys.argv[2]
    y0, y1, x_lo, x_hi = (int(v) for v in sys.argv[3:7])
    wa, ha, a = read_ppm(a_path)
    wb, hb, b = read_ppm(b_path)
    if (wa, ha) != (wb, hb):
        print("DIM_MISMATCH")
        return 1

    def is_hl(x, y):
        i = (y * wa + x) * 3
        ra, ga, ba = a[i], a[i + 1], a[i + 2]
        rb, gb, bb = b[i], b[i + 1], b[i + 2]
        if abs(ra - rb) + abs(ga - gb) + abs(ba - bb) < 24:
            return False
        return bb > rb + 20

    inside = sum(1 for y in range(y0, y1) for x in range(x_lo, x_hi) if is_hl(x, y))
    left = sum(1 for y in range(y0, y1) for x in range(24, max(24, x_lo - 1)) if is_hl(x, y))
    print("INSIDE=%d OUTSIDE_LEFT=%d" % (inside, left))
    return 0


if __name__ == "__main__":
    sys.exit(main())
