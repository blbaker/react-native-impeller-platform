#!/usr/bin/env python3
"""FP-41 pixel checks for tools/ci-backdrop.sh (fixtures/fp41-backdrop geometry, 400x300).

usage: backdrop_check.py <blur.ppm> <noblur.ppm> <tag>
Prints one line per check; exits 1 with BACKDROP_FAIL lines naming the defect.
"""
import sys
from PIL import Image

BLUR = (40, 40, 140, 100)     # tint dark, intensity 60, green child at (100,80) 20x20
CONTROL = (220, 40, 140, 100)  # same tint colour as a plain View, no blur
SCROLL = (60, 190, 120, 60)    # light, intensity 80, inside a ScrollView at contentOffset y=60
CHILD = (100, 80, 20, 20)
TINTS = {"dark": ((25, 25, 25), 0.6 * 0.78), "light": ((249, 249, 249), 0.8 * 0.78)}
INSET = 8  # stay clear of the clamped blur edge


def region(im, r, inset=INSET, skip=None):
    x, y, w, h = r
    px = []
    for yy in range(y + inset, y + h - inset):
        for xx in range(x + inset, x + w - inset):
            if skip and skip[0] - 4 <= xx < skip[0] + skip[2] + 4 and skip[1] - 4 <= yy < skip[1] + skip[3] + 4:
                continue
            px.append(im[xx, yy])
    return px


def stats(px):
    n = len(px)
    mean = [sum(p[c] for p in px) / n for c in range(3)]
    var = sum(sum((p[c] - mean[c]) ** 2 for c in range(3)) for p in px) / n
    return mean, var ** 0.5


def main():
    blur_img = Image.open(sys.argv[1]).convert("RGB")
    ref_img = Image.open(sys.argv[2]).convert("RGB")
    tag = sys.argv[3]
    assert blur_img.size == ref_img.size == (400, 300), (blur_img.size, ref_img.size)
    b, r = blur_img.load(), ref_img.load()
    fails = []

    # 1. Backdrop blurred: inside the blur view vs the same-tint control (what a null backdrop or a
    #    blur on the view's own content paints: the tint over a sharp backdrop).
    _, ctl_sd = stats(region(b, CONTROL))
    for name, rect, tint, skip in (("blur", BLUR, "dark", CHILD), ("scroll", SCROLL, "light", None)):
        mean, sd = stats(region(b, rect, skip=skip))
        print(f"{tag} {name}: local_sd={sd:.2f} control_sd={ctl_sd:.2f} mean={[round(m, 1) for m in mean]}")
        if not sd < 0.15 * ctl_sd:
            fails.append(f"{tag} {name}: backdrop not blurred inside the blur view "
                         f"(sd {sd:.2f} vs control {ctl_sd:.2f}, need < 15%)")
        # 2. Tint: blurred backdrop (= the backdrop's mean colour) under the expo-blur tint.
        bg_mean, _ = stats(region(r, rect, skip=skip))
        (tc, a) = TINTS[tint]
        want = [bg_mean[c] * (1 - a) + tc[c] * a for c in range(3)]
        err = max(abs(mean[c] - want[c]) for c in range(3))
        print(f"{tag} {name}: tint want={[round(v, 1) for v in want]} err={err:.1f}")
        if err > 8:
            fails.append(f"{tag} {name}: wrong tint (mean {[round(m) for m in mean]} want "
                         f"{[round(v) for v in want]})")

    # 3. Children of <BlurView> paint crisp on top (not blurred, not under the tint).
    cx, cy = CHILD[0] + 10, CHILD[1] + 10
    edge = b[CHILD[0] - 2, cy]
    print(f"{tag} child: centre={b[cx, cy]} outside_edge={edge}")
    if max(abs(v - w) for v, w in zip(b[cx, cy], (0, 255, 0))) > 3 or edge[1] > 80:
        fails.append(f"{tag} child: BlurView child is not crisp (centre {b[cx, cy]}, 2 px out {edge})")

    # 4. Outside every blur view the frame equals the no-blur reference.
    worst, where, changed = 0, None, 0
    boxes = [(x - 1, y - 1, x + w + 1, y + h + 1) for (x, y, w, h) in (BLUR, SCROLL)]
    for yy in range(300):
        for xx in range(400):
            if any(x0 <= xx < x1 and y0 <= yy < y1 for (x0, y0, x1, y1) in boxes):
                continue
            d = max(abs(p - q) for p, q in zip(b[xx, yy], r[xx, yy]))
            if d > 2:
                changed += 1
            if d > worst:
                worst, where = d, (xx, yy)
    print(f"{tag} outside: changed_px={changed} max_diff={worst} at={where}")
    if changed:
        fails.append(f"{tag} outside: {changed} px outside the blur views changed (max {worst} at {where})")

    for f in fails:
        print("BACKDROP_FAIL: " + f)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
