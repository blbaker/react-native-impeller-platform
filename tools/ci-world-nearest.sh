#!/usr/bin/env bash
# ENG-21 gate: a <world> can sample its setPixels terrain AND its
# registerSprite sprites NEAREST-neighbour, per world, with linear the default.
#
# THE BUG. paintWorldNode and paintWorldSprites hard-coded
# kImpellerTextureSamplingLinear. Pixel art drawn at an integer scale K got
# every art-pixel edge blended over about one screen px. ROOM-1 (HostApp, darwin,
# K=3) measured the room frame 0.004 from a CPU BILINEAR composite and 1.209
# from a NEAREST one, with 12.7% of pixels holding a colour no nearest
# reference contains (ENGINE-LEDGER ENG-21).
#
# THE ORACLE IS A CPU COMPOSITE OF THE SAME SCENE. Fixture
# fixtures/eng21-world-nearest: two <world> nodes, identical 20x8 terrain at
# K=12 plus a 4x4 checker sprite. One calls setSampling(name, 'nearest'); the
# other never does (control). tools/world-nearest-diff.py rebuilds both
# filters on the CPU and reports ROOM-1's measures per world.
#
#   C. CONTRACT. setSampling exists, an unknown mode THROWS, both worlds
#      drew their sprite (world_sprites_drawn=2).
#   A. NEAREST WORLD. diff_nearest < diff_bilinear (ROOM-1 claim 11:
#      sampling=nearest), diff_nearest <= 2, blend-colour share <= 1%.
#      Terrain and sprite are both inside the measured region, so dropping
#      nearest from either path fails here.
#   B. CONTROL WORLD. The default is still linear: diff_bilinear <
#      diff_nearest and >= 30% blend colours. Also proves the fixture CAN
#      tell the filters apart.
#   D. DARWIN DEFAULT. A and B again at --supersample-rnsvg 4 (the whole tree
#      through the 4x offscreen, as darwin runs by default).
#
# NO-NPM MODE: renders the committed prebuilt bundle with the staged binary.
# The Mac runs: RNI_BIN=<darwin rn-impeller> bash tools/ci-world-nearest.sh
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { echo "WORLD_NEAREST_GATE_FAIL: $*" >&2; exit 1; }

ENGINE="${RNI_BIN:-$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller}"
[ -x "$ENGINE" ] || fail "no engine binary at $ENGINE (set RNI_BIN)"
FIX="$ROOT/fixtures/eng21-world-nearest"
BUNDLE="${RNI_TEST_BUNDLE:-$FIX/prebuilt/eng21-world-nearest.bundle}"
if [ "${BUILD_BUNDLE:-0}" = "1" ] && [ -z "${RNI_TEST_BUNDLE:-}" ]; then
  bash "$ROOT/tools/build-fixture-bundle.sh" eng21-world-nearest Eng21Nearest \
    || fail "could not rebuild the bundle"
fi
[ -s "$BUNDLE" ] || fail "no bundle at $BUNDLE"

WORK="$(mktemp -d)"
KEEP="${KEEP_WORKDIR:-0}"
cleanup() { rni_kill_own; [ "$KEEP" = "1" ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

py() { python3 -c "import sys; sys.exit(0 if ($1) else 1)"; }

render() {  # $1 supersample N -> $WORK/n$1.{ppm,log,diff}
  local n="$1" rc
  set +e
  "$ENGINE" --bundle "$BUNDLE" --app-name Eng21Nearest --probe-banner off \
    --width 320 --height 240 --supersample-rnsvg "$n" --headless \
    --screenshot "$WORK/n$n.ppm" > "$WORK/n$n.log" 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { tail -20 "$WORK/n$n.log" >&2; fail "headless render (N=$n) exited $rc"; }
  local nodes
  nodes="$(sed -n 's/^rn-impeller: scene_nodes=\([0-9]*\)$/\1/p' "$WORK/n$n.log" | tail -1)"
  [ -n "$nodes" ] && [ "$nodes" -gt 0 ] || fail "scene_nodes=${nodes:-none} at N=$n: fixture did not mount"
  grep -q "^rn-impeller: supersample_rnsvg=$n\$" "$WORK/n$n.log" \
    || fail "engine did not report supersample_rnsvg=$n (flag dropped; darwin defaults to 4)"
  python3 tools/world-nearest-diff.py "$WORK/n$n.ppm" 320 240 near:0:0 lin:0:120 > "$WORK/n$n.diff"
  sed "s/^/   N=$n /" "$WORK/n$n.diff"
}
val() { sed -n "s/^$2 .*$3=\([0-9.]*\).*/\1/p" "$WORK/n$1.diff"; }

check_worlds() {  # $1 N  $2 arm label for A  $3 arm label for B
  local n="$1" a="$2" b="$3"
  local NDN NDB NOFF LDN LDB LOFF
  NDN="$(val "$n" near diff_nearest)"; NDB="$(val "$n" near diff_bilinear)"; NOFF="$(val "$n" near offpalette)"
  LDN="$(val "$n" lin diff_nearest)";  LDB="$(val "$n" lin diff_bilinear)";  LOFF="$(val "$n" lin offpalette)"
  py "$NDN < $NDB" \
    || fail "$a: nearest world reads sampling=linear (diff nearest $NDN >= bilinear $NDB): setSampling('nearest') did not reach the draw"
  py "$NDN <= 2.0" || fail "$a: nearest world is $NDN from the CPU nearest composite (want <= 2)"
  py "$NOFF <= 0.01" \
    || fail "$a: nearest world has $NOFF of its pixels in blend colours (want <= 0.01): terrain or sprite still filters linearly"
  echo "   OK $a: nearest world diff nearest=$NDN bilinear=$NDB blend share=$NOFF"
  py "$LDB < $LDN" \
    || fail "$b: control world reads sampling=nearest (diff bilinear $LDB >= nearest $LDN): the default is no longer linear"
  py "$LOFF >= 0.30" \
    || fail "$b: control world has only $LOFF blend colours (want >= 0.30): the fixture cannot tell linear from nearest"
  echo "   OK $b: control world diff bilinear=$LDB nearest=$LDN blend share=$LOFF"
}

echo "== render at --supersample-rnsvg 0 =="
render 0
echo "== C. contract =="
grep -q 'ENG21_NO_SETSAMPLING' "$WORK/n0.log" \
  && fail "C: WorldRaster.setSampling is missing from this engine (JS saw no method)"
grep -q 'ENG21_THROW_OK bad-mode' "$WORK/n0.log" \
  || fail "C: setSampling(id, 'nearst') did not throw: a typo would silently fall back"
grep -q 'ENG21_READY' "$WORK/n0.log" || fail "C: fixture never reached ENG21_READY"
grep -q '^rn-impeller: world_sprites_drawn=2$' "$WORK/n0.log" \
  || fail "C: world_sprites_drawn is not 2: a world did not draw its sprite"
echo "   OK C: setSampling present, bad mode throws, 2 sprites drawn"

echo "== A/B. nearest world vs control (N=0) =="
check_worlds 0 A B

echo "== D. same at --supersample-rnsvg 4 (darwin default) =="
render 4
check_worlds 4 D-A D-B

echo "WORLD_NEAREST_GATE_PASS (setSampling 'nearest' keeps terrain and sprite texels hard; default stays linear)"
