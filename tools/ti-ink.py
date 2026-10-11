#!/usr/bin/env python3
"""Ink census of a P6 .ppm inside a rectangle (stdlib only, Mac-runnable).

usage: ti-ink.py <ppm> <x0> <y0> <x1> <y1> [luma_threshold]
Coordinates are LAYOUT points; the scale is the image width / --layout-width
(env TI_LAYOUT_W, default = image width, i.e. scale 1). Prints one line:
  ink=<n> rows=<r0>-<r1> bands=<b> cols=<c0>-<c1>
ink   = pixels with luma < threshold (default 128) inside the rect
rows  = first/last row (layout units) holding ink, -1 when none
bands = runs of consecutive inked rows (one text line = one band)
cols  = first/last inked column (layout units), -1 when none
"""
import os
import sys


def read_ppm(path):
    d = open(path, 'rb').read()
    fields, i = [], 0
    while len(fields) < 4:
        while d[i:i + 1].isspace():
            i += 1
        if d[i:i + 1] == b'#':
            while d[i:i + 1] != b'\n':
                i += 1
            continue
        j = i
        while not d[j:j + 1].isspace():
            j += 1
        fields.append(d[i:j])
        i = j
    i += 1
    w, h = int(fields[1]), int(fields[2])
    return w, h, d[i:i + w * h * 3]


def main():
    path = sys.argv[1]
    x0, y0, x1, y1 = (float(v) for v in sys.argv[2:6])
    thr = int(sys.argv[6]) if len(sys.argv) > 6 else 128
    w, h, px = read_ppm(path)
    s = w / float(os.environ.get('TI_LAYOUT_W', w))
    X0, Y0 = max(0, int(x0 * s)), max(0, int(y0 * s))
    X1, Y1 = min(w, int(x1 * s)), min(h, int(y1 * s))
    ink, rows, cols = 0, [], []
    for y in range(Y0, Y1):
        row_ink = 0
        for x in range(X0, X1):
            o = (y * w + x) * 3
            r, g, b = px[o], px[o + 1], px[o + 2]
            if (r * 299 + g * 587 + b * 114) // 1000 < thr:
                ink += 1
                row_ink += 1
                cols.append(x)
        if row_ink:
            rows.append(y)
    bands, prev = 0, None
    for y in rows:
        if prev is None or y != prev + 1:
            bands += 1
        prev = y
    r0 = rows[0] / s if rows else -1
    r1 = rows[-1] / s if rows else -1
    c0 = min(cols) / s if cols else -1
    c1 = max(cols) / s if cols else -1
    print('ink=%d rows=%.1f-%.1f bands=%d cols=%.1f-%.1f' % (ink, r0, r1, bands, c0, c1))


if __name__ == '__main__':
    main()
