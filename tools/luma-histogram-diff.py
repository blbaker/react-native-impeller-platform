#!/usr/bin/env python3
"""ENG-09 world-raster gate helper: luma histogram L1 distance between two
PPM (P6) screenshots of identical dimensions.

Kept as a real file, not a command-substitution heredoc, per the
mutation-testing skill's bash-quoting guidance: nesting a heredoc inside
$(...) makes a bash syntax error point at the end of the whole gate script
instead of the real line.
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
    i += 1  # single whitespace byte after maxval
    w, h, _maxval = toks
    return w, h, data[i:i + w * h * 3]


def luma_hist(px, n):
    hist = [0] * 256
    for k in range(n):
        o = k * 3
        r, g, b = px[o], px[o + 1], px[o + 2]
        lum = (299 * r + 587 * g + 114 * b) // 1000
        hist[lum] += 1
    return hist


def main():
    if len(sys.argv) != 3:
        print('usage: luma-histogram-diff.py a.ppm b.ppm', file=sys.stderr)
        return 2
    a_path, b_path = sys.argv[1], sys.argv[2]
    wa, ha, pxa = read_ppm(a_path)
    wb, hb, pxb = read_ppm(b_path)
    if (wa, ha) != (wb, hb):
        print(f'DIMENSION_MISMATCH a={wa}x{ha} b={wb}x{hb}')
        return 1
    n = wa * ha
    hist_a = luma_hist(pxa, n)
    hist_b = luma_hist(pxb, n)
    l1 = sum(abs(x - y) for x, y in zip(hist_a, hist_b))
    pct = l1 / (2 * n)
    distinct_a = sum(1 for c in hist_a if c > 0)
    distinct_b = sum(1 for c in hist_b if c > 0)
    print(f'DIMS {wa}x{ha}')
    print(f'PIXELS {n}')
    print(f'DISTINCT_LUMA_A {distinct_a}')
    print(f'DISTINCT_LUMA_B {distinct_b}')
    print(f'HIST_L1_DIFF {l1}')
    print(f'HIST_L1_PCT {pct:.6f}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
