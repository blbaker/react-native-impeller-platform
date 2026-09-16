#!/usr/bin/env bash
# ENG-08: does the CALayer's contentsScale match the display's backing scale,
# ON FRAME ONE, WITH ZERO RESIZES?
#
# WHY THIS FILE EXISTS
# CAMetalLayer.contentsScale defaults to 1.0. On a 2x display that makes the
# drawable bounds*1 while glfwGetFramebufferSize reports bounds*2, so glViewport
# fills the whole framebuffer but the layer presents a quarter of it -- the
# "quarter window" read. HostApp.app OPENS on 1x and never resizes, so the
# framebuffer-size callback that drives consumeDirty() never fires; a fix that
# lives only there is dead on the arm that reproduces the bug. This gate proves
# the setter runs in init(), before the first present, with no resize.
#
# WHY IT DOES NOT READ THE PICTURE
# A screenshot gate is BLIND to this bug. The app's own pixels are painted,
# correctly coloured, into the top-left quarter; a "did something paint" or
# "painted extent is a valid PPM" gate finds them and passes green. (This is the
# exact trap ci-pointscale.sh:22-25 documents for the fallback branch.) So this
# gate reads the engine's OWN reported numbers. The engine prints, ONCE, before
# any layout, from GlfwSurface::init() right after GlfwCocoaSetLayerScale():
#   rn-impeller: layer contents_scale=<read-back> backing_scale=<display>
# Both come from GlfwCocoaView.mm reading the LIVE layer, not the value we
# intended -- so if the setter is ever dropped, contents_scale falls to its 1.0
# default while backing_scale stays 2.0 and this gate goes red. Prove that with
# tools/mutation-verify-eng08.sh.
#
# Requires a real window, so it is darwin/X11 only and skips elsewhere rather
# than reporting a pass it did not earn.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Default to the STAGED binary (install names rewritten to @loader_path so it
# runs from any cwd), same rationale as ci-pointscale.sh:38-46.
ENGINE="${RNI_BIN:-$ROOT/packages-engine/engine-darwin-arm64/bin/rn-impeller}"

BUNDLE="${RNI_TEST_BUNDLE:-}"
if [ -z "$BUNDLE" ]; then
  BUNDLE="$(bash "$ROOT/tools/fixture-bundle.sh" p3-conformance)" \
    || { echo "ENG08_GATE_FAIL: could not build the fixture bundle"; exit 1; }
fi

fail() { echo "ENG08_GATE_FAIL: $*"; exit 1; }

[ -x "$ENGINE" ] || fail "no engine binary at $ENGINE"
[ -s "$BUNDLE" ] || fail "no bundle at $BUNDLE (set RNI_TEST_BUNDLE)"

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

# A small window (320pt) on the OPEN path. --frames 2 keeps the run bounded and
# both numbers are printed before the first frame. --screenshot-first captures
# frame 1 (the FIRST present) as a full-framebuffer P6 PPM, BEFORE any resize or
# consumeDirty can run. ⛔ NO RESIZE FLAG: the whole point is that contentsScale
# is correct WITHOUT a resize, so consumeDirty() never runs. Do not add --resize
# here or the gate can pass via the change-time path and stops proving frame-one
# correctness.
LOG="$W/eng08.log"
SHOT="$W/frame1.ppm"
"$ENGINE" --bundle "$BUNDLE" --app-name Eng08 --window \
  --width 320 --height 320 --color-scheme dark --probe-banner off \
  --screenshot-first "$SHOT" --frames 2 > "$LOG" 2>&1 \
  || { sed 's/^/   /' "$LOG"; fail "engine exited non-zero (see above)"; }

contents() { sed -n 's/.*rn-impeller: layer contents_scale=\([0-9.]*\).*/\1/p' "$1" | head -1; }
backing()  { sed -n 's/.*rn-impeller: layer .* backing_scale=\([0-9.]*\).*/\1/p'  "$1" | head -1; }

CS="$(contents "$LOG")"
BS="$(backing "$LOG")"

# STEP 0 (skill): assert the extractors are NUMERIC before comparing them. A
# missing line scrapes to empty, and `[ "" = "" ]` would pass open.
num() { awk -v v="$1" 'BEGIN{print (v ~ /^[0-9]+\.[0-9]+$/) ? "y" : "n"}'; }
[ "$(num "$CS")" = "y" ] || fail "no numeric contents_scale on the layer line (got '$CS') -- did the ENG-08 observable print? Is this a windowed build?"
[ "$(num "$BS")" = "y" ] || fail "no numeric backing_scale on the layer line (got '$BS')"

echo "   contents_scale=$CS backing_scale=$BS"

# NULL QUESTION (skill): on a 1x display both read 1.00 and the assertion is
# tautological -- it would pass with the setter deleted. Say so, do not claim a
# proof. Same guard shape as ci-pointscale.sh:141-146.
if [ "$BS" = "1.00" ]; then
  echo "ENG08_GATE_SKIP: this display measures backing_scale=1.00, so a missing"
  echo "  contentsScale setter is numerically identical to a correct one here and"
  echo "  cannot be told apart. Run on a Retina display to exercise the fix."
  exit 0
fi

echo "== 1. the layer's contents_scale matches the display's backing scale =="
# NUMBER ARM. Kills M2 (inert setter -> 1.0), M3 (hardcoded 1.0), M4 (no line).
# ⚠️ It does NOT kill M1 (deleted frame-one setter): on a 2x-Main window AppKit
# and/or consumeDirty leave the read-back number correct even with init()'s
# setter gone, which is exactly why the number-only gate let M1 survive. That is
# what the EXTENT arm below is for. Equality (fails CLOSED), not >= or !=.
[ "$CS" = "$BS" ] || fail \
  "contentsScale=$CS does not match backing_scale=$BS on frame one. The CALayer \
kept its 1.0 default (or a stale value), so the drawable is $CS/$BS of the \
framebuffer and the window paints a partial extent. GlfwCocoaSetLayerScale must \
run in GlfwSurface::init() before the first present."
echo "   OK: contents_scale == backing_scale"

echo "== 2. the FRAME-ONE painted extent fills the window (kills a deleted init setter) =="
# THE ARM THAT ACTUALLY KILLS M1. The number can be auto-corrected off the true
# render path; the PIXELS cannot. If the frame-one contentsScale setter is gone,
# the CALayer keeps its 1.0 default at first present, the drawable is a quarter
# of the framebuffer, and the app paints into ~one quadrant -- measured on the
# Mac as vspan 35% before the fix vs 100% after. We capture frame 1 (before any
# resize) and assert the painted content spans nearly the whole framebuffer on
# BOTH axes. A quarter-window fails both.
[ -s "$SHOT" ] || fail "no frame-1 screenshot at $SHOT -- did --screenshot-first write?"
HEADER="$(head -c 32 "$SHOT" | tr '\n' ' ')"
case "$HEADER" in P6*) : ;; *) fail "frame-1 screenshot is not a valid P6 PPM (header: $HEADER)" ;; esac

# EXTENT_MIN is the assertion; compute the clearance, do not eyeball it. Bug
# fills ~1 quadrant (<=~50% per axis, Mac measured vspan 35%); a correct render
# fills ~100%. 0.90 sits 40 points above the bug and 10 below correct, so it
# separates them with margin. Background is auto-detected as the modal pixel so
# the check does not hardcode a theme colour.
EXTENT_MIN=0.90
read HSPAN VSPAN < <(python3 - "$SHOT" <<'PY'
import sys, struct
p = sys.argv[1]
data = open(p, "rb").read()
# Parse the P6 header: "P6\s+W\s+H\s+MAX\s" then binary RGB triples.
i = 2
def tok():
    global i
    while i < len(data) and data[i:i+1].isspace(): i += 1
    s = i
    while i < len(data) and not data[i:i+1].isspace(): i += 1
    return data[s:i]
w = int(tok()); h = int(tok()); mx = int(tok()); i += 1  # single whitespace after maxval
px = data[i:]
# Modal pixel = background (the huge empty region dominates an under-render).
from collections import Counter
step = max(1, (w*h)//4000)  # sample for speed
c = Counter()
for k in range(0, w*h, step):
    off = k*3
    c[px[off:off+3]] += 1
bg = c.most_common(1)[0][0]
minx, miny, maxx, maxy = w, h, -1, -1
for y in range(h):
    row = y*w*3
    for x in range(w):
        o = row + x*3
        if px[o:o+3] != bg:
            if x < minx: minx = x
            if x > maxx: maxx = x
            if y < miny: miny = y
            if y > maxy: maxy = y
if maxx < 0:
    # The ENTIRE framebuffer is a single colour. That is a FULLY painted window
    # (a partial/quarter drawable would leave a DIFFERENT clear colour in the
    # unpainted region, so it could never be uniform), not an empty one.
    print("1.000 1.000")
else:
    print("%.3f %.3f" % ((maxx-minx+1)/w, (maxy-miny+1)/h))
PY
)
echo "   painted extent: hspan=$HSPAN vspan=$VSPAN (framebuffer, min=$EXTENT_MIN)"
awk -v hs="$HSPAN" -v vs="$VSPAN" -v m="$EXTENT_MIN" 'BEGIN{exit !(hs+0>=m && vs+0>=m)}' || fail \
  "frame-one paint fills hspan=$HSPAN vspan=$VSPAN of the framebuffer, below $EXTENT_MIN. \
The window under-rendered to a partial extent (quarter-window). The frame-one \
GlfwCocoaSetLayerScale call in GlfwSurface::init() is missing or not taking effect \
before the first present."
echo "   OK: frame-one paint fills the window on both axes"

echo "ENG08_GATE_PASS (contents_scale=$CS == backing_scale=$BS; frame-one extent hspan=$HSPAN vspan=$VSPAN; no resize)"
