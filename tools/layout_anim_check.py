#!/usr/bin/env python3
"""FP-40 checker for tools/ci-layout-animation.sh.

usage: layout_anim_check.py animated <log>...   (Fp40LayoutAnim runs)
       layout_anim_check.py snap <log>          (Fp40Snap control)

Each present prints `anim_row ... x1=` (last red column on row 50: bar A's right edge, 79 at width 60,
379 at width 360) and `anim_px ... g=` (pixel 200,190 inside box B: 255 = white/absent, 0 = opaque red,
so opacity = 1 - g/255). RNI_LAYOUT_ANIM_LOG=1 adds `layout_anim_started t_ms=` and, per animated
frame, `layout_anim_tick n= t_ms=` (the KFM clock that frame was interpolated at). The expected curve is
RN's EaseInEaseOut (animations/utils.cpp calculateAnimationProgress): (1 - cos(pi * u)) / 2, u = t / 300.
"""
import math
import re
import statistics
import sys

X_FROM, X_TO = 79, 379
DURATION_MS = 300.0
MIN_INTERMEDIATE = 10
MAX_CURVE_ERR = 0.06  # progress units; pixel rounding is 1/300, the start stamp is +-1 ms (0.02 mid-curve)
ARMS = ("update", "create", "delete")


def fail(msg):
    print("LAYOUT_ANIM_FAIL: " + msg)
    sys.exit(1)


def parse(path):
    """Returns (starts, presents, steps). presents: dict(x1, g, t) with t = tick time or None."""
    starts, presents, steps = [], [], []
    tick = None
    pending = None
    # FP-57: ticks print on main, anim_row on the raster thread, so under load the next frame's
    # tick can print before this present. Main's `anim_frame frame=` (printed when it records the
    # frame, after that frame's tick) pairs each present with its own tick by frame number.
    frame_tick = {}
    for line in open(path, errors="replace"):
        m = re.search(r"anim_frame frame=(\d+)", line)
        if m:
            frame_tick[int(m.group(1))] = tick
            tick = None
            continue
        m = re.search(r"fp40 step=(\w+)", line)
        if m:
            steps.append(m.group(1))
        m = re.search(r"layout_anim_started t_ms=(\d+)", line)
        if m:
            starts.append((int(m.group(1)), len(presents) + (1 if pending else 0)))
        m = re.search(r"layout_anim_tick n=\d+ t_ms=(\d+)", line)
        if m:
            tick = int(m.group(1))
        m = re.search(r"anim_row present=(\d+) clock=\d+ x0=-?\d+ x1=(-?\d+)(?: frame=(\d+))?", line)
        if m:
            if pending:
                presents.append(pending)
            if m.group(3) is not None:
                if int(m.group(3)) not in frame_tick:
                    fail("%s: present of frame %s with no anim_frame line before it" % (path, m.group(3)))
                t = frame_tick[int(m.group(3))]
            else:
                t = tick
                tick = None
            pending = {"x1": int(m.group(2)), "g": None, "t": t}
        m = re.search(r"anim_px present=\d+ r=\d+ g=(\d+)", line)
        if m and pending:
            pending["g"] = int(m.group(1))
    if pending:
        presents.append(pending)
    return starts, presents, steps


def progress(arm, p):
    if arm == "update":
        return (p["x1"] - X_FROM) / float(X_TO - X_FROM)
    if p["g"] is None:
        return None
    return 1.0 - p["g"] / 255.0 if arm == "create" else p["g"] / 255.0


def curve(u):
    u = min(max(u, 0.0), 1.0)
    return (1.0 - math.cos(math.pi * u)) / 2.0


def check_animated(path):
    starts, presents, steps = parse(path)
    if steps != list(ARMS):
        fail("%s: JS steps %s, want %s" % (path, steps, list(ARMS)))
    if not presents:
        fail("%s: no anim_row lines (RNI_TEST_ANIM_ROW probe missing)" % path)
    inter = sum(1 for p in presents if X_FROM < p["x1"] < X_TO)
    if inter < MIN_INTERMEDIATE:
        if not starts:
            why = "snapped: configureNext reached no animation delegate, 0 layout_anim_started"
        elif not any(p["t"] is not None for p in presents):
            why = "stalled: %d animations started but no layout_anim_tick ran on the platform thread " \
                  "(no animationTick)" % len(starts)
        else:
            why = "too few ticked frames"
        fail("%s: update arm: %d intermediate frames between width 60 and 360, want >= %d (LayoutAnimation %s)"
             % (path, inter, MIN_INTERMEDIATE, why))
    if len(starts) != 3:
        fail("%s: %d layout_anim_started lines, want 3 (one per configureNext)" % (path, len(starts)))
    errs = []
    for i, arm in enumerate(ARMS):
        t0, first = starts[i]
        end = starts[i + 1][1] if i + 1 < len(starts) else len(presents)
        seg = presents[first:end]
        vals = [(progress(arm, p), p["t"]) for p in seg]
        if any(v is None for v, _ in vals):
            fail("%s: %s arm: no anim_px samples (RNI_TEST_ANIM_PIXEL probe missing)" % (path, arm))
        mids = [(v, t) for v, t in vals if 0.01 < v < 0.99 and t is not None]
        if len(mids) < MIN_INTERMEDIATE:
            fail("%s: %s arm: %d intermediate frames, want >= %d (values %s)"
                 % (path, arm, len(mids), MIN_INTERMEDIATE, [round(v, 2) for v, _ in vals[:30]]))
        prev = -1.0
        for v, _ in vals:
            if v < prev - 0.02:
                fail("%s: %s arm: progress went backwards %.3f -> %.3f" % (path, arm, prev, v))
            prev = max(prev, v)
        if vals[-1][0] < 0.99:
            fail("%s: %s arm: ended at progress %.3f, never reached the final layout" % (path, arm, vals[-1][0]))
        worst = max(abs(v - curve((t - t0) / DURATION_MS)) for v, t in mids)
        errs.append(worst)
        print("%s %s: intermediate=%d max_curve_err=%.3f" % (path.rsplit("/", 1)[-1], arm, len(mids), worst))
    return max(errs)


def check_snap(path):
    starts, presents, steps = parse(path)
    if steps != list(ARMS):
        fail("%s: JS steps %s, want %s" % (path, steps, list(ARMS)))
    if starts:
        fail("%s: control started %d layout animations without configureNext" % (path, len(starts)))
    inter_x = sum(1 for p in presents if X_FROM < p["x1"] < X_TO)
    inter_g = sum(1 for p in presents if p["g"] is not None and 3 < p["g"] < 252)
    if inter_x or inter_g:
        fail("%s: control (no configureNext) showed %d/%d intermediate frames; the gate's "
             "intermediate detector is not measuring LayoutAnimation" % (path, inter_x, inter_g))
    if presents[-1]["x1"] != X_TO or not any(p["g"] == 0 for p in presents) or presents[-1]["g"] != 255:
        fail("%s: control did not reach the final layout (bar x1=%d, box created+deleted?)"
             % (path, presents[-1]["x1"]))
    print("%s: control snapped (0 intermediate frames)" % path.rsplit("/", 1)[-1])


def main():
    mode, logs = sys.argv[1], sys.argv[2:]
    if mode == "snap":
        check_snap(logs[0])
        return
    worst = [check_animated(p) for p in logs]
    med = statistics.median(worst)
    print("median max_curve_err=%.3f (limit %.2f)" % (med, MAX_CURVE_ERR))
    if med > MAX_CURVE_ERR:
        fail("frames do not follow the easeInEaseOut curve: median max error %.3f > %.2f" % (med, MAX_CURVE_ERR))
    print("LAYOUT_ANIM_OK")


if __name__ == "__main__":
    main()
