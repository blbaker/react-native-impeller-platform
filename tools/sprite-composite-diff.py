#!/usr/bin/env python3
"""ENG-10 world-sprites gate helper: PER-PIXEL comparison of two PPM (P6)
screenshots of identical dimensions -- the GPU drawSprites render (a) vs the
CPU-composite oracle pushed through setPixels (b).

Why per-pixel and not a histogram (the ENG-09 helper): the ENG-10 mutants
that matter -- wrong draw ORDER, wrong ATLAS entry, upside-down sprite -- all
move pixels around without necessarily changing the set of luma values
present. A histogram is order-, orientation- and position-blind; only
comparing the SAME (x,y) in both images catches them. The histogram distance
is still printed as a secondary signal.

Output (one KEY value per line):
  DIMS WxH, PIXELS n, DISTINCT_LUMA_A/B, HIST_L1_PCT,
  MAX_CHANNEL_DIFF      worst |a-b| over R,G,B at any pixel
  BAD_PIXELS            pixels whose worst channel diff > --pix-tol
  BAD_PCT               BAD_PIXELS / PIXELS * 100
  WORST_AT x,y a=(r,g,b) b=(r,g,b)
"""
import sys


def read_ppm(path):
    data = open(path, 'rb').read()
    if data[:2] != b'P6':
        raise ValueError(f'{path}: not a P6 PPM (header {data[:16]!r})')
    i = 2
    toks = []
    while len(toks) < 3:
        while data[i:i + 1].isspace():
            i += 1
        if data[i:i + 1] == b'#':
            while data[i:i + 1] != b'\n':
                i += 1
            continue
        s = i
        while not data[i:i + 1].isspace():
            i += 1
        toks.append(int(data[s:i]))
    i += 1
    w, h, _ = toks
    return w, h, data[i:i + w * h * 3]


def luma(r, g, b):
    return (299 * r + 587 * g + 114 * b) // 1000


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    pix_tol = 6
    for a in sys.argv[1:]:
        if a.startswith('--pix-tol='):
            pix_tol = int(a.split('=', 1)[1])
    if len(args) != 2:
        print('usage: sprite-composite-diff.py a.ppm b.ppm [--pix-tol=N]', file=sys.stderr)
        return 2
    wa, ha, pa = read_ppm(args[0])
    wb, hb, pb = read_ppm(args[1])
    if (wa, ha) != (wb, hb):
        print(f'DIMENSION_MISMATCH a={wa}x{ha} b={wb}x{hb}')
        return 1
    n = wa * ha
    hist_a = [0] * 256
    hist_b = [0] * 256
    max_d = 0
    worst = None
    bad = 0
    for k in range(n):
        o = k * 3
        ra, ga, ba = pa[o], pa[o + 1], pa[o + 2]
        rb, gb, bb = pb[o], pb[o + 1], pb[o + 2]
        hist_a[luma(ra, ga, ba)] += 1
        hist_b[luma(rb, gb, bb)] += 1
        d = max(abs(ra - rb), abs(ga - gb), abs(ba - bb))
        if d > pix_tol:
            bad += 1
        if d > max_d:
            max_d = d
            worst = (k % wa, k // wa, (ra, ga, ba), (rb, gb, bb))
    l1 = sum(abs(x - y) for x, y in zip(hist_a, hist_b))
    print(f'DIMS {wa}x{ha}')
    print(f'PIXELS {n}')
    print(f'DISTINCT_LUMA_A {sum(1 for c in hist_a if c)}')
    print(f'DISTINCT_LUMA_B {sum(1 for c in hist_b if c)}')
    print(f'HIST_L1_PCT {l1 / (2 * n):.6f}')
    print(f'PIX_TOL {pix_tol}')
    print(f'MAX_CHANNEL_DIFF {max_d}')
    print(f'BAD_PIXELS {bad}')
    print(f'BAD_PCT {bad * 100.0 / n:.4f}')
    if worst:
        print(f'WORST_AT {worst[0]},{worst[1]} a={worst[2]} b={worst[3]}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
