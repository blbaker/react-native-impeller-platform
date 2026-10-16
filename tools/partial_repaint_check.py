#!/usr/bin/env python3
"""FP-18 checker for tools/ci-partial-repaint.sh. Arg: the gate's work dir."""
import re
import sys

from PIL import Image

LINE = re.compile(r"^rn-impeller: damage frame=(\d+) seq=(\d+) base=(\d+) mode=(\w+) "
                  r"x=(-?\d+) y=(-?\d+) w=(\d+) h=(\d+) px=(\d+) surface_px=(\d+) reason=(\S+)")
MAX_PCT = 5.0


def load(work, tag):
    text = open(f"{work}/{tag}.log", errors="replace").read()
    rows = [m.groups() for m in map(LINE.match, text.splitlines()) if m]
    frames = [dict(mode=r[3], w=int(r[6]), h=int(r[7]), px=int(r[8]), surface=int(r[9]),
                   reason=r[10]) for r in rows]
    return text, frames


def require_init(tag, text, enabled):
    m = re.search(r"^rn-impeller: partial_repaint_init requested=\d enabled=(\d) reason=(\S+)",
                  text, re.M)
    if not m:
        sys.exit(f"{tag}: no partial_repaint_init line (pre-FP-18 binary?)")
    if m.group(1) != enabled:
        sys.exit(f"{tag}: partial_repaint enabled={m.group(1)} reason={m.group(2)}, want {enabled}")


def arm_a(work):
    text, frames = load(work, "spinner")
    require_init("A", text, "1")
    first = next((i for i, f in enumerate(frames) if f["mode"] == "partial"), None)
    if first is None:
        sys.exit(f"A: no partial frame in {len(frames)} presented frames")
    steady = frames[first:]
    pcts = [100.0 * f["px"] / f["surface"] for f in steady]
    worst = max(pcts)
    partial = sum(f["mode"] == "partial" for f in steady)
    full = [f["reason"] for f in steady if f["mode"] == "full"]
    print(f"A: {len(frames)} frames, warm-up {first}, steady {len(steady)}: partial={partial} "
          f"full={len(full)} max={worst:.3f}% median={sorted(pcts)[len(pcts) // 2]:.3f}% of "
          f"{steady[0]['surface']} px")
    if first > 3:
        sys.exit(f"A: {first} frames before the first partial one (want <= 3)")
    if worst > MAX_PCT:
        bad = next(f for f, p in zip(steady, pcts) if p == worst)
        sys.exit(f"A: a steady frame repainted {worst:.2f}% > {MAX_PCT}% "
                 f"(mode={bad['mode']} reason={bad['reason']})")
    if partial < 250:
        sys.exit(f"A: only {partial} partial frames (want >= 250); full reasons {set(full)}")
    m = re.search(r"^rn-impeller: partial_verify frames=(\d+) mismatched_frames=(\d+) max_px=(\d+)",
                  text, re.M)
    if not m:
        sys.exit("A: no partial_verify summary")
    verified, bad, max_px = map(int, m.groups())
    print(f"A: verify {verified} partial frames against a full repaint: {bad} mismatched "
          f"(max {max_px} px)")
    if verified < 250:
        sys.exit(f"A: only {verified} frames verified")
    if bad:
        first_bad = re.search(r"^rn-impeller: partial_verify_first .*$", text, re.M)
        sys.exit(f"A: {bad} partial frames differ from the full repaint "
                 f"({first_bad.group(0) if first_bad else ''})")


def arm_b(work):
    text, frames = load(work, "finite-on")
    require_init("B on", text, "1")
    off_text, off_frames = load(work, "finite-off")
    require_init("B off", off_text, "0")
    if off_frames:
        sys.exit(f"B: --partial-repaint off logged {len(off_frames)} damage frames")
    partial = sum(f["mode"] == "partial" and f["w"] > 0 for f in frames)
    a = Image.open(f"{work}/finite-on.png").convert("RGBA")
    b = Image.open(f"{work}/finite-off.png").convert("RGBA")
    if a.size != b.size:
        sys.exit(f"B: capture sizes differ {a.size} vs {b.size}")
    ab, bb = a.tobytes(), b.tobytes()
    diff = sum(ab[i:i + 4] != bb[i:i + 4] for i in range(0, len(ab), 4))
    print(f"B: final frame partial-on vs off: {diff} px differ of {a.size[0] * a.size[1]}; "
          f"on run had {partial} partial frames with damage")
    if partial < 30:
        sys.exit(f"B: the on run had only {partial} partial frames")
    if diff:
        sys.exit(f"B: the final frame differs from a full-repaint run in {diff} px (ghost trail?)")


def arm_c(work):
    text, frames = load(work, "wide")
    require_init("C wide", text, "1")
    steady = frames[3:]
    partial = [f for f in steady if f["mode"] == "partial" and f["w"] > 0]
    if not partial:
        sys.exit(f"C: PartialWide never partial: reasons {set(f['reason'] for f in steady)}")
    f = partial[0]
    rx, ry = f["w"] / 800.0, f["h"] / 600.0
    print(f"C: wide {len(partial)}/{len(steady)} partial, damage {f['w']}x{f['h']} "
          f"(rx={rx:.2f} ry={ry:.2f})")
    if len(partial) < 0.9 * len(steady):
        sys.exit(f"C: PartialWide partial in only {len(partial)} of {len(steady)} frames")
    if not (rx > 0.7 and 0.5 < ry <= 0.7):
        sys.exit(f"C: PartialWide damage {f['w']}x{f['h']} does not exercise the OR of the rule")
    text, frames = load(work, "huge")
    require_init("C huge", text, "1")
    steady = frames[3:]
    partial = [f for f in steady if f["mode"] == "partial" and f["w"] > 0]
    ratio = [f for f in steady if f["reason"] == "ratio"]
    print(f"C: huge {len(partial)} partial, {len(ratio)}/{len(steady)} full with reason=ratio")
    if partial:
        f = partial[0]
        sys.exit(f"C: PartialHuge went partial with damage {f['w']}x{f['h']} (> 70% both ways)")
    if len(ratio) < 0.9 * len(steady):
        sys.exit(f"C: PartialHuge reason=ratio in only {len(ratio)} of {len(steady)} frames")


def main():
    work = sys.argv[1]
    arm_a(work)
    arm_b(work)
    arm_c(work)


if __name__ == "__main__":
    main()
