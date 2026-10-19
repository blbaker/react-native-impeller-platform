#!/usr/bin/env bash
# iOS Phase 1 / Task 1.1 gate: MetalSurfaceIOS presents Impeller frames on the
# iOS Simulator. Run from linux or the Mac; on linux it re-execs on the Mac
# (tools/lib/ios-sim.sh). The test host (--test=metal) attaches the surface to a
# CAMetalLayer-backed UIView and, from a serial raster queue, draws a dark
# rounded rect on white every vsync; frame 30 is read back before its present.
# Arms (each failure prints `IOS_METAL_GATE FAIL <arm>: ...`; all arms run):
#   L  layer read-back: bgra8, framebuffer_only=0, contents_scale = the
#      screen's native scale, drawable = the screenshot's pixel size
#   R  ReadPixels: the frame-30 readback is a rounded rect: >= 5 distinct
#      colors (ink + white + 4x MSAA's 3 coverage levels; the plan's ">= 10" is
#      ci-metal.sh's multi-colour fixture number, see tools/ios_image_check.py),
#      partial-coverage AA pixels in every corner box (corner_aa=1), background
#      at the corner pixel
#   S  on screen: a simctl screenshot passes the same check (Present reached
#      the display, not just the drawable)
#   P  presents: >= 200 presents by frame 240 (one per frame, no drops to 0)
# Pass line: IOS_METAL_PASS (colors=<n> corner_aa=1). Mutants:
# tools/mutation-verify-metal-ios-sim.sh.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ios-sim.sh"
ios_on_mac_or_reexec "$0" "$@"
ios_begin metal
FAILS=()
bad() { echo "IOS_METAL_GATE FAIL $1: $2"; FAILS+=("$1"); }
CHECK() { python3 tools/ios_image_check.py "$@"; }

ios_build_testhost || { echo "IOS_METAL_FAIL (build)"; exit 1; }
ios_sim_up || { echo "IOS_METAL_FAIL (simulator)"; exit 1; }
LOG="$IOS_WORK/app.log"
ios_launch "$LOG" metal || { echo "IOS_METAL_FAIL (launch)"; exit 1; }
ios_wait_log "$LOG" 'testhost: readback ' 60 || bad R "no readback line in 60 s: $(tail -2 "$LOG")"
ios_wait_log "$LOG" 'testhost: metal frames=240 ' 30 || bad P "frame 240 never drawn: $(tail -1 "$LOG")"
ios_screenshot "$IOS_WORK/screen.png" || bad S "simctl screenshot failed"
cat "$LOG"

echo "== L: layer =="
LAYER=$(grep -m1 'metal_layer ' "$LOG")
[[ "$LAYER" == *"pixel_format=bgra8 framebuffer_only=0 "* ]] || bad L "layer: $LAYER"
DRAWABLE=$(sed -nE 's/.* drawable=([0-9]+x[0-9]+) .*/\1/p' <<< "$LAYER")
SHOT_SIZE=$(sips -g pixelWidth -g pixelHeight "$IOS_WORK/screen.png" 2> /dev/null \
  | awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{print w "x" h}')
[ -n "$DRAWABLE" ] && [ "$DRAWABLE" = "$SHOT_SIZE" ] \
  || bad L "drawable $DRAWABLE != screenshot $SHOT_SIZE (contents_scale wrong?)"
echo "layer: $LAYER | screenshot $SHOT_SIZE"

echo "== R: ReadPixels before present =="
RB=$(grep -m1 'testhost: readback ' "$LOG")
GEOM=$(sed -nE 's/.* rrect=([0-9]+),([0-9]+),([0-9]+),([0-9]+) r=([0-9]+).*/\1 \2 \3 \4 \5/p' <<< "$RB")
PPM="$(ios_container)/Documents/metal-readback.ppm"
R_OUT=""
if [[ "$RB" != *" ok=1 "* ]] || [ ! -s "$PPM" ] || [ -z "$GEOM" ]; then
  bad R "readback missing: $RB"
else
  cp "$PPM" "$IOS_WORK/readback.ppm"
  # shellcheck disable=SC2086
  R_OUT=$(CHECK rrect "$IOS_WORK/readback.ppm" $GEOM) || bad R "$R_OUT"
  echo "readback: $R_OUT"
fi

echo "== S: on screen =="
if [ -n "$GEOM" ] && [ -s "$IOS_WORK/screen.png" ]; then
  # shellcheck disable=SC2086
  S_OUT=$(CHECK rrect "$IOS_WORK/screen.png" $GEOM) || bad S "$S_OUT"
  echo "screen: $S_OUT"
fi

echo "== P: presents =="
PRESENTS=$(ios_kv "$LOG" 'metal frames=240 ' presents)
[ "${PRESENTS:-0}" -ge 200 ] || bad P "presents=${PRESENTS:-none} at frame 240"
echo "presents at frame 240: ${PRESENTS:-none}"

ios_keep "$LOG" "$IOS_WORK/screen.png" "$IOS_WORK/readback.ppm"
[ "${#FAILS[@]}" = 0 ] || { echo "IOS_METAL_FAIL (${FAILS[*]})"; exit 1; }
COLORS=$(sed -nE 's/.*colors=([0-9]+).*/\1/p' <<< "$R_OUT")
echo "IOS_METAL_PASS (colors=$COLORS corner_aa=1)"
