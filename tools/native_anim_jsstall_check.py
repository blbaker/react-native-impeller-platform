#!/usr/bin/env python3
"""FP-10 checker for tools/ci-native-anim-jsstall.sh (arms A-D, see there)."""
import re
import statistics
import sys
from pathlib import Path

PX_PER_FRAME = 2.0
END_X = 320
ROW = re.compile(r"anim_row present=(\d+) clock=(\d+) x0=(-?\d+) x1=(-?\d+)")


def fail(msg):
    print("NAJ_FAIL: " + msg, file=sys.stderr)
    sys.exit(1)


def parse(path):
    """Returns (samples, events): samples are (present, clock, x0); events is
    the ordered list of ('row', index) / ('stall', None) markers."""
    samples, events = [], []
    for line in path.read_text(errors="replace").splitlines():
        m = ROW.search(line)
        if m:
            samples.append(tuple(int(v) for v in m.groups()[:3]))
            events.append(("row", len(samples) - 1))
        elif "jsstall n=" in line:
            events.append(("stall", None))
    if len(samples) < 50:
        fail(f"{path.name}: only {len(samples)} anim_row samples (RNI_TEST_ANIM_ROW hook missing?)")
    return samples, events


def slide_window(name, samples):
    """Indices [first moving sample, first sample at END_X or the last one] and
    whether the slide completed (checked in arm C, after the lag arm)."""
    first = next((i for i, s in enumerate(samples) if s[2] > 0), None)
    last = next((i for i, s in enumerate(samples) if s[2] >= END_X), None)
    if first is None:
        fail(f"{name}: the box never moved (x0 stayed {samples[0][2]})")
    done = last is not None and samples[last][2] == END_X
    return first, (last if last is not None else len(samples) - 1), done


def max_lag(name, samples, first, last):
    moving = [s for s in samples[first:last] if 0 < s[2] < END_X]
    if len(moving) < 20:
        fail(f"{name}: only {len(moving)} moving samples")
    lags = [s[1] - s[2] / PX_PER_FRAME for s in moving]
    return max(lags) - min(lags)


def cadence(samples, first, last):
    pairs = list(zip(samples[first:last], samples[first + 1:last + 1]))
    ok = lambda a, b: b[1] - a[1] == 1 and abs((b[2] - a[2]) - PX_PER_FRAME) <= 1
    good = sum(1 for a, b in pairs if ok(a, b))
    bad = [(a[0], b[1] - a[1], b[2] - a[2]) for a, b in pairs if not ok(a, b)][:4]
    return good, len(pairs), bad


def stalls_inside(events, first, last):
    n, inside = 0, False
    for kind, idx in events:
        if kind == "row":
            inside = first <= idx <= last
        elif inside:
            n += 1
    return n


def main(work):
    work = Path(work)
    runs = {}
    for arm in ("stall", "control"):
        for i in (1, 2, 3):
            name = f"{arm}-{i}"
            samples, events = parse(work / f"{name}.log")
            first, last, done = slide_window(name, samples)
            runs[name] = dict(arm=arm, samples=samples, first=first, last=last, done=done,
                              lag=max_lag(name, samples, first, last),
                              cad=cadence(samples, first, last),
                              stalls=stalls_inside(events, first, last))
            r = runs[name]
            print(f"  {name}: max_lag={r['lag']:.1f} frames cadence={r['cad'][0]}/{r['cad'][1]} "
                  f"stalls_in_slide={r['stalls']} complete={int(done)} "
                  f"slide=presents {samples[first][0]}..{samples[last][0]}")
    med = lambda arm: statistics.median(r["lag"] for r in runs.values() if r["arm"] == arm)
    s_med, c_med = med("stall"), med("control")
    print(f"A  lag: stall median={s_med:.1f} control median={c_med:.1f} frames (limit control+1)")
    if s_med > c_med + 1.0:
        fail(f"JS stall lag {s_med:.1f} frames > control {c_med:.1f} + 1: the NativeAnimated tick "
             f"waits on the JS thread")
    for name, r in runs.items():
        good, n, bad = r["cad"]
        if good < 0.95 * n:
            fail(f"{name}: cadence {good}/{n} present pairs advance clock+1 and x+2 (need 95%); "
                 f"first bad (present, dclock, dx): {bad}")
    print("B  cadence: every run >= 95% of present pairs advance clock+1, x+2")
    for name, r in runs.items():
        if not r["done"]:
            fail(f"{name}: the slide never reached x0={END_X} (last x0={r['samples'][-1][2]})")
        if r["arm"] == "stall" and r["stalls"] < 2:
            fail(f"{name}: only {r['stalls']} JS stalls landed inside the slide; the fixture did not block JS")
        if r["arm"] == "control" and r["stalls"] != 0:
            fail(f"{name}: control printed {r['stalls']} JS stalls")
    print("C  stalls landed inside every stall-arm slide, none in control; every slide completed")

    samples, _ = parse(work / "scroll.log")
    before = [s[2] for s in samples if s[0] <= 15]
    after = [s[2] for s in samples[-10:]]
    print(f"D  scroll event: x0 before={sorted(set(before))} last10={sorted(set(after))}")
    if set(before) != {0}:
        fail(f"scroll arm: box moved before the scroll (x0 {sorted(set(before))})")
    if any(abs(x - 200) > 2 for x in after):
        fail(f"native Animated.event did not move the box to x0=200 after the scroll "
             f"(last x0 {after[-1]}): scroll events miss the render thread")
    print(f"NATIVE_ANIM_JSSTALL_PASS stall_lag={s_med:.1f} control_lag={c_med:.1f}")


if __name__ == "__main__":
    main(sys.argv[1])
