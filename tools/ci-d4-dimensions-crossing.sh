#!/usr/bin/env bash
# D4: does JS actually HEAR about a resize?
#
# ⛔ WHY THIS GATE EXISTS, AND WHY THE OTHER SIXTEEN DO NOT COVER IT.
# Every existing probe asserts NATIVE-side state: scene_nodes, frame= boxes,
# painted_during, refresh_paints, tap_hit, screenshot hashes. The Mac measured
# it directly (tools/boundary-audit.py): boundary-crossing 0/16 -- all sixteen
# would PASS on a build where native geometry is perfect and JS is never told.
# The rail bug lived exactly there and had nowhere in the suite to be caught.
#
# This gate asserts the CROSSING. It reads the DEVEVENT line DeviceEventSink
# prints, which can only be reached by host code entering the JS runtime and
# finding __rctDeviceEventEmitter. Native-perfect + JS-silent fails it.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

fail() { echo "D4 FAIL: $*"; exit 1; }

# Same display requirements as ci-resize.sh / ci-window.sh: a windowed run
# needs a real X display, and there is no headless substitute -- the whole
# point is the framebuffer-size callback a window manager drives.
#
# ⛔ DO NOT PROBE FOR A DISPLAY WITH xdpyinfo. It is an OPTIONAL package, and
# on a box that has a perfectly good X server but no x11-utils this gate
# reported "no usable X display" and exited SKIP -- a false skip, which is
# worse than a failure because it is silent and looks deliberate. Measured on
# this WSL box 2026-09-09: DISPLAY was live via WSLg's /tmp/.X11-unix/X0 the
# whole time. Test for the SOCKET the server actually creates.
export DISPLAY="${DISPLAY:-:0}"
_dpy_num="${DISPLAY#*:}"; _dpy_num="${_dpy_num%%.*}"
if [ ! -e "/tmp/.X11-unix/X${_dpy_num}" ]; then
  echo "D4 SKIP: no X socket at /tmp/.X11-unix/X${_dpy_num} (DISPLAY=$DISPLAY)"
  echo "         run under: xvfb-run -a --server-args='-screen 0 1280x1024x24' $0"
  exit 2
fi

BIN="${RNI_BIN:-$ROOT/engine/build/rn-impeller}"
[ -x "$BIN" ] || { echo "D4 SKIP: no binary at $BIN"; exit 2; }

BUNDLE="${RNI_BUNDLE:-}"
if [ -z "$BUNDLE" ]; then
  for c in "$ROOT"/fixtures/p9-usesym/prebuilt/*.bundle; do
    [ -f "$c" ] && BUNDLE="$c" && break
  done
fi
[ -n "$BUNDLE" ] && [ -f "$BUNDLE" ] || {
  echo "D4 SKIP: no prebuilt bundle; pass RNI_BUNDLE=<path>"; exit 2; }

LOG=$(mktemp)
timeout 120 "$BIN" --window --probe-banner off \
  --bundle "$BUNDLE" --app-name P9UseSym \
  --width 400 --height 300 --frames 60 \
  --resize-after-frames "10:700x500" \
  > "$LOG" 2>&1 || true

echo "--- resize + DEVEVENT lines ---"
grep -E "rn-impeller: resize |DEVEVENT" "$LOG" | head -12

RESIZED=$(grep -c "rn-impeller: resize px=" "$LOG" || true)
DELIVERED=$(grep -c "DEVEVENT: didUpdateDimensions delivered" "$LOG" || true)
DROPPED=$(grep -c "DEVEVENT: didUpdateDimensions DROPPED" "$LOG" || true)

echo
echo "resize_events=$RESIZED  devevent_delivered=$DELIVERED  devevent_dropped=$DROPPED"

# ⛔ AN UNGRADED RUN IS NOT A PASS. If the resize body never ran, this gate
# learned nothing -- reporting green there is how a probe that tests nothing
# gets to look healthy for weeks.
[ "$RESIZED" -ge 1 ] || fail "the resize body never ran -- gate is UNGRADED, not green"

if [ "$DELIVERED" -lt 1 ]; then
  if [ "$DROPPED" -ge 1 ]; then
    fail "the emit was attempted and DROPPED ($DROPPED) -- JS never heard. See the DEVEVENT reason above."
  fi
  fail "native resized but NOTHING crossed to JS. This is the exact defect 16/16 native-side probes cannot see."
fi

echo "D4 PASS: resize crossed the JS boundary ($DELIVERED delivered emit(s), $RESIZED resize(s))"
