#!/usr/bin/env python3
"""FP-33 helper for tools/ci-memory-budget.sh. Subcommands:
  gen DIR N SIZE            N distinct SIZExSIZE PNGs img-<i>.png (solid colour(i) plus an index stripe)
  tiles PPM FIRST N BOX     checks the centre of tile k (k < N) against colour(FIRST + k); prints tiles_bad=
"""
import os, sys

import numpy as np
from PIL import Image


def color(i):
    return ((i * 37) % 256, (i * 91) % 256, (i * 13 + 50) % 256)


def gen(d, n, size):
    for i in range(n):
        im = Image.new("RGB", (size, size), color(i))
        im.paste((i % 256, (i >> 8) % 256, 0), (0, 0, size, 4))  # distinct bytes per file
        im.save(os.path.join(d, "img-%d.png" % i))


def tiles(ppm, first, n, box):
    im = np.asarray(Image.open(ppm).convert("RGB")).astype(int)
    bad = sum(1 for k in range(n)
              if np.abs(im[box // 2, k * box + box // 2] - np.array(color(first + k))).max() > 3)
    print("tiles_bad=%d of %d" % (bad, n))


if __name__ == "__main__":
    a = sys.argv[1:]
    if a[0] == "gen": gen(a[1], int(a[2]), int(a[3]))
    elif a[0] == "tiles": tiles(a[1], int(a[2]), int(a[3]), int(a[4]))
    else: sys.exit("unknown subcommand " + a[0])
