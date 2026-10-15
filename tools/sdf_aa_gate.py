#!/usr/bin/env python3
"""FP-22 judge for tools/ci-sdf-aa.sh: compares an --sdf-aa off and an --sdf-aa on capture of
fixtures/fp22-sdf-aa (400x300, scale 1). Prints one `name ...` line per measurement and exits 1
with `SDF_AA_GATE_FAIL: <arm>: <why>` on the first broken rule.
  sdf_aa_gate.py <off.ppm> <on.ppm>"""
import sys

import numpy as np
from PIL import Image

# kind, x, y, w, h, radius (rrect), fill: mirrors fixtures/fp22-sdf-aa/index.js
SHAPES = {
    "circle": ("ellipse", 20, 20, 80, 80, 0, (208, 0, 0)),
    "oval": ("ellipse", 120, 20, 140, 80, 0, (0, 0, 208)),
    "rrect": ("rrect", 20.5, 130.5, 120, 80, 20, (0, 128, 0)),
    "path": ("box", 180, 130, 120, 80, 0, (128, 0, 128)),
    "rect": ("box", 320, 20, 60, 40, 0, (0, 0, 0)),
}
MIN_PARTIAL_ON = {"circle": 150, "oval": 200, "rrect": 60}  # >= on --sdf-aa on
MAX_PARTIAL_OFF = {"oval": 10, "rrect": 10}  # tessellated GL fills at 1x have hard edges
MIN_CIRCLE_CHANGED = 100  # Impeller's circle pipeline AAs already; SDF must still replace it
MARGIN = 1.5  # px from the analytic edge that counts as "interior" / "elsewhere"


def fail(arm, why):
    print(f"SDF_AA_GATE_FAIL: {arm}: {why}")
    sys.exit(1)


def signed_dist(kind, x, y, w, h, r, px, py):
    """Approximate signed distance (px, negative inside) of pixel centres to the shape edge."""
    cx, cy, ax, ay = x + w / 2, y + h / 2, w / 2, h / 2
    if kind == "ellipse":
        k = np.sqrt(((px - cx) / ax) ** 2 + ((py - cy) / ay) ** 2)
        return (k - 1) * min(ax, ay)
    if kind == "rrect":
        qx = np.abs(px - cx) - (ax - r)
        qy = np.abs(py - cy) - (ay - r)
        out = np.hypot(np.maximum(qx, 0), np.maximum(qy, 0))
        return out + np.minimum(np.maximum(qx, qy), 0) - r
    qx, qy = np.abs(px - cx) - ax, np.abs(py - cy) - ay
    return np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0)


def main():
    off = np.asarray(Image.open(sys.argv[1]).convert("RGB")).astype(int)
    on = np.asarray(Image.open(sys.argv[2]).convert("RGB")).astype(int)
    if off.shape != (300, 400, 3) or on.shape != off.shape:
        fail("capture", f"want 400x300 captures, got {off.shape} / {on.shape}")
    py, px = np.mgrid[0:300, 0:400] + 0.5
    near = np.zeros(off.shape[:2], bool)  # within MARGIN of any SDF-eligible edge
    diff = np.abs(off - on).max(-1) > 0
    for name, (kind, x, y, w, h, r, fill) in SHAPES.items():
        d = signed_dist(kind, x, y, w, h, r, px, py)
        box = np.abs(d) <= 4
        partial = {}
        for tag, img in (("off", off), ("on", on)):
            bg = (img == 255).all(-1)
            solid = (np.abs(img - np.array(fill)).max(-1) == 0)
            partial[tag] = int((box & ~bg & ~solid).sum())
        inner = d < -MARGIN
        inner_diff = int((diff & inner).sum())
        changed = int((diff & box).sum())
        print(f"{name} partial_off={partial['off']} partial_on={partial['on']} changed={changed} "
              f"interior_px={int(inner.sum())} interior_diff={inner_diff}")
        if inner_diff:
            fail("interior", f"{name}: {inner_diff} interior pixels differ between --sdf-aa off and on")
        if kind == "box":
            if changed:
                fail("elsewhere", f"{name}: {changed} pixels differ; a {kind} the flag must not touch changed")
            continue
        near |= np.abs(d) <= MARGIN
        if partial["on"] < MIN_PARTIAL_ON[name]:
            fail("coverage", f"{name}: {partial['on']} partial-coverage pixels with --sdf-aa on, want >= "
                             f"{MIN_PARTIAL_ON[name]} (SDF AA not in effect)")
        if name in MAX_PARTIAL_OFF and partial["off"] > MAX_PARTIAL_OFF[name]:
            fail("control", f"{name}: {partial['off']} partial pixels with --sdf-aa off, want <= "
                            f"{MAX_PARTIAL_OFF[name]} (off arm is not the tessellated path)")
        if name == "circle" and changed < MIN_CIRCLE_CHANGED:
            fail("coverage", f"circle: only {changed} edge pixels changed with --sdf-aa on, want >= "
                             f"{MIN_CIRCLE_CHANGED} (still Impeller's circle pipeline, not the SDF)")
    elsewhere = int((diff & ~near).sum())
    print(f"elsewhere_diff={elsewhere} total_diff={int(diff.sum())}")
    if elsewhere:
        ys, xs = np.nonzero(diff & ~near)
        fail("elsewhere", f"{elsewhere} pixels away from SDF edges differ, first at ({xs[0]},{ys[0]})")
    print("SDF_AA_JUDGE_OK")


if __name__ == "__main__":
    main()
