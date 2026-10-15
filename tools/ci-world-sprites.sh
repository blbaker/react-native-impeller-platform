#!/usr/bin/env bash
# ENG-10 gate — does WorldRaster.drawSprites composite a back-to-front sprite
# list ON THE GPU, inside ONE <world> node, with the SAME pixels a CPU
# composite of the identical list produces?
#
# Fixture: fixtures/eng10-world-sprites (shared scene.js). Two renders:
#   sprites   = terrain via setPixels + registerSprite atlas + ONE drawSprites
#   reference = the identical scene composited on the CPU (scene.js
#               compositeOnCpu) and pushed as ONE buffer through the proven
#               ENG-09 setPixels path. This is the oracle.
#
# ⛔ BOTH ARMS ARE REQUIRED, TOGETHER (same argument as ci-world-raster.sh):
#   ARM A (structure): sprites render has a SMALL scene_nodes AND the engine
#     reports world_sprites_drawn == the list length the fixture logged. A
#     per-sprite-node regression blows scene_nodes; a drawSprites that parses
#     the list but never issues the GPU draws fails the count. Pixels alone
#     cannot tell "GPU composited" from "fell back to something else".
#   ARM B (pixels): PER-PIXEL match vs the oracle. A histogram is blind to
#     draw ORDER, wrong ATLAS entry and ORIENTATION (all move pixels without
#     changing the luma set) -- so ARM B compares the same (x,y) everywhere.
#     Counts alone cannot tell a correct composite from a garbage one.
# Plus a contract arm: bad byteLength and unregistered textureId must THROW.
#
# Mutation-verified by tools/mutation-verify-world-sprites.sh.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
RNI_ENGINE_PKG="${RNI_ENGINE_PKG:-$ROOT/packages-engine/engine-linux-x64}"
FIXDIR="$ROOT/fixtures/eng10-world-sprites"

# Must equal scene.js WIDTH/HEIGHT: a mismatched surface letterboxes/crops.
W=320
H=240

# ⛔ PIN THE ROOT SUPERSAMPLE OFF. The engine's DEFAULT differs by platform
# (--supersample-rnsvg 4 on darwin, 0 elsewhere). At N>=2 the whole tree is
# drawn into an N x offscreen: every world texture is linear-MAGNIFIED 4x and
# linearly shrunk back, which blurs each hard edge by up to ~44 levels. The
# oracle is ONE texture and the sprites are 145 separate ones, so their edges
# blur DIFFERENTLY and ARM B fails on a correct sprite path (darwin 2026-09-26:
# 10952 bad px; linux forced to N=4 reproduces the Mac shots to 2 levels).
# This gate proves the SPRITE path, so both renders take the exact in-place
# path on every platform. RNI_SUPERSAMPLE=4 reproduces the darwin default.
SUPERSAMPLE="${RNI_SUPERSAMPLE:-0}"

fail() { echo "WORLD_SPRITES_GATE_FAIL: $*" >&2; exit 1; }

[ -d "$BASE_APP/node_modules/react-native" ] || bash tools/base-app.sh
[ -d "$BASE_APP/node_modules/react-native" ] || fail "no base RN app at $BASE_APP"
for f in index.js reference-index.js scene.js; do
  [ -f "$FIXDIR/$f" ] || fail "missing fixture $FIXDIR/$f"
done

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
APP="$WORK/WorldSpritesApp"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="worldspritesapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="Eng10Sprites"; a.displayName="Eng10Sprites";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent \
  "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" || fail "npm install of the tarballs failed"
npx --no-install react-native init-impeller >/dev/null 2>&1 || fail "init-impeller failed"
ENGINE="$(node node_modules/@react-native-impeller/core/src/bin/engine-path.js)" \
  || fail "engine resolver failed"
# RNI_BIN overrides the installed engine (tools/ci-sanitize.sh runs this gate on the ASan build).
[ -z "${RNI_BIN:-}" ] || ENGINE="$RNI_BIN"

run_headless() {
  local entry="$1" appname="$2" bundle_out="$3" shot="$4" log="$5"
  cp "$FIXDIR/scene.js" "$APP/scene.js"
  cp "$entry" "$APP/index.js"
  npx --no-install react-native bundle --platform impeller --dev false \
      --entry-file index.js --bundle-output "$bundle_out" \
      >/dev/null 2>&1 || fail "bundle failed for $entry"
  [ -s "$bundle_out" ] || fail "no bundle produced for $entry"
  "$ENGINE" --bundle "$bundle_out" --app-name "$appname" --headless \
    --probe-banner off --width "$W" --height "$H" \
    --supersample-rnsvg "$SUPERSAMPLE" --screenshot "$shot" \
    > "$log" 2>&1 &
  local pid=$!
  rni_track "$pid"
  wait "$pid"
  local rc=$?
  [ "$rc" -eq 0 ] || { sed 's/^/   /' "$log" | tail -40; fail "engine run failed for $entry (rc=$rc)"; }
  [ -s "$shot" ] || fail "no screenshot produced for $entry"
}

echo "== 2. render sprites via GPU drawSprites (new path) =="
SPR_SHOT="$WORK/sprites.ppm"; SPR_LOG="$WORK/sprites.log"
run_headless "$FIXDIR/index.js" Eng10Sprites "$APP/impeller/build/spr.bundle" "$SPR_SHOT" "$SPR_LOG"

echo "== 3. render the CPU-composite oracle via setPixels =="
REF_SHOT="$WORK/ref.ppm"; REF_LOG="$WORK/ref.log"
run_headless "$FIXDIR/reference-index.js" Eng10SpritesReference "$APP/impeller/build/ref.bundle" "$REF_SHOT" "$REF_LOG"
grep -q 'ENG10_REFERENCE composited' "$REF_LOG" || fail "reference fixture never composited (JS effect did not run?)"

if [ -n "${SHOT_OUT:-}" ]; then
  mkdir -p "$SHOT_OUT"; cp "$SPR_SHOT" "$REF_SHOT" "$SHOT_OUT/"
fi

num_field() { sed -n "s/^rn-impeller: $1=\([0-9]*\)$/\1/p" "$2" | head -1; }

echo "== 4. CONTRACT -- bad byteLength and unregistered textureId THROW =="
for probe in bad-length unregistered-id; do
  grep -q "ENG10_THROW_OK $probe" "$SPR_LOG" || fail \
    "contract probe '$probe' did not throw (log: $(grep -o "ENG10_THROW_[A-Z]* $probe" "$SPR_LOG" || echo none)). A silent no-op here is the 'nothing drawn, no signal' failure WorldRaster forbids."
done
echo "   OK: both strict-throw probes threw"

echo "== 5. ARM A -- ONE <world> node, and every sprite went through the GPU path =="
spr_nodes="$(num_field scene_nodes "$SPR_LOG")"
drawn="$(num_field world_sprites_drawn "$SPR_LOG")"
ref_drawn="$(num_field world_sprites_drawn "$REF_LOG")"
want="$(sed -n 's/.*ENG10_SPRITES n=\([0-9]*\).*/\1/p' "$SPR_LOG" | head -1)"
case "$spr_nodes" in ''|*[!0-9]*) fail "no numeric scene_nodes in sprites log (got '$spr_nodes')";; esac
case "$drawn" in ''|*[!0-9]*) fail "no numeric world_sprites_drawn in sprites log (got '$drawn')";; esac
case "$want" in ''|*[!0-9]*) fail "fixture never logged ENG10_SPRITES n= (JS effect did not run?)";; esac
echo "   scene_nodes=$spr_nodes world_sprites_drawn=$drawn list_len=$want reference_drawn=$ref_drawn"
# The pin above is only real if the engine honoured it in BOTH renders.
for lg in "$SPR_LOG" "$REF_LOG"; do
  ss="$(num_field supersample_rnsvg "$lg")"
  [ "$ss" = "$SUPERSAMPLE" ] || fail \
    "engine ran with supersample_rnsvg='$ss', gate pinned $SUPERSAMPLE ($(basename "$lg")) -- ARM B would compare two differently-resampled renders."
done
NODES_MAX=10
[ "$spr_nodes" -le "$NODES_MAX" ] || fail \
  "scene_nodes=$spr_nodes exceeds $NODES_MAX -- sprites are NOT collapsing into one <world> node (per-sprite node regression)."
[ "$want" -ge 100 ] || fail "fixture list has only $want sprites; expected the ~130-sprite lattice (scene.js drifted?)"
[ "$drawn" -eq "$want" ] || fail \
  "world_sprites_drawn=$drawn != drawSprites list length $want -- the list reached the engine but not every quad was issued as a GPU DrawTextureRect."
[ "${ref_drawn:-0}" -eq 0 ] || fail "reference render drew $ref_drawn sprites; the oracle must be the pure setPixels path"
echo "   OK: 1 <world> node, $drawn/$want GPU sprite draws"

echo "== 6. ARM B -- PER-PIXEL match vs the CPU-composite oracle =="
[ -x "$(command -v python3)" ] || fail "python3 not found"
PIX_TOL=6
DIFF_OUT="$(python3 "$ROOT/tools/sprite-composite-diff.py" "$SPR_SHOT" "$REF_SHOT" --pix-tol=$PIX_TOL)" \
  || fail "sprite-composite-diff.py failed: $DIFF_OUT"
echo "$DIFF_OUT" | sed 's/^/   /'
get_field() { echo "$DIFF_OUT" | sed -n "s/^$1 //p"; }
case "$DIFF_OUT" in *DIMENSION_MISMATCH*) fail "dimension mismatch: $DIFF_OUT";; esac
BAD="$(get_field BAD_PIXELS)"; MAXD="$(get_field MAX_CHANNEL_DIFF)"
DA="$(get_field DISTINCT_LUMA_A)"; DB="$(get_field DISTINCT_LUMA_B)"
case "$BAD" in ''|*[!0-9]*) fail "no numeric BAD_PIXELS (got '$BAD')";; esac
# TOLERANCE. Same scene, same 8-bit blend order, 1:1 texel sampling: a correct
# composite differs from the oracle only by per-draw rounding (<= a few levels).
# PIX_TOL=6 absorbs that; BAD_PIXELS must be ZERO. A real ANGLE-Metal driver
# gets the same headroom -- this is not a target to aim for.
[ "$BAD" -eq 0 ] || fail \
  "$BAD pixels differ from the CPU-composite oracle by > $PIX_TOL (max $MAXD at $(get_field WORST_AT)). Wrong draw order, wrong atlas entry, wrong orientation, wrong alpha or wrong premultiplication all land here."
# Non-degeneracy: both renders must carry the whole scene, not a blank frame
# that trivially matches another blank frame.
[ "$DA" -ge 40 ] && [ "$DB" -ge 40 ] || fail \
  "degenerate render: distinct luma A=$DA B=$DB (want >= 40 each) -- the scene did not paint."
echo "   OK: 0 pixels over tolerance $PIX_TOL (max channel diff $MAXD), distinct luma A=$DA B=$DB"

echo "WORLD_SPRITES_GATE_PASS (scene_nodes=$spr_nodes sprites=$drawn/$want max_channel_diff=$MAXD)"
