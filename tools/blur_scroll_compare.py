#!/usr/bin/env python3
"""Pixel verdict for the blur-over-moving-content gates (stdlib only).

  blur_scroll_compare.py <scene> <scale> <before> <after> <ref> [<control>]

fixtures/blur-scroll lays a 400x400-point scene at the surface's top-left; a
BlurView header covers points y 0..140. Images are .ppm (desktop capture) or
.png (simulator screenshot); <scale> is pixels per point. One sample per point
(the pixel at the point's top-left), so both gates compare the same grid.

  scene scroll  tiles scroll 0 -> 100 under the header (ScrollView top = 80)
  scene tile    one tile at points (150,100) 100x40 changes colour under it

For every band prints `<band>: moved mean|d|= stale px=a/b control px=c/d`, then
FAIL lines (callers prefix them with their gate's name):
  FAIL M: a header band did not change between <before> and <after>
          (the blur did not follow what moved under it)
  FAIL S: <after> differs from <ref> (the same scene painted in its end state
          from the start) in more than 0.2% of a band's samples (> 8 per channel)
  FAIL C: <control> (the same motion with partial repaint off) differs from <ref>
  FAIL B: (scene scroll) the header over the tiles is not blurred: its mean
          horizontal neighbour difference is not under 1/4 of the sharp tiles'
          below it (an engine that skips the blur passes M and S, not B)
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ios_image_check import read_image  # noqa: E402

# (name, x0, x1, y0, y1, min mean |d| between before and after or None)
BANDS = {
    "scroll": [("header above scroll (0..80)", 0, 400, 0, 80, 5.0),
               ("header over scroll (80..140)", 0, 400, 80, 140, 5.0),
               ("below header (140..400)", 0, 400, 140, 400, None)],
    # The moved band is the blur just above the tile (x 120..280, y 60..100):
    # averaged over the whole header width the tile's pull is too thin to judge.
    # Measured: black -> white tile moves it 6.7 (light tint); want >= 3.
    "tile": [("tile: header above the tile (0..100)", 0, 400, 0, 100, None),
             ("tile: blur just above the tile (x120..280 y60..100)", 120, 280, 60, 100, 3.0),
             ("tile: tile rows (100..140)", 0, 400, 100, 140, None),
             ("tile: below (140..400)", 0, 400, 140, 400, None)],
}


def samples(img, scale, x0, x1, y0, y1):
    w, h, bpp, rows = img
    out = []
    for y in range(y0, y1):
        py = min(h - 1, int(y * scale))
        r = rows[py]
        for x in range(x0, x1):
            px = min(w - 1, int(x * scale)) * bpp
            out.append((r[px], r[px + 1], r[px + 2]))
    return out


def edge(img, scale, y0, y1):
    """Mean |horizontal neighbour difference| over a band, one sample per point."""
    s = samples(img, scale, 0, 400, y0, y1)
    tot, n = 0, 0
    for i in range(1, len(s)):
        if i % 400:
            tot += sum(abs(s[i][c] - s[i - 1][c]) for c in range(3))
            n += 3
    return tot / max(1, n)


def mean_abs(a, b):
    return sum(abs(p[i] - q[i]) for p, q in zip(a, b) for i in range(3)) / max(1, 3 * len(a))


def bad(a, b, thr=8):
    return sum(1 for p, q in zip(a, b) if max(abs(p[i] - q[i]) for i in range(3)) > thr)


def main(argv):
    if len(argv) not in (6, 7) or argv[1] not in BANDS:
        print(__doc__)
        return 2
    scene, scale = argv[1], float(argv[2])
    imgs = [read_image(p) for p in argv[3:]]
    before, after, ref = imgs[:3]
    ctl = imgs[3] if len(imgs) > 3 else None
    print(f"size {after[0]}x{after[1]} scale {scale}")
    fails = []
    # A blank shot (taken before the first frame) would "move" everything.
    for label, img in (("before", before), ("after", after), ("ref", ref)):
        n = len(set(samples(img, scale, 0, 400, 0, 400)))
        if n < 20:
            print(f"FAIL setup: the {label} shot has {n} colours: blank, not the scene")
            return 1
    for name, x0, x1, y0, y1, min_move in BANDS[scene]:
        b, a, r = (samples(i, scale, x0, x1, y0, y1) for i in (before, after, ref))
        mv, sb = mean_abs(b, a), bad(a, r)
        line = f"{name}: moved mean|d|={mv:.1f}  stale px={sb}/{len(a)}"
        if ctl is not None:
            cb = bad(samples(ctl, scale, x0, x1, y0, y1), r)
            line += f"  control px={cb}/{len(a)}"
            if cb > len(a) * 0.002:
                fails.append(f"FAIL C: {name}: the full-repaint control differs from the reference ({cb} px)")
        print(line)
        if min_move is not None and mv < min_move:
            fails.append(f"FAIL M: {name} did not change with the content under it (mean |d| {mv:.1f})")
        if sb > len(a) * 0.002:
            fails.append(f"FAIL S: {name}: {sb} of {len(a)} px differ from the reference painted in the end state")
    if scene == "scroll":
        hdr, tiles = edge(after, scale, 90, 130), edge(after, scale, 300, 340)
        print(f"blur: header edge={hdr:.2f} tiles edge={tiles:.2f}")
        if not hdr < tiles / 4:
            fails.append(f"FAIL B: the header over the tiles is not blurred (edge {hdr:.2f} vs tiles {tiles:.2f})")
    for f in fails:
        print(f)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
