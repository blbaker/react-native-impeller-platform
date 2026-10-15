#!/usr/bin/env python3
"""FP-12: measured width vs painted ink extent, per paragraph.

usage: typography_rows.py <ppm> <engine.log> <name>:<frame_y> [...]
For each row, the Paragraph whose node_frame y equals <frame_y> gives the measured box
(x, w). The painted ink extent is the leftmost..rightmost dark pixel (luminance < 128) in that
box's rows, searched across the WHOLE width so ink outside the box counts. The fixture brackets
every string with U+2588 FULL BLOCK, so ink extent == advance width when measure == paint.
Prints `row <name> measured=<w> ink=<w> dl=<left delta> dr=<right delta>` (device px == pt at
scale 1) and exits 1 if a row is missing.
"""
import re
import sys


def read_ppm(path):
    d = open(path, "rb").read()
    parts, i = [], 0
    while len(parts) < 4:
        while d[i:i + 1].isspace():
            i += 1
        s = i
        while not d[i:i + 1].isspace():
            i += 1
        parts.append(d[s:i])
    return int(parts[1]), int(parts[2]), d[i + 1:]


def main():
    ppm, log, specs = sys.argv[1], sys.argv[2], sys.argv[3:]
    w, h, px = read_ppm(ppm)
    frames = {}
    for line in open(log, errors="replace"):
        m = re.match(r"^rn-impeller: node_frame=Paragraph,\d+,([0-9.]+),([0-9.]+),([0-9.]+),([0-9.]+)$", line.strip())
        if m:
            x, y, fw, fh = (float(v) for v in m.groups())
            frames[round(y)] = (x, y, fw, fh)  # last commit wins
    rc = 0
    for spec in specs:
        name, fy = spec.split(":")
        f = frames.get(int(fy))
        if f is None:
            print(f"row {name} missing: no node_frame=Paragraph at y={fy}")
            rc = 1
            continue
        x, y, fw, fh = f
        left = right = None
        for yy in range(int(y), min(h, int(y + fh))):
            base = yy * w
            for xx in range(w):
                o = (base + xx) * 3
                if (px[o] * 299 + px[o + 1] * 587 + px[o + 2] * 114) // 1000 < 128:
                    left = xx if left is None or xx < left else left
                    right = xx if right is None or xx > right else right
        if left is None:
            print(f"row {name} measured={fw:.1f} ink=0 dl=nan dr=nan")
            continue
        ink = right - left + 1
        print(f"row {name} measured={fw:.1f} ink={ink} dl={left - x:.1f} dr={right + 1 - (x + fw):.1f}")
    return rc


sys.exit(main())
