#!/usr/bin/env bash
# SC-28 GATE: <ActivityIndicator> paints the iOS spinner and keeps repainting.
#   A. headless grid 1: the activityIndicator tile passes its strict rule
#      (red spokes around the slot centre, >= 4 alpha levels, hub empty).
#   B. windowed: the tile at ~1.25 s differs from frame 0 and is still a spinner
#      (1 s is exactly one turn, so the second capture is taken at 1.25 s).
#   C. windowed --idle-skip: while the spinner animates, frames keep painting
#      (without the clock the loop would sleep after the first paint).
# Node-free: prebuilt bundle + RNI_BIN (the Mac can run it). Needs xvfb-run on linux.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BUNDLE="${RNI_TEST_BUNDLE:-$ROOT/fixtures/style-audit/prebuilt/style-audit.bundle}"
if [ -n "${RNI_BIN:-}" ]; then BIN="$RNI_BIN"
elif [ "$(uname -s)" = Darwin ]; then BIN="$ROOT/packages-engine/engine-darwin-arm64/bin/rn-impeller"
else BIN="$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller"; fi
fail() { echo "ACTIVITY_INDICATOR_FAIL: $*" >&2; exit 1; }
[ -x "$BIN" ] || fail "no engine binary at $BIN"
[ -s "$BUNDLE" ] || fail "no bundle at $BUNDLE"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
COMMON=(--bundle "$BUNDLE" --app-name probe --probe-banner off --width 1200 --height 2100
        --initial-url probe://grid --supersample-rnsvg 0)
WIN=(); [ "$(uname -s)" = Darwin ] || WIN=(xvfb-run -a -s "-screen 0 1280x2200x24")

echo "== A. headless: spinner tile passes the strict rule =="
( cd "$(dirname "$BIN")" && "$BIN" "${COMMON[@]}" --headless --screenshot "$WORK/grid.ppm" ) > "$WORK/a.log" 2>&1 \
  || { tail -10 "$WORK/a.log" >&2; fail "headless render failed"; }
python3 tools/style-audit-measure.py "$WORK/grid.ppm" fixtures/style-audit/index.js > "$WORK/tiles.txt"
line="$(grep -E '^TILE [0-9]+ activityIndicator ' "$WORK/tiles.txt" | cut -c1-150)"
echo "   $line"
echo "$line" | grep -q ' PASS ' || fail "A: activityIndicator tile does not paint a spinner"

echo "== B. windowed: frame at 1.25 s differs from frame 0 =="
( cd "$(dirname "$BIN")" && "${WIN[@]}" "$BIN" "${COMMON[@]}" --window --scale 1 --frames 240 \
    --screenshot-first "$WORK/w0.ppm" --screenshot "$WORK/w1.ppm" --screenshot-after 1250 ) > "$WORK/b.log" 2>&1 \
  || { tail -10 "$WORK/b.log" >&2; fail "windowed render failed"; }
[ -s "$WORK/w0.ppm" ] && [ -s "$WORK/w1.ppm" ] || fail "B: windowed captures missing"
res="$(python3 tools/activity_indicator_frames.py "$WORK/w0.ppm" "$WORK/w1.ppm")" || true
echo "   $res"
echo "$res" | grep -q ACTIVITY_FRAMES_OK || fail "B: $res"

echo "== C. idle-skip: an animating spinner keeps frames painting =="
( cd "$(dirname "$BIN")" && "${WIN[@]}" "$BIN" "${COMMON[@]}" --window --scale 1 \
    --idle-skip --idle-log --idle-run-sec 6 ) > "$WORK/c.log" 2>&1 \
  || { tail -10 "$WORK/c.log" >&2; fail "idle run failed"; }
total="$(grep -c '\[idle\] frame=' "$WORK/c.log" || true)"
# Frames after the 3 s mark of a 6 s run: take the last third of the log.
painted="$(grep '\[idle\] frame=' "$WORK/c.log" | tail -n $((total / 3)) | grep -c 'painted=1' || true)"
echo "   frames=$total painted_in_last_third=$painted"
[ "$total" -gt 30 ] || fail "C: too few frames logged ($total)"
[ "$painted" -ge 10 ] || fail "C: only $painted frames painted late in the run, the loop slept through the spinner"
echo "ACTIVITY_INDICATOR_GATE_PASS"
