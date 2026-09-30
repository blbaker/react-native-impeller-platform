"""Finds the LEFTMOST x where two same-size PPMs differ inside a y-band + x-range.

Used by tools/ci-caret-edit.sh's pixel arm: two windowed screenshots of the SAME
focused field with the SAME text but the caret at two different positions
differ ONLY in the caret bar's column (the glyphs are pixel-identical —
neither screenshot changed the text). The leftmost differing x within the
field's band is therefore the caret's painted column.

Argv: <ppm_a> <ppm_b> <x0> <y0> <x1> <y1> [threshold]
Prints the smallest x in [x0,x1) with a differing pixel at some y in [y0,y1),
or NONE if the two images are identical in that band.
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
    i += 1  # single whitespace byte after maxval
    w, h, _maxval = vals
    return w, h, d[i:]


def main():
    path_a, path_b = sys.argv[1], sys.argv[2]
    x0, y0, x1, y1 = (int(v) for v in sys.argv[3:7])
    threshold = int(sys.argv[7]) if len(sys.argv) > 7 else 24

    wa, ha, pa = read_ppm(path_a)
    wb, hb, pb = read_ppm(path_b)
    if (wa, ha) != (wb, hb):
        print("DIM_MISMATCH %dx%d vs %dx%d" % (wa, ha, wb, hb))
        return 1

    best_x = None
    for y in range(max(0, y0), min(ha, y1)):
        row_off = y * wa * 3
        for x in range(max(0, x0), min(wa, x1)):
            o = row_off + x * 3
            dr = abs(pa[o] - pb[o])
            dg = abs(pa[o + 1] - pb[o + 1])
            db = abs(pa[o + 2] - pb[o + 2])
            if dr + dg + db > threshold:
                if best_x is None or x < best_x:
                    best_x = x
                break  # next y row; we only need the leftmost per column scan
    print(best_x if best_x is not None else "NONE")
    return 0


if __name__ == "__main__":
    sys.exit(main())
