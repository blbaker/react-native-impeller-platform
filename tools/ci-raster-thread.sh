#!/usr/bin/env bash
# FP-15 GATE: windowed RASTER runs on a dedicated raster thread that owns the GL
# context; main keeps events, input, mount, NativeAnimated, scheduling and RECORD.
# Model: flutter shell/common/rasterizer.cc + shell.cc (OnAnimatorDraw,
# OnPlatformViewDestroyed), pipeline depth 2 (animator.cc).
#
# fixtures/fp15-raster-thread (RasterTear) + native-transform, windowed 400x300
# --scale 1 on $DISPLAY (the job's private Xvfb; one is started if unset).
#   A  main stall: --main-stall-after-frames 60:50 makes main sleep 50 ms right
#      after it recorded frame 60, with that item queued (the raster thread holds
#      it ~10 ms first; both scale with RNI_TIME_SCALE). RNI_TEST_RASTER_LOG=1 stamps every present. That item
#      must present DURING the stall: median over 3 runs of (present - stall
#      begin) lies in (0, stall length); every run reports presents_during >= 1
#      and every present on a thread other than main.
#   B  1000 commits racing raster: the 12 boxes share one colour per commit and
#      RNI_TEST_UNIFORM_PROBE reads every present back on the raster thread. Runs
#      until JS logs FP15_COMMITS n=1000 and 30 frames presented, then quits: torn=0, >= 3 distinct
#      colours on screen, >= 30 presents. Two runs: raster delay 0 and 3 ms.
#   C  quit mid-animation x20 (NativeRotateProbe, --quit-on-term, TERM 150-640 ms
#      after the first present, raster delay alternating 0 / 20 ms): exit 0,
#      WINDOW_OK, draw_failed=0, produced == consumed == presents, and the GPU
#      objects were released on the raster thread with its GL context current
#      (`gpu_release gl_current=1 tid=<raster>`). B's two quits are held to the same.
# Node-free: committed bundles + RNI_BIN.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
. tools/lib/own-procs.sh
. tools/lib/wait-for.sh
TEAR="$ROOT/fixtures/fp15-raster-thread/prebuilt/fp15-raster-thread.bundle"
ROT="$ROOT/fixtures/native-transform/prebuilt/native-transform.bundle"
fail() { echo "RASTER_THREAD_FAIL: $*" >&2; exit 1; }
[ -s "$TEAR" ] || fail "no committed bundle at $TEAR"
[ -s "$ROT" ] || fail "no committed bundle at $ROT"
. tools/lib/host-window.sh
# darwin (FP-19): real window server, no Xvfb; run through tools/parity-mac.sh gate.
[ "$(rni_host)" != other ] || fail "linux (Xvfb) or darwin only"
if [ -n "${RNI_BIN:-}" ]; then
  BIN="$RNI_BIN"
else
  bash tools/engine-build.sh linux x64 > "${TMPDIR:-/tmp}/ci-raster-thread-build.log" 2>&1 \
    || { tail -20 "${TMPDIR:-/tmp}/ci-raster-thread-build.log" >&2; fail "engine build failed"; }
  BIN="$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller"
fi
[ -x "$BIN" ] || fail "no engine binary at $BIN (set RNI_BIN)"
echo "engine: $BIN ($(shasum -a 256 "$BIN" | cut -c1-12)) host=$(rni_host)"

WORK="$(mktemp -d)"
XPID=""
cleanup() {
  rni_kill_own
  [ -n "$XPID" ] && kill "$XPID" 2> /dev/null || true
  [ "${KEEP_WORKDIR:-0}" = 1 ] && echo "workdir kept: $WORK" || rm -rf "$WORK"
}
trap cleanup EXIT
if [ "$(rni_host)" = linux ] && [ -z "${DISPLAY:-}" ]; then
  for n in $(seq 160 199); do [ -e "/tmp/.X11-unix/X$n" ] || break; done
  Xvfb ":$n" -screen 0 1280x1024x24 -nolisten tcp > "$WORK/xvfb.log" 2>&1 & XPID=$!
  export DISPLAY=":$n"
  for _ in $(seq 50); do [ -e "/tmp/.X11-unix/X$n" ] && break; sleep 0.1; done
fi
echo "DISPLAY=${DISPLAY:-} host=$(rni_host)"
# The stall scales with RNI_TIME_SCALE (ci-sanitize / ci-tsan export 4), like every FP-06 ceiling.
STALL_MS="$(awk -v s="$(rni_scaled 50)" 'BEGIN { printf "%d", s }')"
BOXES="50,50;140,50;230,50;320,50;50,140;140,140;230,140;320,140;50,230;140,230;230,230;320,230"
COMMON=(--window --scale 1 --width 400 --height 300 --supersample-rnsvg 0 --probe-banner off)

# The GPU objects were released on the raster thread with its context current
# (read back at release time). Checked before the exit code: a context torn
# down under the raster thread often ends in a crash.
teardown_ok() {  # log tag
  python3 - "$1" "$2" <<'PY' || exit 1
import re, sys
log = open(sys.argv[1], errors="replace").read(); tag = sys.argv[2]
def bad(m): print("RASTER_THREAD_FAIL: %s: %s" % (tag, m), file=sys.stderr); sys.exit(1)
rt = re.search(r"^rn-impeller: raster_thread threaded=\d depth=\d+ main_tid=(\d+) raster_tid=(\d+)", log, re.M)
g = re.findall(r"^rn-impeller: gpu_release gl_current=(\d) tid=(\d+)", log, re.M)
if not rt: bad("no raster_thread line")
if len(g) > 1: bad("%d gpu_release lines" % len(g))
if g and g[0][0] != "1": bad("GPU objects released with NO GL context current (tid %s)" % g[0][1])
if g and g[0][1] != rt.group(2):
    bad("GPU objects released on tid %s, not the raster thread %s (main %s)" % (g[0][1], rt.group(2), rt.group(1)))
PY
}

# Fields of the raster summary lines.
summary_ok() {  # log tag
  local log="$1" tag="$2" pl
  grep -q '^RN_IMPELLER_WINDOW_OK' "$log" || fail "$tag: no RN_IMPELLER_WINDOW_OK"
  grep -q '^rn-impeller: raster_thread threaded=1 depth=2 ' "$log" || fail "$tag: not running a depth-2 raster thread ($(grep -m1 '^rn-impeller: raster_thread ' "$log"))"
  grep -q '^rn-impeller: raster_thread_summary .*draw_failed=0 ' "$log" \
    || fail "$tag: a frame failed to draw ($(grep -m1 raster_thread_summary "$log"))"
  pl="$(grep -m1 '^rn-impeller: pipeline depth=' "$log")" || fail "$tag: no pipeline line"
  python3 - "$log" "$tag" <<'PY' || exit 1
import re, sys
log = open(sys.argv[1]).read(); tag = sys.argv[2]
def bad(m): print("RASTER_THREAD_FAIL: %s: %s" % (tag, m), file=sys.stderr); sys.exit(1)
p = re.search(r"^rn-impeller: pipeline depth=(\d+) produced=(\d+) consumed=(\d+)", log, re.M)
presents = int(re.findall(r"^rn-impeller: presents=(\d+)", log, re.M)[-1])
if not (int(p.group(2)) == int(p.group(3)) == presents):
    bad("produced=%s consumed=%s presents=%d" % (p.group(2), p.group(3), presents))
rt = re.search(r"^rn-impeller: raster_thread threaded=1 depth=2 main_tid=(\d+) raster_tid=(\d+)", log, re.M)
g = re.findall(r"^rn-impeller: gpu_release gl_current=(\d) tid=(\d+)", log, re.M)
if len(g) != 1: bad("expected one gpu_release line, got %d" % len(g))
PY
}

echo "== A: a $STALL_MS ms main-thread stall with a frame queued still presents =="
for i in 1 2 3; do
  log="$WORK/a-$i.log"; rc=0
  RNI_TEST_RASTER_LOG=1 timeout 120 "$BIN" "${COMMON[@]}" --bundle "$TEAR" --app-name RasterTear \
    --frames 120 --main-stall-after-frames "60:$STALL_MS" > "$log" 2>&1 || rc=$?
  teardown_ok "$log" "A run $i"
  [ "$rc" = 0 ] || { tail -15 "$log" >&2; fail "A run $i exited $rc"; }
  grep -qE '^rn-impeller: scene_nodes=[1-9]' "$log" || fail "A run $i: nothing mounted"
done
python3 - "$WORK" <<'PY' || fail "A: see above"
import re, statistics, sys
w = sys.argv[1]; deltas = []; late = []
for i in (1, 2, 3):
    log = open("%s/a-%d.log" % (w, i)).read()
    b = re.search(r"^rn-impeller: main_stall_begin frame=\d+ item=(\d+) ms=(\d+) t_us=(\d+)", log, re.M)
    e = re.search(r"^rn-impeller: main_stall_end presents_during=(\d+) t_us=(\d+)", log, re.M)
    if not b or not e: print("A run %d: no main_stall_begin/end lines" % i); sys.exit(1)
    item, t0, during, t1 = b.group(1), int(b.group(3)), int(e.group(1)), int(e.group(2))
    rt = re.search(r"^rn-impeller: raster_thread threaded=\d depth=\d+ main_tid=(\d+) raster_tid=(\d+)", log, re.M)
    pres = re.findall(r"^rn-impeller: raster_present n=\d+ frame=(\d+) t_us=(\d+) tid=(\d+)", log, re.M)
    if not rt or not pres: print("A run %d: no raster_thread / raster_present lines" % i); sys.exit(1)
    hit = [int(p[1]) for p in pres if p[0] == item]
    if len(hit) != 1: print("A run %d: frame %s presented %d times" % (i, item, len(hit))); sys.exit(1)
    d = hit[0] - t0; deltas.append((d, t1 - t0))
    print("   run %d: frame %s presented %+.2f ms after the stall began (stall %.1f ms), presents_during=%d"
          % (i, item, d / 1000.0, (t1 - t0) / 1000.0, during))
    on_main = [p for p in pres if p[2] == rt.group(1)]
    if on_main: late.append("A run %d: %d presents ran on the main thread" % (i, len(on_main)))
    if during < 1: late.append("A run %d: presents_during=0 (nothing reached the screen while main slept)" % i)
med = statistics.median(d for d, _ in deltas); stall = statistics.median(s for _, s in deltas)
if med <= 0:
    print("A: the queued frame presented %.2f ms BEFORE the stall began (median): raster ran on the platform thread" % (-med / 1000.0)); sys.exit(1)
if med >= stall:
    print("A: the queued frame presented %.1f ms after the stall began, past its %.1f ms end (median): raster waited for main" % (med / 1000.0, stall / 1000.0)); sys.exit(1)
if late: print(late[0]); sys.exit(1)
print("   A ok: median %.1f ms into a %.1f ms stall" % (med / 1000.0, stall / 1000.0))
PY
for i in 1 2 3; do summary_ok "$WORK/a-$i.log" "A run $i"; done

echo "== B: 1000 commits racing the raster thread, zero torn frames =="
for delay in 0 3; do
  log="$WORK/b-$delay.log"
  RNI_TEST_UNIFORM_PROBE="$BOXES" RNI_TEST_RASTER_DELAY_MS="$delay" RNI_TEST_RASTER_LOG=1 \
    "$BIN" "${COMMON[@]}" --bundle "$TEAR" --app-name RasterTear --quit-on-term > "$log" 2>&1 &
  pid=$!; rni_track "$pid"
  rni_wait_line "$log" '^\[js\] FP15_COMMITS n=1000$' 120 "$pid" || { tail -15 "$log" >&2; fail "B delay $delay: JS never reached 1000 commits"; }
  # FP-19: an M-series Mac commits 1000 in ~0.45 s (28 presents); wait for 30 presents too.
  rni_wait_line "$log" '^rn-impeller: raster_present n=30 ' 60 "$pid" || { tail -15 "$log" >&2; fail "B delay $delay: never reached 30 presents"; }
  kill -TERM "$pid" 2> /dev/null || true
  rc=0; rni_wait_exit "$pid" 60 || rc=$?
  teardown_ok "$log" "B delay $delay"
  [ "$rc" = 0 ] || { tail -15 "$log" >&2; fail "B delay $delay exited $rc"; }
  summary_ok "$log" "B delay $delay"
  u="$(grep -m1 '^rn-impeller: uniform_probe ' "$log")" || fail "B delay $delay: no uniform_probe line"
  commits="$(sed -nE 's/^\[js\] FP15_COMMITS n=([0-9]+)$/\1/p' "$log" | tail -1)"
  echo "   delay $delay ms: commits>=$commits $u"
  python3 - "$u" "$commits" "$delay" <<'PY' || fail "B: see above"
import re, sys
u, commits, delay = sys.argv[1], int(sys.argv[2]), sys.argv[3]
f = dict(re.findall(r"(\w+)=(-?\d+)", u))
if int(f["points"]) != 12: print("B: probe has %s points, want 12" % f["points"]); sys.exit(1)
if int(f["torn"]) != 0:
    print("B delay %s: %s TORN presents (two commits in one frame), first at present %s" % (delay, f["torn"], f["first_torn"])); sys.exit(1)
if commits < 1000: print("B: only %d commits" % commits); sys.exit(1)
if int(f["presents"]) < 30: print("B: only %s presents" % f["presents"]); sys.exit(1)
if int(f["distinct"]) < 3: print("B: only %s distinct colours reached the screen" % f["distinct"]); sys.exit(1)
PY
done

echo "== C: quit mid-animation, 20 times =="
for i in $(seq 1 20); do
  log="$WORK/c-$i.log"; delay=$(( i % 2 == 0 ? 20 : 0 )); wait_ms=$(( 150 + (i * 97) % 491 ))
  RNI_TEST_RASTER_DELAY_MS="$delay" "$BIN" "${COMMON[@]}" --bundle "$ROT" --app-name NativeRotateProbe \
    --quit-on-term > "$log" 2>&1 &
  pid=$!; rni_track "$pid"
  rni_wait_line "$log" '^rn-impeller: first_present_ms=' 30 "$pid" || { tail -15 "$log" >&2; fail "C run $i: no first present"; }
  sleep "$(awk -v m="$wait_ms" 'BEGIN { printf "%.3f", m / 1000 }')"
  kill -TERM "$pid" 2> /dev/null || true
  rc=0; rni_wait_exit "$pid" 60 || rc=$?
  teardown_ok "$log" "C run $i"
  [ "$rc" = 0 ] || { tail -15 "$log" >&2; fail "C run $i (raster delay $delay ms, TERM at +$wait_ms ms) exited $rc"; }
  grep -q '^rn-impeller: quit_requested ' "$log" || fail "C run $i: the TERM did not end the loop"
  summary_ok "$log" "C run $i (raster delay $delay ms)"
  printf '   run %2d: delay %2d ms, TERM +%3d ms, %s\n' "$i" "$delay" "$wait_ms" \
    "$(grep -m1 '^rn-impeller: presents=' "$log" | sed 's/^rn-impeller: //')"
done

echo "RASTER_THREAD_PASS (A stall presents mid-stall x3, B 2x1000+ commits 0 torn, C 20 quits exit 0)"
