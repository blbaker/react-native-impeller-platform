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
# both numbers are printed before the first frame. ⛔ NO RESIZE FLAG: the whole
# point is that contentsScale is correct WITHOUT a resize, so consumeDirty()
# never runs. Do not add --resize here or the gate can pass via the change-time
# path and stops proving frame-one correctness.
LOG="$W/eng08.log"
"$ENGINE" --bundle "$BUNDLE" --app-name Eng08 --window \
  --width 320 --height 320 --color-scheme dark --probe-banner off \
  --frames 2 > "$LOG" 2>&1 \
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

# THE ASSERTION. Equality (fails CLOSED), not >= or !=. The layer's real
# contentsScale must equal the display's physical backing scale, or the drawable
# desyncs from the default framebuffer and the window under-renders.
[ "$CS" = "$BS" ] || fail \
  "contentsScale=$CS does not match backing_scale=$BS on frame one. The CALayer \
kept its 1.0 default (or a stale value), so the drawable is $CS/$BS of the \
framebuffer and the window paints a partial extent. GlfwCocoaSetLayerScale must \
run in GlfwSurface::init() before the first present."

echo "ENG08_GATE_PASS (contents_scale=$CS == backing_scale=$BS, frame one, no resize)"
