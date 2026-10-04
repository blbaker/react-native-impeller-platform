#!/usr/bin/env python3
"""ENG-23: ink bands (text lines) inside layout regions of a P6 PPM.

usage: ink-bands.py <ppm> <layout_w> <layout_h> <region> [<region> ...]
  region = name:x0:y0:x1:y1 in LAYOUT points (scaled to the PPM by proportion,
  so a 2x Retina capture reads the same regions).
Prints one line per region:
  <name> bands=<n> tops=<t1,t2,..> bottoms=<b1,b2,..> pitch=<pts>
A band is a run of consecutive pixel rows holding ink (luminance < 128, black
text on a white page). tops/bottoms are in layout points. pitch is the distance
between the first two band TOPS (two lines that start with the same cap glyphs
have equal ascent, so top-to-top is the painted line pitch); 0 when < 2 bands.
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
        inked = []
        for y in range(Y0, Y1):
            row = y * w
            hit = False
            for x in range(X0, X1):
                o = (row + x) * 3
                if (px[o] * 299 + px[o + 1] * 587 + px[o + 2] * 114) // 1000 < 128:
                    hit = True
                    break
            inked.append(hit)
        bands, start = [], None
        for k, hit in enumerate(inked + [False]):
            if hit and start is None:
                start = k
            elif not hit and start is not None:
                bands.append((start, k - 1))
                start = None
        tops = [(Y0 + a) / sy for a, _ in bands]
        bots = [(Y0 + b + 1) / sy for _, b in bands]
        pitch = tops[1] - tops[0] if len(tops) >= 2 else 0.0
        print(f"{name} bands={len(bands)} "
              f"tops={','.join(f'{t:.1f}' for t in tops)} "
              f"bottoms={','.join(f'{b:.1f}' for b in bots)} pitch={pitch:.1f}")


main()
