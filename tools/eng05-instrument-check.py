#!/usr/bin/env python3
"""Instrument validation for the ENG-05b anti-aliasing probe.

Reuses the SAME PPM reader and the SAME ink test as eng05-aa-analyse.py, over
a fixture whose intermediate luminance comes from alpha blending and a
gradient rather than from edge coverage. If this reports a wide spread, the
measurement chain can carry partial values and "0.0% partial" on hard edges is
a real renderer property. If it reports pure-only, the AA result is an
artifact of the instrument and proves nothing.

Exits nonzero when the instrument fails, so it can be used as a gate.
"""
import sys

PURE_LO = 8
PURE_HI = 247


def read_ppm(path):
    d = open(path, 'rb').read()
    parts = []
    i = 0
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


# ⛔ DISTINCT-COUNT IS THE WRONG ASSERTION FOR A FLAT REGION.
# First cut of this gate demanded >=2 distinct luminances from both regions
# and reported the 0.5-alpha disc as INSTRUMENT-BLIND on a run where the
# instrument was working perfectly: the disc interior is a FLAT mid grey, so
# one distinct value (127) is the CORRECT answer and 127 is itself the proof
# that the chain carries partial luminance. A gate that fails on correct
# output is worse than no gate, because it sends you to debug a healthy
# pipeline. So each region asserts on the quantity that actually discriminates
# for its own shape:
#   flat blend  -> the VALUE must be intermediate (mode near the target)
#   ramp        -> the SPREAD must be wide (many distinct values)
#
# name: (left_pt, top_pt, w_pt, h_pt, mode, arg, why)
REGIONS = {
    "HALF_ALPHA": (70, 70, 60, 60, "value", 128,
                   "0.5-alpha disc interior must blend to mid grey (~128)"),
    "GRADIENT":   (40, 210, 120, 40, "spread", 16,
                   "black->white ramp must show many luminances"),
}


def analyse(path, scale):
    w, h, px = read_ppm(path)
    print("--- %dx  (image %dx%d) ---" % (scale, w, h))
    ok = True
    for name, (lx, ly, rw, rh, mode, arg, why) in REGIONS.items():
        x0, y0 = int(lx * scale), int(ly * scale)
        sw, sh = int(rw * scale), int(rh * scale)
        # --scale scales CONTENT into the same framebuffer; a region can fall
        # off canvas. That is probe geometry, NOT a paint result.
        if x0 >= w or y0 >= h:
            print("   %-11s OUT OF FRAME at %dx (origin %d,%d vs %dx%d)"
                  " -- not a paint result" % (name, scale, x0, y0, w, h))
            continue
        ink = []
        for dy in range(sh):
            for dx in range(sw):
                x, y = x0 + dx, y0 + dy
                if x >= w or y >= h:
                    continue
                o = (y * w + x) * 3
                ink.append(px[o])
        if not ink:
            print("   %-11s PAINTED NOTHING" % name)
            ok = False
            continue
        vals = sorted(set(ink))
        mid = sum(1 for v in ink if PURE_LO < v < PURE_HI)
        if mode == "value":
            # The discriminating quantity is the VALUE, not the count. A flat
            # 50%-alpha region correctly has exactly one distinct luminance.
            mode_val = max(set(ink), key=ink.count)
            good = PURE_LO < mode_val < PURE_HI and abs(mode_val - arg) <= 12
            detail = "dominant luminance %d (need %d +/-12, and strictly " \
                     "between %d and %d)" % (mode_val, arg, PURE_LO, PURE_HI)
        else:
            good = len(vals) >= arg
            detail = "%d distinct (need >=%d)" % (len(vals), arg)
        verdict = "OK" if good else "INSTRUMENT-BLIND"
        if not good:
            ok = False
        print("   %-11s %5d px | %5d intermediate | %s -> %s"
              % (name, len(ink), mid, detail, verdict))
        print("               %s" % why)
        print("               luminances: %s%s"
              % (vals[:12], " ..." if len(vals) > 12 else ""))
    return ok


if __name__ == '__main__':
    all_ok = True
    for arg, sc in ((sys.argv[1], 1), (sys.argv[2], 2)):
        all_ok = analyse(arg, sc) and all_ok
    if all_ok:
        print("\nENG05_INSTRUMENT_PASS: the chain CAN read partial luminance, "
              "so 0.0%% partial on hard edges is a real renderer property.")
        sys.exit(0)
    print("\nENG05_INSTRUMENT_FAIL: a region could not carry intermediate "
          "values. The 0.0%% AA result is an instrument artifact, not "
          "evidence about anti-aliasing.")
    sys.exit(1)
