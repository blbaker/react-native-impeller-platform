#!/usr/bin/env bash
# FP-01 gate: the per-frame timing recorder (engine/host/FrameTimings.*, model
# flutter/flow/frame_timings.h). Node-free: committed native-transform bundle,
# staged binary (or RNI_BIN), never rebuilds.
#
#   A  windowed 120-frame NativeRotateProbe: n == presents >= 120
#   B  windowed --idle-skip NativeRotateIdle: idle frames discarded (>= 1),
#      painted frames still complete (mutant M1 lives here)
#   C  headless --frames 10: n == presents == 11 (10 loop frames + final paint)
# Every arm: zero frame_timing_errors, every JSON record complete and monotonic,
# printed percentiles equal the ones recomputed from the JSON.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BUNDLE="$ROOT/fixtures/native-transform/prebuilt/native-transform.bundle"
fail() { echo "FRAME_TIMINGS_FAIL: $*" >&2; exit 1; }
[ -s "$BUNDLE" ] || fail "no committed bundle at $BUNDLE"

if [ -n "${RNI_BIN:-}" ]; then BIN="$RNI_BIN"
elif [ "$(uname -s)" = Darwin ]; then BIN="$ROOT/packages-engine/engine-darwin-arm64/bin/rn-impeller"
else BIN="$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller"; fi
[ -x "$BIN" ] || fail "no engine binary at $BIN (build with tools/engine-build.sh or set RNI_BIN)"
echo "engine: $BIN ($( (shasum -a 256 "$BIN" 2>/dev/null || sha256sum "$BIN") | cut -c1-12))"

WORK="$(mktemp -d)"
cleanup() { [ "${KEEP_WORKDIR:-0}" = 1 ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

WIN=(); [ "$(uname -s)" = Linux ] && WIN=(xvfb-run -a -f "$WORK/xvfb.auth" -s "-screen 0 1280x1024x24")
run() {  # arm args...
  local arm="$1" rc=0; shift
  ( cd "$(dirname "$BIN")" && timeout 300 "$@" --bundle "$BUNDLE" --width 400 --height 300 \
      --supersample-rnsvg 0 --frame-timings-out "$WORK/$arm.json" ) > "$WORK/$arm.log" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || { tail -15 "$WORK/$arm.log" >&2; fail "arm $arm exited $rc"; }
  grep -qE '^rn-impeller: scene_nodes=[1-9]' "$WORK/$arm.log" || fail "arm $arm mounted nothing"
}
check() {  # arm min_n exact_n min_discarded
  local out
  out="$(python3 tools/frame_timings_check.py "$1" "$WORK/$1.log" "$WORK/$1.json" "$2" "$3" "$4")" \
    || fail "$out"
  echo "   $out"
}

echo "== A: windowed 120 animated frames =="
run windowed "${WIN[@]}" "$BIN" --window --scale 1 --app-name NativeRotateProbe --frames 120
grep -q 'RN_IMPELLER_WINDOW_OK app=NativeRotateProbe frames=120' "$WORK/windowed.log" \
  || fail "windowed arm did not run 120 frames"
check windowed 120 - 0

echo "== B: windowed idle-skip (static tree) =="
run idle "${WIN[@]}" "$BIN" --window --scale 1 --app-name NativeRotateIdle --idle-skip --idle-run-sec 2
check idle 1 - 1

echo "== C: headless 10 frames =="
run headless "$BIN" --headless --probe-banner off --app-name NativeRotateProbe --frames 10
check headless 11 11 0

echo "FRAME_TIMINGS_PASS windowed+idle+headless"
