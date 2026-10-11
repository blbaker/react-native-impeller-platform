#!/usr/bin/env bash
# ENG-09 gate — does <world>+WorldRaster.setPixels replace a ~238-RNSVGPath
# decomposition with the SAME pixels, through a SMALL, CONSTANT scene graph?
#
# ⛔ WHY BOTH ASSERTIONS ARE REQUIRED, TOGETHER
#
# This gate has two arms and a pass requires BOTH, for exactly the same
# reason ci-eng08.sh needs its number arm AND its extent arm (see that file's
# header): each arm alone is satisfied by a DIFFERENT, DIFFERENT-LOOKING
# broken engine.
#
#   NODES-ALONE IS VACUOUS: an engine that mounts <world> as an unregistered
#   plain View (M1 below) ALSO reports a small scene_nodes count -- an
#   unrecognised component still mounts as exactly one node, it just paints
#   nothing. A gate that only checked "is scene_nodes small" would go GREEN
#   on a <world> that renders a blank rectangle. Small nodes is necessary,
#   not sufficient.
#
#   LUMA-ALONE IS VACUOUS: the reference (path-decomposition) render could be
#   reproduced by an engine that did NOT change the scene graph strategy at
#   all -- e.g. one that silently fell back to decomposing <world> into 238
#   RNSVGPath nodes internally, defeating the entire point of ENG-09 (a
#   TurboModule + one GPU texture instead of hundreds of vector nodes). A
#   luma match with scene_nodes=242 would be a PASS on a renderer that
#   changed nothing about the architecture. Pixel-identical output is
#   necessary, not sufficient either.
#
# Only NODES SMALL *AND* PIXELS MATCHING, TOGETHER, is evidence that <world>
# is (a) actually painting the real published buffer, through (b) the new,
# collapsed scene-graph path this feature exists to deliver.
#
# Mutation-verified by tools/mutation-verify-world-raster.sh: M1 (unregistered
# component), M2 (inert setter), M3 (skipped Y-flip) must each fail THIS gate.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
RNI_ENGINE_PKG="${RNI_ENGINE_PKG:-$ROOT/packages-engine/engine-linux-x64}"
FIXDIR="$ROOT/fixtures/eng09-world-raster"

# Match the fixtures' own dimensions (17*20 x 14*20 -- see pattern.js). A
# gate-supplied --width/--height that disagreed with the fixture's own
# buffer size would silently letterbox/crop the pattern and corrupt the
# comparison without either render being "wrong".
W=340
H=280

fail() { echo "WORLD_RASTER_GATE_FAIL: $*" >&2; exit 1; }

[ -d "$BASE_APP/node_modules/react-native" ] || bash tools/base-app.sh
[ -d "$BASE_APP/node_modules/react-native" ] || fail "no base RN app at $BASE_APP"
[ -f "$FIXDIR/index.js" ] || fail "missing fixture $FIXDIR/index.js"
[ -f "$FIXDIR/reference-index.js" ] || fail "missing fixture $FIXDIR/reference-index.js"
[ -f "$FIXDIR/pattern.js" ] || fail "missing fixture $FIXDIR/pattern.js"

WORK="$(mktemp -d)"
KEEP="${KEEP_WORKDIR:-0}"
cleanup() {
  rni_kill_own
  [ "$KEEP" = "1" ] && echo "workdir kept: $WORK" || rm -rf "$WORK"
}
trap cleanup EXIT

echo "== 1. pack + install into a pristine app OUTSIDE the repo =="
ENGINE_TGZ="$(cd "$RNI_ENGINE_PKG" && npm pack --silent --pack-destination "$WORK")"
MAIN_TGZ="$(cd package && npm pack --silent --pack-destination "$WORK")"
APP="$WORK/WorldRasterApp"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="worldrasterapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="Eng09World"; a.displayName="Eng09World";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent \
  "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" || fail "npm install of the tarballs failed"

# react-native-svg is only needed for the REFERENCE render.
npm install --no-audit --no-fund --silent react-native-svg@15.15.5 \
  || fail "could not install react-native-svg into the consumer app"

npx --no-install react-native init-impeller >/dev/null 2>&1 || fail "init-impeller failed"
ENGINE="$(node node_modules/@react-native-impeller/core/src/bin/engine-path.js)" \
  || fail "engine resolver failed"

run_headless() {
  local entry="$1" appname="$2" bundle_out="$3" shot="$4" log="$5"
  # Both fixtures `import ... from './pattern'` -- copy it alongside every
  # entry file we stage, not just the entry itself.
  cp "$FIXDIR/pattern.js" "$APP/pattern.js"
  cp "$entry" "$APP/index.js"
  npx --no-install react-native bundle --platform impeller --dev false \
      --entry-file index.js --bundle-output "$bundle_out" \
      >/dev/null 2>&1 || fail "bundle failed for $entry"
  [ -s "$bundle_out" ] || fail "no bundle produced for $entry"
  "$ENGINE" --bundle "$bundle_out" --app-name "$appname" --headless \
    --probe-banner off --width "$W" --height "$H" --screenshot "$shot" \
    > "$log" 2>&1 &
  local pid=$!
  rni_track "$pid"
  wait "$pid"
  local rc=$?
  [ "$rc" -eq 0 ] || { sed 's/^/   /' "$log"; fail "engine run failed for $entry (rc=$rc)"; }
  [ -s "$shot" ] || fail "no screenshot produced for $entry"
}

echo "== 2. render the <world> node (new path) =="
WORLD_BUNDLE="$APP/impeller/build/world.impeller.bundle"
WORLD_SHOT="$WORK/world.ppm"
WORLD_LOG="$WORK/world.log"
run_headless "$FIXDIR/index.js" Eng09World "$WORLD_BUNDLE" "$WORLD_SHOT" "$WORLD_LOG"

echo "== 3. render the ~238-RNSVGPath decomposition (reference/old path) =="
REF_BUNDLE="$APP/impeller/build/ref.impeller.bundle"
REF_SHOT="$WORK/ref.ppm"
REF_LOG="$WORK/ref.log"
run_headless "$FIXDIR/reference-index.js" Eng09WorldReference "$REF_BUNDLE" "$REF_SHOT" "$REF_LOG"

echo "== 4. ARM A -- scene_nodes for the world surface is a SMALL CONSTANT =="
# scene_nodes must be numeric before comparing, same guard shape as
# ci-eng08.sh's num() check -- a missing line scrapes to empty and a naive
# comparison would pass open.
world_nodes="$(sed -n 's/^rn-impeller: scene_nodes=\([0-9]*\)$/\1/p' "$WORLD_LOG" | head -1)"
ref_nodes="$(sed -n 's/^rn-impeller: scene_nodes=\([0-9]*\)$/\1/p' "$REF_LOG" | head -1)"
case "$world_nodes" in ''|*[!0-9]*) fail "no numeric scene_nodes in world log (got '$world_nodes')";; esac
case "$ref_nodes" in ''|*[!0-9]*) fail "no numeric scene_nodes in reference log (got '$ref_nodes')";; esac
echo "   world scene_nodes=$world_nodes  reference scene_nodes=$ref_nodes"

# Threshold: <world> + its wrapping <View> + the implicit RootView is 3.
# NODES_MAX gives headroom for chrome without weakening the "small constant,
# NOT ~650" claim: a regression back to per-tile decomposition would report
# ~238+ nodes, nowhere near this ceiling.
NODES_MAX=10
[ "$world_nodes" -le "$NODES_MAX" ] || fail \
  "world scene_nodes=$world_nodes exceeds $NODES_MAX -- <world> is not collapsing to a \
single image node + chrome. This is the exact regression ENG-09 exists to prevent: a \
world surface that silently decomposes back into many nodes."
# The reference render is expected to be node-heavy -- it is the OLD strategy
# this gate proves <world> replaces. Asserting it too documents the contrast
# a reader would otherwise have to take on faith.
REF_NODES_MIN=200
[ "$ref_nodes" -ge "$REF_NODES_MIN" ] || fail \
  "reference scene_nodes=$ref_nodes is below $REF_NODES_MIN -- the reference fixture no \
longer builds the ~238-path decomposition this gate is meant to contrast against \
(fixtures/eng09-world-raster/reference-index.js drifted from pattern.js?)."
echo "   OK: world scene_nodes ($world_nodes) is a small constant; reference ($ref_nodes) is node-heavy, as expected"

echo "== 5. ARM B -- luma histogram of <world> matches the reference within tolerance =="
[ -x "$(command -v python3)" ] || fail "python3 not found"
DIFF_OUT="$(python3 "$ROOT/tools/luma-histogram-diff.py" "$WORLD_SHOT" "$REF_SHOT")" \
  || fail "luma-histogram-diff.py failed: $DIFF_OUT"
echo "$DIFF_OUT" | sed 's/^/   /'

get_field() { echo "$DIFF_OUT" | sed -n "s/^$1 //p"; }
case "$DIFF_OUT" in *DIMENSION_MISMATCH*) fail "world and reference screenshots have different dimensions: $DIFF_OUT";; esac

PCT="$(get_field HIST_L1_PCT)"
DISTINCT_A="$(get_field DISTINCT_LUMA_A)"
DISTINCT_B="$(get_field DISTINCT_LUMA_B)"
case "$PCT" in ''|*[!0-9.]*) fail "no numeric HIST_L1_PCT (got '$PCT')";; esac

# TOLERANCE: 0.02 (2% of the total luma mass may differ). The pattern is
# generated from the SAME levelForTile() ramp in both fixtures and both
# renders happen at identical dimensions, so a correct <world> render is
# BYTE-IDENTICAL to the reference (measured: HIST_L1_PCT=0.000000 on the
# real ENG-09 build) -- 0.02 is headroom for legitimate float/antialiasing
# noise on a real GPU driver, not a target to aim for.
TOLERANCE="0.02"
over_tolerance="$(awk -v p="$PCT" -v t="$TOLERANCE" 'BEGIN{print (p>t)?"y":"n"}')"
[ "$over_tolerance" = "n" ] || fail \
  "luma histogram L1 distance ${PCT} exceeds tolerance ${TOLERANCE}. The <world> render \
does not match the path-decomposition reference -- either the published buffer never \
reached the GPU texture (stale/blank), or it was drawn wrong (e.g. upside down)."

# Also require both renders to have painted the whole 238-level ramp, not
# some degenerate subset -- a renderer that clamped/quantized the buffer
# could still pass a loose histogram distance while visibly banding.
MIN_DISTINCT=200
[ "$DISTINCT_A" -ge "$MIN_DISTINCT" ] || fail \
  "world render has only $DISTINCT_A distinct luma levels (want >= $MIN_DISTINCT) -- the \
238-tile ramp did not survive the round trip."
[ "$DISTINCT_B" -ge "$MIN_DISTINCT" ] || fail \
  "reference render has only $DISTINCT_B distinct luma levels (want >= $MIN_DISTINCT) -- \
the reference fixture itself is degenerate; fix it before trusting this gate."

# ⛔ THE HISTOGRAM ALONE CANNOT CATCH ORIENTATION. A luma histogram counts
# HOW MANY pixels hold each value, not WHERE -- a vertically flipped render
# of this exact ramp has an IDENTICAL histogram to the correct one (every
# tile row just trades places with another row at the same luma level).
# Measured directly by tools/mutation-verify-world-raster.sh's M3 (skipped
# Y-flip): HIST_L1_PCT alone is 0.0 on that mutant, i.e. invisible to it.
# MAX_POINT_DIFF compares the SAME (x,y) between the two renders at 9
# well-separated points; the ramp is monotonic top-to-bottom, so a flip
# disagrees by ~200 luma at every off-center row (measured) while a correct
# render agrees to within antialiasing noise at all nine.
POINT_TOLERANCE=10
MAX_POINT_DIFF="$(get_field MAX_POINT_DIFF)"
case "$MAX_POINT_DIFF" in ''|*[!0-9]*) fail "no numeric MAX_POINT_DIFF (got '$MAX_POINT_DIFF')";; esac
[ "$MAX_POINT_DIFF" -le "$POINT_TOLERANCE" ] || fail \
  "positional luma check failed: MAX_POINT_DIFF=$MAX_POINT_DIFF exceeds tolerance \
$POINT_TOLERANCE (see $(get_field MAX_POINT_DIFF_AT) above). The two renders have matching \
histograms but disagree at specific coordinates -- the classic signature of a correct \
pattern painted in the WRONG ORIENTATION (e.g. a missing Y-flip)."

echo "   OK: luma histogram L1 diff = ${PCT} (tolerance ${TOLERANCE}), distinct levels A=$DISTINCT_A B=$DISTINCT_B, max positional diff = $MAX_POINT_DIFF (tolerance $POINT_TOLERANCE)"

echo "WORLD_RASTER_GATE_PASS (world_nodes=$world_nodes ref_nodes=$ref_nodes hist_l1_pct=$PCT)"
