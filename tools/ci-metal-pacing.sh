#!/usr/bin/env bash
# FP-27 GATE: darwin Metal presents are paced on CVDisplayLink and logged at displayed time.
#
# Model: flutter/shell/platform/darwin/macos/framework/Source/FlutterVSyncWaiter.mm +
# FlutterDisplayLink.mm (frame start = the link's targetTimestamp - period). fixtures/fp11-vsync
# VsyncSpin, windowed, --backend metal --vsync-log: one vsync_displayed line per present from the
# drawable's presented handler (presentedTime), one display_link_tick line per link callback.
# A spin-0 warm-up, then 3 runs; tools/metal_pacing_check.py:
#   S  source: display_link ok=1, `vsync requested=displaylink`, >= 120 link ticks, <= 5 software fallbacks
#   P  pacing: median over the runs of the median presented interval within 5% of the display period
#   K  short presented intervals (< half a period), pooled, at most 3 + 2x the same process's
#      CVDisplayLink callback intervals under half a period over the same span (ci-vsync's B limit)
#   T  displayed time: no frame "displayed" > 1 ms before its target vblank or at/before its encode
#   L  latency: median displayed - target vblank <= 3 periods (paced on the link = 1-2 measured;
#      paced only by drawable back-pressure = 5)
# linux: `--vsync displaylink` is refused (exit 2, darwin-only); the Metal arms run on darwin.
# Node-free: committed bundle + RNI_BIN. Run it on a Mac with RNI_BIN set.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BUNDLE="$ROOT/fixtures/fp11-vsync/prebuilt/fp11-vsync.bundle"
fail() { echo "METAL_PACING FAIL: $*" >&2; exit 1; }
[ -s "$BUNDLE" ] || fail "no committed bundle at $BUNDLE"
. tools/lib/host-window.sh
WORK="$(mktemp -d)"
cleanup() { [ "${KEEP_WORKDIR:-0}" = 1 ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

if [ "$(rni_host)" = linux ]; then
  BIN="${RNI_BIN:-$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller}"
  [ -x "$BIN" ] || fail "no engine binary at $BIN (set RNI_BIN)"
  rc=0
  ( cd "$(dirname "$BIN")" && rni_xrun "$WORK/xauth" timeout 120 "$BIN" --window --scale 1 \
      --width 400 --height 300 --bundle "$BUNDLE" --app-name VsyncSpin --probe-banner off \
      --supersample-rnsvg 0 --frames 3 --vsync displaylink ) > "$WORK/refuse.log" 2>&1 || rc=$?
  [ "$rc" = 2 ] && grep -q 'vsync displaylink is darwin-only' "$WORK/refuse.log" \
    || fail "linux --vsync displaylink not refused (rc=$rc: $(tail -1 "$WORK/refuse.log"))"
  echo "METAL_PACING PASS linux (--vsync displaylink refused off darwin; the pacing arms run on darwin)"
  exit 0
fi
[ "$(rni_host)" = darwin ] || fail "linux or darwin only"
BIN="${RNI_BIN:?darwin: set RNI_BIN (the staged darwin binary)}"
[ -x "$BIN" ] || fail "no engine binary at $BIN"
echo "engine: $BIN ($(shasum -a 256 "$BIN" | cut -c1-12))"

run() {  # tag run_sec
  local rc=0
  ( cd "$(dirname "$BIN")" && timeout 120 "$BIN" --window --scale 1 --width 400 --height 300 \
      --bundle "$BUNDLE" --app-name VsyncSpin --probe-banner off --supersample-rnsvg 0 \
      --backend metal --idle-skip --idle-run-sec "$2" --vsync-log ) > "$WORK/$1.log" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || { tail -15 "$WORK/$1.log" >&2; fail "$1 exited $rc"; }
  grep -qE '^rn-impeller: scene_nodes=[1-9]' "$WORK/$1.log" || fail "$1: nothing mounted"
  grep -q '^rn-impeller: metal_context ok=1' "$WORK/$1.log" || fail "$1: not on the Metal backend"
  grep -h '^rn-impeller: display_link ' "$WORK/$1.log" | head -2
}

echo "== render =="
run spin-0 1.5  # cold-start warm-up (FP-26)
for i in 1 2 3; do run "spin-$i" 3.5; done
echo "== check =="
python3 tools/metal_pacing_check.py "$WORK" || exit 1
echo "METAL_PACING PASS"
