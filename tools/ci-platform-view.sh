#!/usr/bin/env bash
# FP-44 gate: platform views (linux X11). A native child window tracks its RN
# box through scroll, translate and clip, and RN content painted after it stays
# above it (overlay surface). Model: flow/embedded_views.h (mutator stack),
# flow/view_slicer.cc (overlay rects), FlutterPlatformViewsController.mm
# submitFrame (overlays + mutators applied with the frame, raster thread).
#
# Fixture fixtures/fp44-platform-view: <ImpellerPlatformView color=#00aa00>
# 160x80 inside a ScrollView (viewport (50,60) 300x200), drawn over a magenta
# box of the same size (the marker of where RN says the view is) with a yellow
# box painted after it that overlaps it. JS scrolls 0 -> 140 (the viewport
# clips the view's top), translates 0 -> 180 (clips its right side), holds
# still between (a tick box in the header keeps frames presenting), then
# rotates 10deg (unsupported: logged, placed at the transformed bounds).
#
# RNI_TEST_PLATFORM_VIEW_PROBE, per present:
#   1. tracking: the native view's rect read back from the X server
#      (clip window ∩ content window) == the magenta box in this frame's own
#      background pixels (GL readback before the present), every present until
#      the rotation (a view one frame late fails here)
#   2. at least 25 distinct positions were presented (scroll + translate seen)
#   3. holds (hole == the hold's expected rect, settled presents): the screen
#      pixels the X server composites at 10 points: native green inside, white
#      where the viewport clips the box away (clip ignored fails here), yellow
#      where the yellow box overlaps the native view (overlay above it)
#   4. the overlay window in hold A is the yellow box ∩ the view (view_slicer)
#   5. rotate: `platform_view_unsupported` once; native ⊇ the rotated box
# ARMS: A threaded raster, B --raster-thread off, C --supersample-rnsvg 4 (root
#       supersample walk: boxes divided back to surface pixels).
# Node-free: committed bundle + staged binary (RNI_BIN overrides). Never rebuilds.
# Mutants: tools/mutation-verify-platform-view.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
. tools/lib/own-procs.sh
BUNDLE="$ROOT/fixtures/fp44-platform-view/prebuilt/fp44-platform-view.bundle"
fail() { echo "PLATFORM_VIEW_FAIL: $*" >&2; exit 1; }
[ -s "$BUNDLE" ] || fail "no committed bundle at $BUNDLE"
. tools/lib/host-window.sh
[ "$(rni_host)" = linux ] || fail "linux (Xvfb) only: the embedder is X11"
BIN="${RNI_BIN:-$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller}"
[ -x "$BIN" ] || fail "no engine binary at $BIN (run tools/engine-build.sh or set RNI_BIN)"
echo "engine: $BIN ($(shasum -a 256 "$BIN" | cut -c1-12))"

WORK="$(mktemp -d)"
cleanup() { rni_kill_own; [ "${KEEP_WORKDIR:-0}" = 1 ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

POINTS="120,200;225,205;265,205;70,200;120,80;120,50;225,70;300,80;370,80;300,50"
COMMON=(--window --scale 1 --width 400 --height 300 --probe-banner off
        --app-name PlatformView --bundle "$BUNDLE"
        --initial-url "fp44://run?step=50&hold=1000&boot=800" --idle-run-sec 11)

check_log() {  # log tag
  python3 - "$1" "$2" <<'PY' || exit 1
import os, re, sys
POINTS = os.environ["POINTS"].split(";")
log = open(sys.argv[1], errors="replace").read(); tag = sys.argv[2]
def bad(m): print("PLATFORM_VIEW_FAIL: %s: %s" % (tag, m), file=sys.stderr); sys.exit(1)
if not re.search(r"^rn-impeller: platform_view_embedder ok=1 kind=x11", log, re.M):
    bad("no `platform_view_embedder ok=1 kind=x11` line (no native embedder)")
for ph in ("holdA", "scroll", "holdB", "move", "holdC", "rotate", "done"):
    if "FP44 phase=%s" % ph not in log: bad("JS never reached phase %s" % ph)
uns = re.findall(r"^rn-impeller: platform_view_unsupported tag=(\d+) mutator=transform", log, re.M)
if len(uns) != 1: bad("%d platform_view_unsupported lines, wanted 1 (rotate)" % len(uns))
rot_at = log.index("platform_view_unsupported")
def rect(s): return None if s == "-" else tuple(int(v) for v in s.split(","))
pres = {}
for m in re.finditer(r"^rn-impeller: pv_probe present=(\d+) frame=(\d+) hole=(\S+) views=(\d+)", log, re.M):
    pres[int(m.group(1))] = {"hole": rect(m.group(3)), "views": int(m.group(4)), "rot": m.start() > rot_at}
for m in re.finditer(r"^rn-impeller: pv_view present=(\d+) tag=(\d+) native=(\S+) mapped=(\d) overlay=(\S+)", log, re.M):
    p = pres.get(int(m.group(1)))
    if p is not None: p.update(native=rect(m.group(3)), mapped=int(m.group(4)), overlay=rect(m.group(5)))
for m in re.finditer(r"^rn-impeller: pv_screen present=(\d+) px=(\S+)", log, re.M):
    p = pres.get(int(m.group(1)))
    if p is not None: p["px"] = [tuple(int(v) for v in q.split(",")) if q != "-" else None for q in m.group(2).split(";")]
if len(pres) < 60: bad("only %d probed presents" % len(pres))
def near(a, b, tol=1): return a is not None and b is not None and all(abs(x - y) <= tol for x, y in zip(a, b))
def contains(a, b): return a is not None and b is not None and a[0] <= b[0] + 1 and a[1] <= b[1] + 1 and a[2] >= b[2] - 1 and a[3] >= b[3] - 1
tracked = set(); rotated = 0; prev = None
for n in sorted(pres):
    p = pres[n]
    if p["views"] != 1 or "native" not in p: bad("present %d: %d views probed, wanted 1" % (n, p["views"]))
    if p["rot"]:
        rotated += 1
        if not contains(p["native"], p["hole"]):
            bad("present %d (rotated): native %s does not cover the box %s" % (n, p["native"], p["hole"]))
        continue
    if p["hole"] is None:
        if p["native"] is not None: bad("present %d: native view shown at %s with no box on screen" % (n, p["native"]))
        continue
    if not near(p["native"], p["hole"]):
        if prev is not None and near(p["native"], prev) and not near(p["hole"], prev):
            bad("present %d: native view at %s is the previous frame's box, this frame's is %s (one frame late)" % (n, p["native"], p["hole"]))
        if contains(p["native"], p["hole"]):
            bad("present %d: native view %s covers more than this frame's visible box %s (clip ignored)" % (n, p["native"], p["hole"]))
        bad("present %d: native view at %s but this frame's box is %s" % (n, p["native"], p["hole"]))
    tracked.add(p["hole"])
    prev = p["hole"]
if len(tracked) < 25: bad("only %d distinct positions tracked, wanted >= 25 (no motion?)" % len(tracked))
if rotated < 3: bad("only %d rotated presents" % rotated)
G, Y, W = (0, 170, 0), (255, 255, 0), (255, 255, 255)
HOLDS = {
    "A": ((90, 160, 250, 240), [G, Y, Y, W, W, W, W, W, W, W]),
    "B": ((90, 60, 250, 100), [W, W, W, W, G, W, Y, W, W, W]),
    "C": ((270, 60, 350, 100), [W, W, W, W, W, W, W, G, W, W]),
}
settled = {}
names = ["view", "overlap", "yellow-out", "viewport", "view-B", "clip-top-B", "overlap-B", "view-C", "clip-right-C", "clip-top-C"]
for h, (hole, want) in HOLDS.items():
    ns = [n for n in sorted(pres) if pres[n]["hole"] == hole and not pres[n]["rot"]]
    ns = ns[2:]  # settled: the X server has every connection's requests by then
    if len(ns) < 5: bad("hold %s: only %d settled presents" % (h, len(ns)))
    settled[h] = len(ns)
    for n in ns:
        px = pres[n].get("px")
        if px is None: bad("hold %s present %d: no screen readback" % (h, n))
        for i, (got, exp) in enumerate(zip(px, want)):
            if got is None or any(abs(a - b) > 6 for a, b in zip(got, exp)):
                bad("hold %s present %d: screen at %s (%s) is %s, wanted %s" % (h, n, POINTS[i], names[i], got, exp))
    if h == "A":
        ov = pres[ns[-1]]["overlay"]
        if ov != (200, 190, 250, 220): bad("hold A: overlay window %s, wanted (200, 190, 250, 220) (yellow ∩ view)" % (ov,))
summ = re.search(r"^rn-impeller: platform_views_summary embedder=x11 frames=(\d+) views_max=(\d+) overlay_draws=(\d+) created=(\d+) destroyed=(\d+)", log, re.M)
if not summ: bad("no platform_views_summary line")
if int(summ.group(3)) == 0: bad("no overlay was drawn")
if summ.group(4) != summ.group(5): bad("windows created %s != destroyed %s at teardown" % (summ.group(4), summ.group(5)))
print("%s: OK presents=%d tracked_positions=%d rotated=%d overlay_draws=%s settled=A%d,B%d,C%d" % (tag, len(pres), len(tracked), rotated, summ.group(3), settled["A"], settled["B"], settled["C"]))
PY
}

run_arm() {  # tag [extra args...]
  local tag="$1"; shift
  local log="$WORK/$tag.log" rc=0
  echo "== $tag =="
  (
    export RNI_TEST_PLATFORM_VIEW_PROBE="$POINTS"
    rni_xrun "$WORK/x$tag" timeout 120 "$BIN" "${COMMON[@]}" "$@"
  ) > "$log" 2>&1 || rc=$?
  [ "$rc" = 0 ] || { tail -15 "$log" >&2; fail "$tag: exit $rc"; }
  grep -q '^RN_IMPELLER_WINDOW_OK' "$log" || fail "$tag: no RN_IMPELLER_WINDOW_OK"
  POINTS="$POINTS" check_log "$log" "$tag"
}

run_arm A --supersample-rnsvg 0
run_arm B --supersample-rnsvg 0 --raster-thread off
run_arm C --supersample-rnsvg 4
echo "PLATFORM_VIEW_PASS"
