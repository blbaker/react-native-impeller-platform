#!/usr/bin/env bash
# FIRST-PRESENT GATE: a launch animation must be ON SCREEN, not finished
# before the window shows anything (Mac report 2026-10-03, HostApp v5 D-156).
#
# Runs the committed fixtures/first-present bundle windowed and asserts:
#   1. The windowed boot wait drained (boot_wait_ms ... drained=1/1).
#   2. The FIRST PRESENTED FRAME shows the BOOT screen (red with the green
#      mark), not HOME (blue) and not a blank/black window. Read from the
#      pixels captured before that present, not from a log line. Checked
#      before the timing so a regression names what the user would SEE.
#   3. The host's firstFramePresented event reached the JS listener exactly
#      once (FP_FIRST_FRAME, one DEVEVENT emit).
#   4. The first frame reached the window inside the boot clock, measured on
#      the JS clock (FP_FIRST_FRAME js_ms < BOOT_MS). The old boot waited for
#      every pending one-shot timer, so the first present landed AFTER it.
#
# Node-free on purpose: the Mac has no JS toolchain, so the bundle is
# committed and pixels are read with od. Engine binary: RNI_BIN wins (the
# Mac points it at its engine dir, e.g. ~/.local/state/rni-tool/cache/engines/rni-<sha>/
# rn-impeller); otherwise linux builds and uses its staged package, and
# darwin uses packages-engine/engine-darwin-arm64 as staged (engine-build.sh
# needs node, which the Mac lacks). On darwin the run goes through
# tools/darwin-run-interactive.sh: a QoS-clamped launch coalesces timers and
# would inflate first_present_ms (see that script's header).
#
# ⚠️ DISPLAY=:0 on linux; SDL_VIDEODRIVER unset (see ci-window.sh).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
cd "$(dirname "$0")/.."
ROOT="$PWD"
BUNDLE="$ROOT/fixtures/first-present/prebuilt/first-present.bundle"
BOOT_MS=1500   # must match BOOT_MS in fixtures/first-present/index.js
W=400; H=300

fail() { echo "FIRST_PRESENT_GATE_FAIL: $*" >&2; exit 1; }

unset SDL_VIDEODRIVER || true
OS="$(uname -s)"
[ "$OS" = Linux ] && export DISPLAY="${DISPLAY:-:0}"
[ -s "$BUNDLE" ] || fail "no committed bundle at $BUNDLE (tools/build-first-present-bundle.sh)"

if [ -n "${RNI_BIN:-}" ]; then
  BIN="$RNI_BIN"
elif [ "$OS" = Darwin ]; then
  BIN="$ROOT/packages-engine/engine-darwin-arm64/bin/rn-impeller"
elif [ "$OS" = Linux ]; then
  case "$(uname -m)" in x86_64) ARCH=x64 ;; aarch64) ARCH=arm64 ;; *) fail "unsupported arch $(uname -m)" ;; esac
  bash tools/engine-build.sh linux "$ARCH" > "${TMPDIR:-/tmp}/ci-first-present-build.log" 2>&1 \
    || { tail -20 "${TMPDIR:-/tmp}/ci-first-present-build.log" >&2; fail "engine build failed"; }
  BIN="$ROOT/packages-engine/engine-linux-$ARCH/bin/rn-impeller"
else
  fail "unsupported OS $OS"
fi
[ -x "$BIN" ] || fail "no engine binary at $BIN (set RNI_BIN)"

WORK="$(mktemp -d)"
cleanup() { rni_kill_own; [ "${KEEP_WORKDIR:-0}" = 1 ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

echo "== 1. windowed run, capture the FIRST presented frame =="
LOG="$WORK/run.log"; SHOT="$WORK/first.ppm"
ARGS=(--window --bundle "$BUNDLE" --app-name FirstPresent
      --width "$W" --height "$H" --frames 150 --screenshot-first "$SHOT")
set +e
if [ "$OS" = Darwin ]; then
  # cwd = the engine dir: the binary links ./libimpeller.dylib.
  ( cd "$(dirname "$BIN")" && zsh "$ROOT/tools/darwin-run-interactive.sh" "$LOG" 60 -- "$BIN" "${ARGS[@]}" ) > /dev/null 2>&1
else
  "$BIN" "${ARGS[@]}" > "$LOG" 2>&1
fi
RC=$?
set -e
grep -E 'interactive_pri|boot_wait_ms|first_present_ms|scene_nodes|screenshot_first|FP_|WINDOW_OK' "$LOG" | sed 's/^/   /'
[ "$RC" -eq 0 ] || { tail -20 "$LOG" >&2; fail "windowed run exited $RC"; }
if [ "$OS" = Darwin ]; then
  grep -q '^interactive_pri=31$' "$LOG" \
    || fail "darwin run was QoS-clamped ($(grep -m1 interactive_pri "$LOG")): first_present_ms would measure the clamp"
fi

echo "== 2. boot wait drained =="
grep -qE '^rn-impeller: boot_wait_ms=[0-9]+ drained=1/1$' "$LOG" \
  || fail "no 'boot_wait_ms=N drained=1/1' line: the windowed boot wait timed out or is gone"
echo "   OK"

echo "== 3. the first presented frame is the BOOT screen =="
[ -s "$SHOT" ] || fail "no --screenshot-first file"
# The capture is in FRAMEBUFFER pixels: 400x300 on WSLg, 800x600 on a 2x
# Retina Mac. Sample points are in layout points and scaled to match.
# Header is exactly three text lines (Pixel.cpp: "P6\n%d %d\n255\n").
[ "$(head -c 2 "$SHOT")" = P6 ] || fail "first frame is not a P6 PPM"
HDRLEN="$(head -n 3 "$SHOT" | wc -c | tr -d ' ')"
read -r PW PH <<< "$(head -n 2 "$SHOT" | tail -n 1)"
S=$(( PW / W ))
{ [ "$S" -ge 1 ] && [ $(( PW )) -eq $(( W * S )) ] && [ $(( PH )) -eq $(( H * S )) ]; } \
  || fail "first frame is ${PW}x${PH}, not an integer multiple of ${W}x${H}"
# RGB hex at layout point (x,y).
px() { od -An -tx1 -j $(( HDRLEN + ($2 * S * PW + $1 * S) * 3 )) -N3 "$SHOT" | tr -d ' \n'; }
BG="$(px 380 280)"     # far corner: background only
# The mark slides right 200 points over the boot clock (left 20+x, 60 wide),
# so a fixed sample point would only hold for the first ~225 ms. Scan the
# whole travel band on row y=70 instead and report where the mark starts:
# that offset is how far into the animation the first frame landed.
# od -v: never collapse repeated lines into '*' (the row is mostly one colour).
ROWHEX="$(od -An -v -tx1 -j $(( HDRLEN + (70 * S * PW + 20 * S) * 3 )) -N $(( 260 * S * 3 )) "$SHOT" | tr -d ' \n' | fold -w 6)"
MARK_COL="$(printf '%s\n' "$ROWHEX" | grep -n -m1 '^00ff00$' | cut -d: -f1 || true)"
if [ -n "$MARK_COL" ]; then MARK=00ff00; MARK_X=$(( (MARK_COL - 1) / S )); else MARK=none; MARK_X=-; fi
echo "   ${PW}x${PH} (scale $S) background(380,280)=$BG mark=$MARK at +${MARK_X} pt of 200"
case "$BG" in
  ff0000) : ;;
  0000ff) fail "first frame is HOME (blue): the boot clock finished before anything was presented" ;;
  000000) fail "first frame is BLACK: the window presented before the app's first commit" ;;
  *) fail "first frame background is $BG, expected ff0000 (BOOT)" ;;
esac
[ "$MARK" = 00ff00 ] || fail "BOOT background but no green mark on row 70: the first frame is not the app's first committed tree"
echo "   OK: BOOT screen with the mark"

echo "== 4. firstFramePresented reached JS exactly once =="
N_EMIT="$(grep -c 'DEVEVENT: firstFramePresented' "$LOG" || true)"
N_JS="$(grep -c 'FP_FIRST_FRAME' "$LOG" || true)"
[ "$N_EMIT" -eq 1 ] || fail "firstFramePresented emitted $N_EMIT times (expected 1)"
[ "$N_JS" -eq 1 ] || fail "JS listener saw firstFramePresented $N_JS times (expected 1)"
echo "   OK"

echo "== 5. first present lands inside the boot clock (JS clock) =="
# ⛔ MEASURED ON THE JS CLOCK, NOT FROM PROCESS START. The boot clock starts
# at JS start, so "inside the animation" means first present - JS start <
# BOOT_MS. first_present_ms counts from process start and also includes
# window/GL/Hermes init BEFORE JS; on darwin that pre-JS part was ~3.4 s on
# 2 of 4 launches (2026-10-03) while the frame itself was still BOOT at +7 pt.
# Gating on it failed a correct engine for a cost this fix does not touch.
# js_ms = when the listener ran, so it is an upper bound on the present.
FP_MS="$(sed -n 's/^rn-impeller: first_present_ms=\([0-9]*\)$/\1/p' "$LOG")"
[ -n "$FP_MS" ] || fail "no first_present_ms line: nothing was presented"
JS_MS="$(sed -n 's/.*FP_FIRST_FRAME js_ms=\([0-9]*\).*/\1/p' "$LOG" | head -1)"
[ -n "$JS_MS" ] || fail "no FP_FIRST_FRAME js_ms= line"
[ "$JS_MS" -lt "$BOOT_MS" ] \
  || fail "first present reached JS ${JS_MS} ms after JS start, not inside the ${BOOT_MS} ms boot clock: a launch animation would be invisible"
echo "   OK: first frame heard ${JS_MS} ms after JS start (< $BOOT_MS); process start -> present ${FP_MS} ms"

echo "== 6. no orphan window process =="
sleep 1
if rni_have_own; then rni_kill_own; fail "rn-impeller still running after the bounded run"; fi
echo "   OK"

echo "FIRST_PRESENT_GATE_PASS (js_ms=$JS_MS first_present_ms=$FP_MS bg=$BG mark_x=$MARK_X)"
