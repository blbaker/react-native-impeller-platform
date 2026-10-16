#!/usr/bin/env bash
# FP-30 gate: resize synchronizer + stale-size discard.
# Model: macOS ResizeSynchronizer.swift (the platform thread does not hand a
# resize back to the OS until a frame at the new size presented, 1 s cap) and
# shell.cc Shell::ShouldDiscardLayerTree (a frame recorded for another size
# than the surface's current one is dropped by the rasterizer).
#
# Fixture fixtures/fp30-resize-geometry (ResizeGeometry): a 100x100 pt red
# square centred in a black root. RNI_TEST_RESIZE_PROBE=1 reads back every
# present and measures the square's aspect AS DISPLAYED (a w x h frame shown
# on a W x H window is stretched by W/w, H/h, as CAMetalLayer and DXGI do).
#
# ARMS
#   A  10 random fast resizes (one every 4 loop frames, seed RESIZE_SEED) with
#      the raster thread slowed to 30 ms/frame, so old-size frames are always
#      queued when a resize lands. Every present: frame size == the window size
#      it was admitted against, square found, aspect_err <= 0.02. Every
#      resize_capture (main, the moment the resize returns to the OS): the
#      last presented frame == the window size, aspect_err <= 0.02. 10
#      resize_sync result=ok, >= 1 frame_discarded reason=size (the stale
#      frames really existed), consumed == presents + discarded, draw_failed=0.
#   B  the raster thread hangs on the first new-size frame
#      (RNI_TEST_RASTER_HANG_AFTER_RESIZE=1): resize_sync result=timeout after
#      ~1 s, and the run still exits 0 (rc 124 = the platform thread hung).
#   C  --raster-thread off: the same resizes present inline, every sync ok,
#      every present at the window size (frames recorded between the announce
#      and GLFW's resize report are discarded, ~1 per resize).
# Node-free: committed bundle + RNI_BIN. Mutants: tools/mutation-verify-resize-geometry.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
. tools/lib/own-procs.sh
. tools/lib/wait-for.sh
BUNDLE="$ROOT/fixtures/fp30-resize-geometry/prebuilt/fp30-resize-geometry.bundle"
fail() { echo "RESIZE_GEOMETRY_FAIL: $*" >&2; exit 1; }
[ -s "$BUNDLE" ] || fail "no committed bundle at $BUNDLE"
. tools/lib/host-window.sh
[ "$(rni_host)" != other ] || fail "linux (Xvfb) or darwin only"
if [ -n "${RNI_BIN:-}" ]; then
  BIN="$RNI_BIN"
else
  bash tools/engine-build.sh linux x64 > "${TMPDIR:-/tmp}/ci-resize-geometry-build.log" 2>&1 \
    || { tail -20 "${TMPDIR:-/tmp}/ci-resize-geometry-build.log" >&2; fail "engine build failed"; }
  BIN="$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller"
fi
[ -x "$BIN" ] || fail "no engine binary at $BIN (set RNI_BIN)"
echo "engine: $BIN ($(shasum -a 256 "$BIN" | cut -c1-12)) host=$(rni_host)"

WORK="$(mktemp -d)"
cleanup() { rni_kill_own; [ "${KEEP_WORKDIR:-0}" = 1 ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT
COMMON=(--window --scale 1 --width 400 --height 300 --supersample-rnsvg 0 --probe-banner off
        --bundle "$BUNDLE" --app-name ResizeGeometry)

SEED="${RESIZE_SEED:-$RANDOM}"
SEQ="$(python3 - "$SEED" <<'PY'
import random, sys
r = random.Random(int(sys.argv[1])); prev = (400, 300); out = []
for i in range(10):
    while True:
        s = (r.randrange(240, 721, 2), r.randrange(200, 561, 2))
        if s != prev: break
    out.append("%d:%dx%d" % (20 + 4 * i, s[0], s[1])); prev = s
print(",".join(out))
PY
)"
echo "seed=$SEED sequence=$SEQ"

check_log() {  # log tag mode(threaded|inline)
  python3 - "$1" "$2" "$3" "$SEQ" <<'PY' || exit 1
import re, sys
log = open(sys.argv[1], errors="replace").read(); tag, mode, seq = sys.argv[2:5]
def bad(m): print("RESIZE_GEOMETRY_FAIL: %s: %s" % (tag, m), file=sys.stderr); sys.exit(1)
want = [tuple(map(int, s.split(":")[1].split("x"))) for s in seq.split(",")]
# Requested sizes are window points; a 2x (Retina) framebuffer has 2 px per point.
w0 = re.search(r"^rn-impeller: window px=(\d+)x\d+ ", log, re.M)
if not w0: bad("no window line")
k = int(w0.group(1)) // 400
want = [(a * k, b * k) for a, b in want]
got = [(int(a), int(b)) for a, b in re.findall(r"^rn-impeller: resize px=(\d+)x(\d+) ", log, re.M)]
if got != want: bad("applied resizes %s != requested %s" % (got, want))
syncs = re.findall(r"^rn-impeller: resize_sync n=(\d+) size=(\d+)x(\d+) result=(\w+) waited_us=(\d+)", log, re.M)
if len(syncs) != len(want): bad("%d resize_sync lines for %d resizes" % (len(syncs), len(want)))
probes = re.findall(r"^rn-impeller: resize_probe present=(\d+) frame=(\d+)x(\d+) window=(\d+)x(\d+) "
                    r"square=(-?\d+),(-?\d+),(\d+)x(\d+) aspect_err=([\d.]+)", log, re.M)
presents = int(re.findall(r"^rn-impeller: presents=(\d+)", log, re.M)[-1])
if len(probes) != presents: bad("%d probe lines for %d presents" % (len(probes), presents))
for p in probes:
    n, fw, fh, ww, wh, bw, bh, err = int(p[0]), int(p[1]), int(p[2]), int(p[3]), int(p[4]), int(p[7]), int(p[8]), float(p[9])
    if (fw, fh) != (ww, wh):
        bad("stale-size frame presented: present %d is %dx%d on a %dx%d window" % (n, fw, fh, ww, wh))
    if bw == 0 or bh == 0: bad("present %d: no reference square in the frame" % n)
    if err > 0.02: bad("present %d: square aspect error %.4f > 0.02 (%dx%d)" % (n, err, bw, bh))
caps = re.findall(r"^rn-impeller: resize_capture n=(\d+) window=(\d+)x(\d+) frame=(\d+)x(\d+) aspect_err=([\d.]+)", log, re.M)
if len(caps) != len(want): bad("%d resize_capture lines for %d resizes" % (len(caps), len(want)))
for c in caps:
    n, ww, wh, fw, fh, err = int(c[0]), int(c[1]), int(c[2]), int(c[3]), int(c[4]), float(c[5])
    if (fw, fh) != (ww, wh):
        bad("resize %d returned to the OS showing a %dx%d frame on a %dx%d window (no wait)" % (n, fw, fh, ww, wh))
    if err > 0.02: bad("resize %d capture: aspect error %.4f > 0.02" % (n, err))
notok = [s for s in syncs if s[3] != "ok"]
if notok: bad("resize_sync not ok: %s" % (notok[:3],))
disc = len(re.findall(r"^rn-impeller: frame_discarded reason=size ", log, re.M))
summ = re.search(r"^rn-impeller: resize_sync_summary .* discarded=(\d+)", log, re.M)
if not summ or int(summ.group(1)) != disc: bad("discard count mismatch (%d lines, %s)" % (disc, summ and summ.group(0)))
if mode == "threaded" and disc < 1: bad("no stale frame was ever queued: the fixture cannot see the defect")
p = re.search(r"^rn-impeller: pipeline depth=(\d+) produced=(\d+) consumed=(\d+)", log, re.M)
if not p or int(p.group(3)) != presents + disc:
    bad("consumed %s != presents %d + discarded %d" % (p and p.group(3), presents, disc))
if not re.search(r"^rn-impeller: raster_thread_summary .*draw_failed=0 ", log, re.M): bad("a frame failed to draw")
waits = sorted(int(s[4]) for s in syncs)
print("%s: OK resizes=%d presents=%d discarded=%d captures=%d max_aspect_err=%.4f sync_wait_us median=%d max=%d"
      % (tag, len(got), presents, disc, len(caps), max(float(x[9]) for x in probes), waits[len(waits) // 2], waits[-1]))
PY
}

echo "== A: 10 random fast resizes, slow raster (30 ms/frame) =="
log="$WORK/a.log"; rc=0
RNI_TEST_RESIZE_PROBE=1 RNI_TEST_RASTER_DELAY_MS=30 rni_xrun "$WORK/xa" timeout 180 "$BIN" "${COMMON[@]}" \
  --frames 70 --resize-sequence "$SEQ" > "$log" 2>&1 || rc=$?
[ "$rc" = 124 ] && fail "A: run hung (rc 124)"
[ "$rc" = 0 ] || { tail -15 "$log" >&2; fail "A: exit $rc"; }
grep -q '^RN_IMPELLER_WINDOW_OK' "$log" || fail "A: no RN_IMPELLER_WINDOW_OK"
grep -q '^rn-impeller: raster_thread threaded=1 depth=2 ' "$log" || fail "A: not a depth-2 raster thread"
check_log "$log" A threaded

echo "== B: raster hangs on the new-size frame: the wait gives up after 1 s =="
log="$WORK/b.log"; rc=0
# After the hang every loop frame waits 2 x 1 s for a pipeline slot: 14 frames ~ 28 s. Those waits
# scale with RNI_TIME_SCALE (4 under ci-sanitize: ~112 s), so the hang ceiling scales too (FP-57).
RNI_TEST_RASTER_HANG_AFTER_RESIZE=1 RNI_TEST_RASTER_DELAY_MS=30 rni_xrun "$WORK/xb" timeout "$(( $(rni_scaled 60000) / 1000 ))" "$BIN" "${COMMON[@]}" \
  --frames 20 --resize-sequence "6:520x340" > "$log" 2>&1 || rc=$?
[ "$rc" = 124 ] && fail "B: hang: the platform thread waited for the resize frame without a timeout (rc 124)"
[ "$rc" = 0 ] || { tail -15 "$log" >&2; fail "B: exit $rc"; }
python3 - "$log" "$(rni_scaled 1000)" <<'PY' || { grep -E 'resize|raster_test_hang|presents=' "$log" | head -8 >&2; exit 1; }
import re, sys
log = open(sys.argv[1], errors="replace").read(); cap_ms = float(sys.argv[2])
def bad(m): print("RESIZE_GEOMETRY_FAIL: B: %s" % m, file=sys.stderr); sys.exit(1)
w0 = re.search(r"^rn-impeller: window px=(\d+)x\d+ ", log, re.M)
k = int(w0.group(1)) // 400 if w0 else 1  # 2 on a Retina framebuffer
size = "%dx%d" % (520 * k, 340 * k)
if "raster_test_hang size=%s" % size not in log: bad("the raster test hang never armed (%s)" % size)
s = re.search(r"^rn-impeller: resize_sync n=1 size=%s result=(\w+) waited_us=(\d+)" % size, log, re.M)
if not s: bad("no resize_sync line")
if s.group(1) != "timeout": bad("result=%s, expected timeout" % s.group(1))
w = int(s.group(2)) / 1000.0
if not (cap_ms - 5 <= w <= cap_ms + 1500): bad("waited %.0f ms, cap is %.0f ms" % (w, cap_ms))
print("B: OK timeout after %.0f ms (cap %.0f ms)" % (w, cap_ms))
PY

echo "== C: --raster-thread off presents inline, never a stale size =="
log="$WORK/c.log"; rc=0
RNI_TEST_RESIZE_PROBE=1 RNI_TEST_RASTER_DELAY_MS=30 rni_xrun "$WORK/xc" timeout 180 "$BIN" "${COMMON[@]}" --raster-thread off \
  --frames 70 --resize-sequence "$SEQ" > "$log" 2>&1 || rc=$?
[ "$rc" = 0 ] || { tail -15 "$log" >&2; fail "C: exit $rc"; }
check_log "$log" C inline

echo "RESIZE_GEOMETRY_PASS seed=$SEED"
