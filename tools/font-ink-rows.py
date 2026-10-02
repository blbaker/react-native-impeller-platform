#!/usr/bin/env python3
"""ENG-22: ink extents per fixture row of a P6 PPM.

usage: font-ink-rows.py <ppm> <layout_w> <layout_h> <row> [<row> ...]
  row = name:x0:y0:x1:y1 in LAYOUT points (scaled to the PPM by proportion,
  so a 2x Retina capture reads the same rows).
Prints one line per row: `<name> ink=<n> left=<px> right=<px> width=<pts>`.
Ink = luminance < 128 (black text on a white page). width is in layout points.
"""
import sys


def read_ppm(path):
    d = open(path, 'rb').read()
    parts, i = [], 0
    while len(parts) < 4:
        while d[i:i + 1].isspace():
            i += 1
        if d[i:i + 1] == b'#':
            while d[i:i + 1] != b'\n':
                i += 1
            continue
        s = i
        while not d[i:i + 1].isspace():
            i += 1
        parts.append(d[s:i])
    return int(parts[1]), int(parts[2]), d[i + 1:]


def main():
    path, lw, lh = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
    w, h, px = read_ppm(path)
    sx, sy = w / lw, h / lh
    for spec in sys.argv[4:]:
        name, *nums = spec.split(':')
        x0, y0, x1, y1 = (float(v) for v in nums)
        X0, X1 = int(x0 * sx), min(w, int(x1 * sx))
        Y0, Y1 = int(y0 * sy), min(h, int(y1 * sy))
        ink, left, right = 0, None, None
        for y in range(Y0, Y1):
            row = y * w
            for x in range(X0, X1):
                o = (row + x) * 3
                if (px[o] * 299 + px[o + 1] * 587 + px[o + 2] * 114) // 1000 < 128:
                    ink += 1
                    left = x if left is None or x < left else left
                    right = x if right is None or x > right else right
        width = 0.0 if left is None else (right - left + 1) / sx
        print(f"{name} ink={ink} left={left} right={right} width={width:.1f}")


main()
