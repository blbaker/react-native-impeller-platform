#!/usr/bin/env bash
# SC-29 GATE (A22, parity item 26): <Modal> is an overlay surface.
#   A. headless transparent: the modal paints over the LATER red sibling, at
#      window (0,0) (its holder has a 50 px border), and the app shows through.
#   B. headless opaque: the white container covers the whole window.
#   C. windowed: onShow fires exactly once over 60 frames (engine + JS log).
#   D. windowed: a click on the app Pressable under a transparent modal is
#      swallowed (the modal is hit-tested first).
#   E. windowed: a click on the modal's own Pressable presses it.
#   F. windowed: Escape sends onRequestClose to the modal (the fixture then
#      closes it) and the next click on the app Pressable reaches the app.
# animationType none: arm A/B capture the modal fully painted on the first
# frames after mount (no transition). Node-free: prebuilt bundle + RNI_BIN.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BUNDLE="${RNI_TEST_BUNDLE:-$ROOT/fixtures/sc29-modal/prebuilt/sc29-modal.bundle}"
if [ -n "${RNI_BIN:-}" ]; then BIN="$RNI_BIN"
elif [ "$(uname -s)" = Darwin ]; then BIN="$ROOT/packages-engine/engine-darwin-arm64/bin/rn-impeller"
else BIN="$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller"; fi
fail() { echo "MODAL_FAIL: $*" >&2; exit 1; }
[ -x "$BIN" ] || fail "no engine binary at $BIN"
[ -s "$BUNDLE" ] || fail "no bundle at $BUNDLE"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
COMMON=(--bundle "$BUNDLE" --app-name probe --probe-banner off --width 400 --height 300 --supersample-rnsvg 0)
WIN=(); [ "$(uname -s)" = Darwin ] || WIN=(xvfb-run -a -s "-screen 0 1280x1024x24")
run() {  # log, extra args...
  local log="$1"; shift
  ( cd "$(dirname "$BIN")" && "$BIN" "${COMMON[@]}" "$@" ) > "$log" 2>&1 \
    || { tail -10 "$log" >&2; fail "render failed ($*)"; }
  grep -qE '^rn-impeller: scene_nodes=[1-9]' "$log" || fail "the fixture mounted nothing ($log)"
}
js() { sed -n 's/^\[js\] \(SHOW\|REQUEST_CLOSE\|PRESS .*\)$/\1/p' "$1" | tr '\n' ',' | sed 's/,$//'; }

for scene in transparent opaque; do
  arm=A; [ "$scene" = opaque ] && arm=B
  echo "== $arm. headless $scene modal =="
  run "$WORK/$scene.log" --initial-url "probe://$scene" --headless --screenshot "$WORK/$scene.ppm"
  res="$(python3 tools/modal_pixels.py "$WORK/$scene.ppm" "$scene")" || true
  echo "   $res"
  echo "$res" | grep -q MODAL_PIXELS_OK || fail "$arm: $res"
done

WRUN=(--initial-url probe://transparent --window --scale 1 --frames 60)
echo "== C. onShow fires once over 60 windowed frames =="
( cd "$(dirname "$BIN")" && "${WIN[@]}" "$BIN" "${COMMON[@]}" "${WRUN[@]}" ) > "$WORK/c.log" 2>&1 \
  || { tail -10 "$WORK/c.log" >&2; fail "C: windowed run failed"; }
n_eng="$(grep -c '^\[modal\] show tag=' "$WORK/c.log" || true)"
n_js="$(grep -c '^\[js\] SHOW$' "$WORK/c.log" || true)"
echo "   engine show=$n_eng js SHOW=$n_js"
[ "$n_eng" = 1 ] && [ "$n_js" = 1 ] || fail "C: onShow should fire exactly once (engine $n_eng, js $n_js)"

echo "== D. click on the app under a transparent modal is swallowed =="
( cd "$(dirname "$BIN")" && "${WIN[@]}" "$BIN" "${COMMON[@]}" "${WRUN[@]}" --click-after-frames 10:70,240 ) > "$WORK/d.log" 2>&1 \
  || { tail -10 "$WORK/d.log" >&2; fail "D: windowed run failed"; }
grep -q 'touch_down hit=' "$WORK/d.log" || fail "D: the click never reached the host"
echo "   js: $(js "$WORK/d.log")"
js "$WORK/d.log" | grep -q 'PRESS APP' && fail "D: PRESS APP fired through the modal (the modal is not hit-tested first)"
js "$WORK/d.log" | grep -q 'SHOW' || fail "D: the modal never showed"

echo "== E. click on the modal's Pressable =="
( cd "$(dirname "$BIN")" && "${WIN[@]}" "$BIN" "${COMMON[@]}" "${WRUN[@]}" --click-after-frames 10:330,240 ) > "$WORK/e.log" 2>&1 \
  || { tail -10 "$WORK/e.log" >&2; fail "E: windowed run failed"; }
echo "   js: $(js "$WORK/e.log")"
js "$WORK/e.log" | grep -q 'PRESS MODAL' || fail "E: the modal Pressable did not press"

echo "== F. Escape requests close, then the app is clickable again =="
( cd "$(dirname "$BIN")" && "${WIN[@]}" "$BIN" "${COMMON[@]}" "${WRUN[@]}" \
    --key-after-frames 8:Escape:down --click-after-frames 25:70,240 ) > "$WORK/f.log" 2>&1 \
  || { tail -10 "$WORK/f.log" >&2; fail "F: windowed run failed"; }
echo "   js: $(js "$WORK/f.log")"
grep -q '^\[modal\] request_close tag=' "$WORK/f.log" || fail "F: Escape did not reach the modal"
[ "$(js "$WORK/f.log")" = "SHOW,REQUEST_CLOSE,PRESS APP" ] \
  || fail "F: want SHOW,REQUEST_CLOSE,PRESS APP, got $(js "$WORK/f.log")"
echo "MODAL_GATE_PASS"
