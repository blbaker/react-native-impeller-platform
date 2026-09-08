#!/usr/bin/env bash
# Does --scale still OVERRIDE the display's measured backing scale, and does
# its absence still fall back to the display?
#
# WHY THIS FILE EXISTS
# retina-check.sh already proves --scale changes resolution rather than layout,
# but it runs --headless at BOTH scales. A headless surface has no display
# behind it, so its backing scale is always 1 and the fallback branch this gate
# covers is unreachable there. That is exactly how the windowed under-render
# survived a green retina gate: the instrument was sound and pointed at the one
# path that cannot exhibit the bug.
#
# The branch under test is scaleWasExplicit in RunWindowed. It decides between
# the CLI's --scale and the surface's own measured backingScale(). Both arms
# produce a window that LOOKS right to a human and to any screenshot that only
# asks "did something paint", because:
#
#   - override lost   : the display scale is used anyway, and on a Retina Mac
#                       that is 2.0, which is what most callers wanted. A gate
#                       asserting "sharp" passes while --scale 1 silently does
#                       nothing.
#   - fallback lost   : pointScale stays 1.0, the frame under-renders into a
#                       quarter of the framebuffer, and a gate that only reads
#                       the app's own pixels still finds them, correctly
#                       coloured, in the top-left.
#
# So this gate reads the engine's OWN reported numbers, not the picture. The
# engine prints, once, before any layout:
#   rn-impeller: window backing_scale=<measured> fb=<W>x<H> px paint_scale=<used>
# and Fabric prints:
#   [fabric] surface 1 (app) started <W>x<H> points @<S>x (<W>x<H> px)
#
# Requires a real window, so it is darwin/X11 only and skips elsewhere rather
# than reporting a pass it did not earn.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Default to the STAGED binary, not engine/build/rn-impeller. The build-tree
# binary links './libimpeller.dylib' by relative path, so it only runs with cwd
# set to engine/build; from anywhere else it dies with `dyld: Library not
# loaded: ./libimpeller.dylib` and `Abort trap: 6`. That abort is the same
# symptom an unsigned or wrongly-named image produces, which is precisely the
# confusion tools/engine-build.sh:195-244 exists to prevent, so it is worth not
# reproducing here. The staged package has its install names rewritten to
# @loader_path and runs from any directory.
ENGINE="${RNI_BIN:-$ROOT/packages-engine/engine-darwin-arm64/bin/rn-impeller}"
# ⛔ NEVER AN ABSOLUTE PATH INTO A PARTICULAR APPLICATION.
# This line used to read the author's own app bundle out of a fixed home
# directory. That made this an application's gate wearing the engine's name: it
# could not run on any other machine, and a consumer who copied it inherited a
# path that cannot exist for them. The fixture ships in this repo, so the
# default is now reproducible anywhere the repo is. RNI_TEST_BUNDLE overrides
# it for anyone who wants to point the gate at their own app.
BUNDLE="${RNI_TEST_BUNDLE:-}"
if [ -z "$BUNDLE" ]; then
  BUNDLE="$(bash "$ROOT/tools/fixture-bundle.sh" p3-conformance)" \
    || { echo "POINTSCALE_GATE_FAIL: could not build the fixture bundle"; exit 1; }
fi

fail() { echo "POINTSCALE_GATE_FAIL: $*"; exit 1; }

[ -x "$ENGINE" ] || fail "no engine binary at $ENGINE"
[ -s "$BUNDLE" ] || fail "no bundle at $BUNDLE (set RNI_TEST_BUNDLE)"

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

# --frames keeps each run bounded; the numbers this gate reads are all printed
# before the first frame, so 2 is plenty and the run cannot hang waiting for a
# human to close a window.
# The window is REQUESTED in points on the command line; px= is what
# glfwGetFramebufferSize actually reported. Their ratio is the display's real
# backing scale and it is measured on a code path the branch under test cannot
# touch, which is the whole reason it is read here rather than off scale=.
REQ_W=1280
REQ_H=860
run() {
  local log="$1"; shift
  "$ENGINE" --bundle "$BUNDLE" --app-name PointScale --window \
    --width $REQ_W --height $REQ_H --color-scheme dark --probe-banner off \
    --frames 2 "$@" > "$log" 2>&1
}

# ⛔ THE ENGINE STOPPED PRINTING TWO NUMBERS. PARSE THE PROVENANCE INSTEAD.
# Until f92ef6e the windowed line read
#     rn-impeller: window backing_scale=<measured> fb=<W>x<H> px paint_scale=<used>
# and this gate read the two fields separately. f92ef6e replaced it with
#     rn-impeller: window px=<W>x<H> points=<W>x<H> scale=<used> (<provenance>)
# where provenance is "from framebuffer" or "--scale override", taken from the
# same pointScaleGiven flag the branch under test keys off. So there is exactly
# ONE scale on the line now, and the measured-vs-used comparison that used to
# be two fields is now the SUFFIX. Reading scale= alone and calling it
# "measured" would make arm 1 tautological -- it would pass with the fallback
# branch deleted, which is the precise failure this gate exists to catch.
# The real measured scale is recovered independently in step 4, from the ratio
# of the two runs' surface point sizes, which come from a different code path
# ([fabric] surface) than this line.
used()       { sed -n 's/.*rn-impeller: window .* scale=\([0-9.]*\).*/\1/p' "$1" | head -1; }
provenance() { sed -n 's/.*rn-impeller: window .* scale=[0-9.]* (\(.*\))$/\1/p' "$1" | head -1; }
pxwidth()    { sed -n 's/.*rn-impeller: window px=\([0-9]*\)x[0-9]*.*/\1/p' "$1" | head -1; }
surface()  { sed -n 's/^\[fabric\] surface .* started \([0-9.]*x[0-9.]*\) points @\([0-9]*\)x.*/\1 @\2x/p' "$1" | head -1; }

echo "== 1. no --scale: the DISPLAY decides =="
run "$W/auto.log" || fail "engine exited non-zero with no --scale (see $W/auto.log)"
U_AUTO="$(used "$W/auto.log")"
V_AUTO="$(provenance "$W/auto.log")"
PX_AUTO="$(pxwidth "$W/auto.log")"
[ -n "$U_AUTO" ] || fail "engine printed no windowed scale= line — is this a windowed build?"
[ -n "$PX_AUTO" ] || fail "engine printed no px= on the windowed line"

# ⛔ THE MEASURED SCALE COMES FROM THE FRAMEBUFFER, NOT FROM scale=.
# Deriving it from the number the engine CHOSE makes arm 1 tautological and
# makes the 1x skip guard read the value under test: measured 2026-09-04, the
# fallback mutant made scale= read 1.00, the guard concluded "this is a 1x
# display", the gate SKIPped, and the mutant escaped a harness that exited 0.
# px= is glfwGetFramebufferSize's own report and REQ_W is what we asked for in
# points; neither passes through DeriveWindowPointScale.
M_AUTO="$(python3 -c "print('%.2f' % ($PX_AUTO / $REQ_W))")"
echo "   measured=$M_AUTO (px=$PX_AUTO / requested=$REQ_W) used=$U_AUTO provenance='$V_AUTO' surface=$(surface "$W/auto.log")"
[ "$V_AUTO" = "from framebuffer" ] || fail \
  "fallback branch is dead: no --scale was passed but the engine reported provenance '$V_AUTO' instead of 'from framebuffer'."
[ "$U_AUTO" = "$M_AUTO" ] || fail \
  "fallback branch is dead: no --scale was passed but the engine used $U_AUTO instead of the framebuffer's measured $M_AUTO. The window will under-render on any display whose backing scale is not $U_AUTO."

echo "== 2. --scale 1 on the same display: the FLAG must win =="
run "$W/one.log" --scale 1 || fail "engine exited non-zero with --scale 1"
U_ONE="$(used "$W/one.log")"
V_ONE="$(provenance "$W/one.log")"
echo "   used=$U_ONE provenance='$V_ONE' surface=$(surface "$W/one.log")"
[ "$U_ONE" = "1.00" ] || fail \
  "override branch is dead: --scale 1 was passed but scale=$U_ONE. An explicit scale that silently stops overriding is invisible to a screenshot that already looks correct."
[ "$V_ONE" = "--scale override" ] || fail \
  "--scale 1 was passed but the engine reported provenance '$V_ONE'. D-46: comparing pointScale to 1.0f will not do, the default IS 1.0, so an explicit --scale 1 must stay distinguishable from no flag at all."

# THE ASSERTION THAT MAKES THIS GATE WORTH RUNNING.
# If the display's own scale happens to equal the CLI default, both branches
# return the same number and neither assertion above can distinguish them. On a
# 1x display measured=1.00 and --scale 1 is indistinguishable from no flag, so
# the gate would pass with the branch removed entirely. Say so instead of
# claiming a proof.
if [ "$M_AUTO" = "1.00" ]; then
  echo "POINTSCALE_GATE_SKIP: this display measures 1.00, so the override and"
  echo "  fallback arms are numerically identical here and cannot be told apart."
  echo "  Run on a Retina display to exercise the branch."
  exit 0
fi

echo "== 3. the two arms really did differ =="
[ "$U_AUTO" != "$U_ONE" ] || fail \
  "both runs used paint_scale=$U_AUTO, so nothing distinguished --scale from its absence"

echo "== 4. layout stays in POINTS across both arms =="
# A scale change must alter resolution, not the size of the surface in points.
# Same trap retina-check.sh documents: feeding raw device pixels to Yoga makes
# a 2x run lay out twice the points and still paint a plausible picture.
P_AUTO="$(sed -n 's/^\[fabric\] surface .* started \([0-9.]*x[0-9.]*\) points .*/\1/p' "$W/auto.log" | head -1)"
P_ONE="$(sed -n 's/^\[fabric\] surface .* started \([0-9.]*x[0-9.]*\) points .*/\1/p' "$W/one.log" | head -1)"
echo "   points: auto=$P_AUTO scale1=$P_ONE"
[ -n "$P_AUTO" ] && [ -n "$P_ONE" ] || fail "could not read the surface point size"
# auto runs at the display scale, so its point size is the framebuffer divided
# by that scale; --scale 1 lays out the whole framebuffer as points. They are
# EXPECTED to differ, and the ratio is the measured scale. That is the honest
# relationship: assert it rather than asserting equality, which would be wrong.
python3 - "$P_AUTO" "$P_ONE" "$M_AUTO" <<'PY' || fail "point-size relationship does not hold"
import sys
a_w, a_h = (float(v) for v in sys.argv[1].split('x'))
o_w, o_h = (float(v) for v in sys.argv[2].split('x'))
s = float(sys.argv[3])
assert abs(o_w / a_w - s) < 0.02, f"width ratio {o_w/a_w:.3f} != measured scale {s}"
assert abs(o_h / a_h - s) < 0.02, f"height ratio {o_h/a_h:.3f} != measured scale {s}"
print(f"   OK: --scale 1 lays out {s:g}x the points of the auto run, as expected")
PY

echo "POINTSCALE_GATE_PASS (measured=$M_AUTO auto_used=$U_AUTO override_used=$U_ONE)"
