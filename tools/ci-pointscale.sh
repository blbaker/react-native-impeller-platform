#!/usr/bin/env bash
# GATE: the windowed path derives its backing scale from the WINDOW, not from
# a CLI default.
#
# ⛔ WHY THIS GATE IS NOT A SCREENSHOT TEST.
# The defect it guards is invisible on every host this repo's CI can run on.
# On a 1x display glfwCreateWindow's screen coordinates and
# glfwGetFramebufferSize's pixels are EQUAL, so a build that ignores the
# framebuffer entirely renders byte-identically to a correct one. The bug only
# paints wrong on a 2x (Retina) display: a 1280x860-point window gets a
# 2560x1720-pixel framebuffer, and using the CLI numbers lays out 1280x860
# POINTS rasterised at 1x — content in the top-left quarter, glyphs rasterised
# for the wrong display. Baker's Mac measured exactly that: 2558x1747 window
# interior, 1288x888 painted, ratio 1.99 x 1.97, remainder pure (0,0,0).
#
# So this gate asserts the DECISION rather than the pixels: it feeds
# DeriveWindowPointScale the real number pairs a 2x Mac produces (via the
# engine's own --test-pointscale, i.e. the shipped binary, not a retyped copy
# of the logic) and checks the answers. Then it asserts the windowed path
# actually CONSUMES that decision, by checking the surface line the engine
# prints, and re-runs the existing window gate so the 1x behaviour is proven
# unchanged rather than assumed.
set -euo pipefail
CI_TOOLS="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$0")/.."
ROOT="$PWD"
. "$CI_TOOLS/ci-triple.sh"

fail() { echo "POINTSCALE_GATE_FAIL: $*" >&2; exit 1; }

bash tools/engine-build.sh "$RNI_PLATFORM" "$RNI_ARCH" > /dev/null || fail "engine build failed"
ENGINE="$ROOT/${RNI_ENGINE_PKG}/bin/rn-impeller"
[ -x "$ENGINE" ] || ENGINE="$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller"
[ -x "$ENGINE" ] || fail "no engine staged"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== 1. the scale decision itself, over the pairs a 2x display produces =="
"$ENGINE" --test-pointscale > "$WORK/selftest.log" 2>&1 \
  || { sed 's/^/   /' "$WORK/selftest.log"; fail "--test-pointscale reported a mismatch"; }
sed 's/^/   /' "$WORK/selftest.log"
grep -q '^POINTSCALE_SELFTEST_OK' "$WORK/selftest.log" \
  || fail "--test-pointscale did not print POINTSCALE_SELFTEST_OK"

# ⛔ ASSERT THE RETINA CASE BY NAME.
# A mutant that returns a constant 1.0 still prints POINTSCALE_SELFTEST_* and
# still exits non-zero only because of the assertion INSIDE the binary. If
# someone ever weakens that table, this line is the independent check that the
# one case the whole gate exists for is present and correct.
grep -qE 'retina 2x window .*fb=2560 .*win=1280 .*-> 2\.0000 \(want 2\.0000\) ok' "$WORK/selftest.log" \
  || fail "the 2560px/1280pt Retina case did not resolve to 2.0 — this is the exact defect"
grep -qE '1x window .*fb=1280 .*win=1280 .*-> 1\.0000 .*ok' "$WORK/selftest.log" \
  || fail "a 1x window no longer resolves to 1.0 — every existing 1x gate's golden is at risk"
echo "   OK: 2x window -> 2.0, 1x window -> 1.0, --scale still overrides"

echo "== 2. the windowed path CONSUMES the decision (not just computes it) =="
# Computing the right number and then not using it is the same bug with extra
# steps, so check the engine reports a window whose points/pixels/scale are
# mutually consistent. On this 1x host the scale is 1.0 and the assertion that
# bites is px == the size actually granted, proving the CLI numbers are no
# longer what reaches displayMetrics.
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
FIXTURE="$ROOT/fixtures/p3-conformance"
if [ -d "$BASE_APP/node_modules/react-native" ] && [ -n "${DISPLAY:-}" ]; then
  APP="$WORK/app"; cp -R "$BASE_APP" "$APP"
  cp "$FIXTURE/index.js" "$APP/index.js"
  cp "$FIXTURE/fixture.json" "$APP/fixture.json" 2>/dev/null || true
  bash tools/local-registry.sh use "$APP" >/dev/null 2>&1 || true
  (cd "$APP" && npm install @react-native-impeller/core --no-audit --no-fund --silent >/dev/null 2>&1) || true
  (cd "$APP" && npx --no-install react-native init-impeller >/dev/null 2>&1) || true
  if (cd "$APP" && npx --no-install react-native bundle --entry-file index.js \
        --platform impeller --dev false --bundle-output "$WORK/b.js" >/dev/null 2>&1); then
    "$ENGINE" --window --bundle "$WORK/b.js" --app-name P3Fixture \
              --width 400 --height 300 --frames 3 > "$WORK/win.log" 2>&1 || true
    LINE="$(grep '^rn-impeller: window px=' "$WORK/win.log" | head -1)"
    [ -n "$LINE" ] && echo "   $LINE"
    [ -n "$LINE" ] || fail "the windowed run never printed its resolved window geometry — RunWindowed is not reading the surface"
    echo "$LINE" | grep -q 'from framebuffer' \
      || fail "scale was not derived from the framebuffer on a run with no --scale"

    # ⛔ THE ASSERTION THAT ACTUALLY KILLS "COMPUTE IT, THEN IGNORE IT".
    # A build that derives the scale correctly and then feeds the CLI numbers
    # to displayMetrics/startSurface anyway is the same defect with extra
    # steps, and on a 1x host it is INVISIBLE to every check above: when the
    # window manager grants exactly what was requested, CLI == framebuffer and
    # both builds print the same line.
    #
    # Force them apart without a Retina display by requesting a window size
    # the WM cannot grant. The request is then NOT what the surface got, so:
    #   correct build -> reads the surface: fb == win, scale unchanged
    #   ignoring build -> fb = the impossible request, win = what was granted,
    #                     so the scale comes out as a garbage ratio
    # Comparing the scale from a granted request against the scale from a
    # clamped one is host-independent: on a 1x host both are 1.00, on a 2x
    # host both are 2.00, and only a build that ignores the surface can make
    # them differ.
    scale_of() {
      # No `| head -1` inside the pipeline: this script runs under
      # `set -o pipefail`, and head closing the pipe early SIGPIPEs sed, which
      # fails the whole function for a reason that has nothing to do with the
      # engine. Capture, then take the first line.
      local out
      out="$("$ENGINE" --window --bundle "$WORK/b.js" --app-name P3Fixture \
                       --width "$1" --height "$1" --frames 2 2>&1 || true)"
      printf '%s\n' "$out" \
        | sed -n 's/^rn-impeller: window px=.* scale=\([0-9.]*\).*/\1/p' \
        | sed -n '1p'
    }
    SGRANTED="$(scale_of 400)"
    SCLAMPED="$(scale_of 99999)"
    echo "   scale from a granted request=${SGRANTED:-?}  from an unhonoured one=${SCLAMPED:-?}"
    [ -n "$SGRANTED" ] && [ -n "$SCLAMPED" ] \
      || fail "could not read the resolved scale from both runs"
    [ "$SGRANTED" = "$SCLAMPED" ] \
      || fail "backing scale changed with the REQUESTED window size ($SGRANTED vs $SCLAMPED) — the host is using the CLI numbers as the pixel size instead of the surface's real framebuffer"
  else
    echo "   SKIP: could not bundle a fixture here (assertion 1 still ran)"
  fi
else
  echo "   SKIP: no base app or no DISPLAY (assertion 1 still ran)"
fi

echo "== 3. the 1x windowed behaviour is unchanged =="
if [ -n "${DISPLAY:-}" ] && [ -d "$BASE_APP/node_modules/react-native" ]; then
  bash "$CI_TOOLS/ci-window.sh" > "$WORK/window.log" 2>&1 \
    || { tail -20 "$WORK/window.log" >&2; fail "tools/ci-window.sh regressed"; }
  grep -q 'WINDOW_GATE_PASS' "$WORK/window.log" || fail "ci-window.sh did not pass"
  echo "   OK: WINDOW_GATE_PASS"
else
  echo "   SKIP: no DISPLAY for the windowed gate"
fi

echo "POINTSCALE_GATE_PASS"
