#!/usr/bin/env bash
# P10-A gate — can this engine carry the game view's canvas draw path?
#
# The macOS tester instrumented CanvasRenderingContext2D on the real game and
# found it uses SIX operations and nothing else: fillRect, drawImage,
# clearRect, save, restore, translate, plus globalAlpha and
# imageSmoothingEnabled as state. No paths, no gradients, no text, no clips.
# So this gate does not test "canvas" -- it tests that exact op mix, at the
# volume that was actually measured (median 290 draws/frame, worst 9367).
#
# ⛔ WHY THERE IS A NEGATIVE CONTROL, AND WHY IT IS THE POINT
#
# The interesting capability here is the offscreen sprite atlas: the game bakes
# sprites into 3 offscreen canvases once, then blits them 128454 times. A gate
# that only asserts "the frame has the right colours in it" passes on an engine
# that never blits at all, because the fillRects underneath are already
# colourful. So this runs the SAME fixture twice:
#
#   POSITIVE  RNI_SKIP_BLIT=0 -> blit sites MUST show the sprite quadrants
#   NEGATIVE  RNI_SKIP_BLIT=1 -> blit sites MUST show background
#
# The negative is what makes the positive mean something. The macOS tester asked
# for this explicitly, having shipped a green "it rendered" over a wrong screen
# twice already.
#
# ⛔ THE TEST ATLAS IS DELIBERATELY ASYMMETRIC (4 different-coloured quadrants).
# A uniform or symmetric atlas cannot distinguish a correct blit from a
# vertically flipped one -- and the first run of this bench WAS flipped, because
# a GL texture adopted from an FBO carries GL's bottom-left origin while
# Impeller paints top-left. Every colour was real and the frame looked fine.
# Keep the asymmetry.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUILD="${BUILD:-$ROOT/engine/build}"
BIN="$BUILD/canvas-bench"

fail() { echo "CANVAS_GATE_FAIL: $*" >&2; exit 1; }

# ⛔ MAC PORTABILITY, FOUND BY THE macOS tester 2026-08-29 00:2x.
# canvas-bench is linked with the install name "./libimpeller.dylib" (relative,
# no @rpath), so it ONLY runs with the working directory set to $BUILD. This
# script cd's to $ROOT, so invoking "$BIN" from here died in dyld before main()
# and the gate reported CANVAS_GATE_FAIL on a tree where the engine is correct.
# Run every probe with cwd=$BUILD. Do not "fix" this by cd'ing the whole script.
run_bench() { ( cd "$BUILD" && env "$@" ./canvas-bench 2>&1 ); }

# nproc is a GNU coreutils tool and does NOT exist on macOS; the build fallback
# below used it and would die rc=127 on a clean Mac checkout.
ncpu() { command -v nproc >/dev/null 2>&1 && nproc || sysctl -n hw.ncpu; }

if [ ! -x "$BIN" ]; then
  echo "building canvas-bench..."
  cmake --build "$BUILD" --target canvas-bench -j"$(ncpu)" > /tmp/canvas-build.log 2>&1 \
    || { tail -30 /tmp/canvas-build.log; fail "canvas-bench build failed"; }
fi
[ -x "$BIN" ] || fail "no canvas-bench binary at $BIN"

echo "=== POSITIVE: blit enabled ==="
POS="$(run_bench RNI_SKIP_BLIT=0)" || { echo "$POS"; fail "positive run exited non-zero"; }
echo "$POS"
grep -q "CANVAS_BENCH_PASS" <<< "$POS" || fail "positive run did not report PASS"
grep -q "^sprite TL .* OK" <<< "$POS" || fail "sprite did not blit in positive run"

echo
echo "=== NEGATIVE CONTROL: blit skipped, sprite sites MUST be background ==="
NEG="$(run_bench RNI_SKIP_BLIT=1)" || { echo "$NEG"; fail "negative run exited non-zero"; }
echo "$NEG"
grep -q "CANVAS_BENCH_PASS (negative control)" <<< "$NEG" \
  || fail "negative control did not report PASS"

# The two runs MUST disagree at the blit site. If they agree, the blit is not
# doing anything and the positive run passed for the wrong reason.
pos_tl="$(grep '^sprite TL' <<< "$POS" | sed 's/.*got=(\([^)]*\)).*/\1/')"
neg_tl="$(grep '^sprite TL' <<< "$NEG" | sed 's/.*got=(\([^)]*\)).*/\1/')"
[ "$pos_tl" != "$neg_tl" ] \
  || fail "blit site identical with and without the blit ($pos_tl) -- gate is vacuous"
echo
echo "blit site differs as required: with=($pos_tl) without=($neg_tl)"

# Throughput, reported not asserted: llvmpipe in CI is a SOFTWARE rasteriser and
# is the floor, not the number a real GPU will produce. Asserting an fps here
# would make the gate flaky on a busy machine for no gain.
grep "CANVAS_BENCH steady_rects" <<< "$POS" || true
grep "CANVAS_BENCH burst_rects" <<< "$POS" || true

echo
echo "CANVAS_GATE_PASS"
