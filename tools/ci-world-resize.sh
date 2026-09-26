#!/usr/bin/env bash
# ENG-10 RESIZE gate -- does <world> survive its buffer changing SIZE while the
# app is running (a zoom), on the WINDOWED GPU present?
#
# ⛔ WHY THIS GATE EXISTS
# ci-world-raster.sh and ci-world-sprites.sh each call setPixels ONCE, at ONE
# size. paintWorldNode's sizeChanged branch therefore only ever ran on the first
# upload (glTex == 0). The reallocate-and-re-adopt half -- the branch every zoom
# takes -- was never executed by any gate. It was broken: the adopt call hands
# the GL name to Impeller, which deletes it on release, and the resize path
# re-uploaded into that name, released (deleting it), then re-adopted the dead
# name. Terrain presented BLACK while world_sprites_drawn and scene_nodes both
# reported success. Measured on linux before the fix: 35296 bad pixels.
#
# ONE RUN, TWO SIZES. fixtures/eng10-world-sprites/resize-index.js publishes a
# 160x120 terrain + the ENG-10 sprite list (with the 'bubble' atlas entry at a
# wrong 8x8), then a synthetic tap swaps in the 320x240 terrain from scene.js
# AND re-registers 'bubble' at its native 16x16 -- so BOTH texture caches
# (paintWorldNode's terrain and paintWorldSprites' atlas) take their
# reallocate branch. The oracle is reference-index.js (the whole
# scene composited on the CPU, one setPixels at 320x240) -- the same oracle
# ci-world-sprites.sh ARM B uses.
#
# Mutation-verified by tools/mutation-verify-world-resize.sh (both caches).
#
# ARMS (all required):
#   PRE   size A really painted: frame 1 shows the A terrain grey at a
#         sprite-free pixel. Without this, a fixture that published B first
#         would pass while never taking the reallocate branch.
#   ORDER the size-B setPixels ran BEFORE the timed capture. Otherwise a slow
#         host captures size A and the gate grades the wrong frame.
#   COUNT world_sprites_drawn == the fixture's list length.
#   PIXEL per-pixel match of the post-resize frame vs the oracle (BAD_PIXELS=0
#         at tol 6). A black/stale terrain fails here.
#
# NO-NPM MODE (Mac): renders the committed prebuilt bundles with the staged
# engine. RNI_BIN overrides the engine; tools/build-world-resize-bundles.sh
# regenerates the bundles after a fixture edit.
#
# Pins --supersample-rnsvg 0 and --scale 1 in every run (asserted from the log):
# darwin defaults N=4 and Retina scale 2, both of which linear-resample the one
# oracle texture and the 145 sprite textures DIFFERENTLY and fail ARM PIXEL on
# a correct engine. See ci-world-sprites.sh's header for the measured case.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
case "$(uname -s)" in
  Darwin) DEFAULT_BIN="$ROOT/packages-engine/engine-darwin-arm64/bin/rn-impeller" ;;
  *) DEFAULT_BIN="$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller" ;;
esac
ENGINE="${RNI_BIN:-$DEFAULT_BIN}"
PRE="$ROOT/fixtures/eng10-world-sprites/prebuilt"
RESIZE_BUNDLE="${RNI_RESIZE_BUNDLE:-$PRE/eng10-resize.bundle}"
REF_BUNDLE="${RNI_REF_BUNDLE:-$PRE/eng10-reference.bundle}"
W=320
H=240
SUPERSAMPLE=0
# Sprite-free terrain pixel (sprites start at x=16,y=12) and size-A grey.
PROBE_X=2
PROBE_Y=2
A_GREY=200

fail() { echo "WORLD_RESIZE_GATE_FAIL: $*" >&2; exit 1; }

[ -x "$ENGINE" ] || fail "no engine binary at $ENGINE (set RNI_BIN)"
[ -s "$RESIZE_BUNDLE" ] || fail "missing $RESIZE_BUNDLE (tools/build-world-resize-bundles.sh)"
[ -s "$REF_BUNDLE" ] || fail "missing $REF_BUNDLE (tools/build-world-resize-bundles.sh)"
command -v python3 >/dev/null || fail "python3 not found"
if [ "$(uname -s)" != Darwin ]; then
  unset SDL_VIDEODRIVER || true
  export DISPLAY="${DISPLAY:-:0}"
fi

WORK="$(mktemp -d)"
KEEP="${KEEP_WORKDIR:-0}"
cleanup() {
  rni_kill_own
  [ "$KEEP" = "1" ] && echo "workdir kept: $WORK" || rm -rf "$WORK"
}
trap cleanup EXIT

run_window() {
  local bundle="$1" appname="$2" log="$3"; shift 3
  "$ENGINE" --window --probe-banner off --bundle "$bundle" --app-name "$appname" \
    --width "$W" --height "$H" --scale 1 --supersample-rnsvg "$SUPERSAMPLE" \
    --frames 600 "$@" > "$log" 2>&1 &
  local pid=$!
  rni_track "$pid"
  wait "$pid"
  local rc=$?
  [ "$rc" -eq 0 ] || { tail -30 "$log" | sed 's/^/   /' >&2; fail "windowed run of $appname exited $rc"; }
}

echo "== 1. windowed run: size A (160x120) -> tap -> size B (320x240) =="
RS_LOG="$WORK/resize.log"; FIRST="$WORK/first.ppm"; LATE="$WORK/late.ppm"
# Tap at SCREEN 80,60. With --scale 1 pinned, a 2x (Retina) framebuffer maps
# screen->layout by x2, so this lands at layout 160,120 there and 80,60 on a 1x
# display -- inside the 320x240 tap target either way. 160,120 would land on
# the target's far edge (320,240) on Retina and could miss.
run_window "$RESIZE_BUNDLE" Eng10Resize "$RS_LOG" \
  --click-after-frames 5:80,60 \
  --screenshot-first "$FIRST" --screenshot-after 400 --screenshot "$LATE"
[ -s "$FIRST" ] || fail "no frame-1 capture"
[ -s "$LATE" ] || fail "no post-resize capture"

echo "== 2. windowed run: CPU-composite oracle at size B =="
REF_LOG="$WORK/ref.log"; REF="$WORK/ref.ppm"
run_window "$REF_BUNDLE" Eng10SpritesReference "$REF_LOG" \
  --screenshot-after 400 --screenshot "$REF"
[ -s "$REF" ] || fail "no oracle capture"
grep -q 'ENG10_REFERENCE composited' "$REF_LOG" || fail "oracle fixture never composited"

if [ -n "${SHOT_OUT:-}" ]; then
  mkdir -p "$SHOT_OUT"; cp "$FIRST" "$LATE" "$REF" "$SHOT_OUT/"
fi

num_field() { sed -n "s/^rn-impeller: $1=\([0-9]*\)$/\1/p" "$2" | head -1; }

echo "== 3. pins honoured (supersample 0, scale 1 override) =="
for lg in "$RS_LOG" "$REF_LOG"; do
  ss="$(num_field supersample_rnsvg "$lg")"
  [ "$ss" = "$SUPERSAMPLE" ] || fail "supersample_rnsvg='$ss' in $(basename "$lg"), gate pinned $SUPERSAMPLE"
  grep -q 'scale=1.00 (--scale override)' "$lg" || fail "$(basename "$lg") did not run at the pinned --scale 1: $(grep 'window px=' "$lg")"
done
echo "   OK"

echo "== 4. ARM PRE -- frame 1 painted the size-A terrain =="
grep -q 'ENG10_RESIZE size=A w=160 h=120' "$RS_LOG" || fail "fixture never published size A"
PRE_PX="$(python3 - "$FIRST" "$PROBE_X" "$PROBE_Y" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
p = d.split(maxsplit=4)
w = int(p[1]); px = p[4]
x, y = int(sys.argv[2]), int(sys.argv[3])
o = (y * w + x) * 3
print(px[o], px[o + 1], px[o + 2])
PY
)"
echo "   frame-1 pixel ($PROBE_X,$PROBE_Y) = $PRE_PX (want ~$A_GREY)"
for c in $PRE_PX; do
  case "$c" in ''|*[!0-9]*) fail "non-numeric probe pixel '$PRE_PX'";; esac
  d=$(( c > A_GREY ? c - A_GREY : A_GREY - c ))
  [ "$d" -le 6 ] || fail "frame 1 is not the size-A terrain at ($PROBE_X,$PROBE_Y): $PRE_PX. The run never presented size A, so the resize branch was not exercised."
done

echo "== 5. ARM ORDER -- size-B setPixels ran before the timed capture =="
b_line="$(grep -n 'ENG10_RESIZE size=B w=320 h=240' "$RS_LOG" | head -1 | cut -d: -f1)"
s_line="$(grep -n '^rn-impeller: screenshot=' "$RS_LOG" | head -1 | cut -d: -f1)"
[ -n "$b_line" ] || fail "the tap never swapped in size B (touch: $(grep -o 'touch_down hit=[0-9]*' "$RS_LOG" || echo none))"
[ -n "$s_line" ] || fail "no screenshot= line in resize log"
[ "$b_line" -lt "$s_line" ] || fail "timed capture (log line $s_line) happened BEFORE the size-B swap (line $b_line) -- grading the wrong frame"
echo "   OK: size B at log line $b_line, capture at line $s_line"

echo "== 6. ARM COUNT -- every sprite issued =="
drawn="$(num_field world_sprites_drawn "$RS_LOG")"
want="$(sed -n 's/.*ENG10_RESIZE size=A .* sprites=\([0-9]*\).*/\1/p' "$RS_LOG" | head -1)"
case "$drawn" in ''|*[!0-9]*) fail "no numeric world_sprites_drawn (got '$drawn')";; esac
case "$want" in ''|*[!0-9]*) fail "fixture never logged its sprite count";; esac
[ "$drawn" -eq "$want" ] || fail "world_sprites_drawn=$drawn != list length $want"
echo "   OK: $drawn/$want"

echo "== 7. ARM PIXEL -- post-resize frame matches the CPU oracle per pixel =="
PIX_TOL=6
DIFF_OUT="$(python3 "$ROOT/tools/sprite-composite-diff.py" "$LATE" "$REF" --pix-tol=$PIX_TOL)" \
  || fail "sprite-composite-diff.py failed: $DIFF_OUT"
echo "$DIFF_OUT" | sed 's/^/   /'
get_field() { echo "$DIFF_OUT" | sed -n "s/^$1 //p"; }
case "$DIFF_OUT" in *DIMENSION_MISMATCH*) fail "dimension mismatch: $DIFF_OUT";; esac
BAD="$(get_field BAD_PIXELS)"; MAXD="$(get_field MAX_CHANNEL_DIFF)"
DA="$(get_field DISTINCT_LUMA_A)"; DB="$(get_field DISTINCT_LUMA_B)"
case "$BAD" in ''|*[!0-9]*) fail "no numeric BAD_PIXELS (got '$BAD')";; esac
[ "$BAD" -eq 0 ] || fail \
  "$BAD pixels differ from the oracle by > $PIX_TOL after the resize (max $MAXD at $(get_field WORST_AT)). A black terrain is the adopted-name-deleted bug; a grey one is a stale size-A texture."
[ "$DA" -ge 40 ] && [ "$DB" -ge 40 ] || fail "degenerate render: distinct luma A=$DA B=$DB (want >= 40)"
echo "   OK: 0 pixels over tolerance $PIX_TOL (max channel diff $MAXD)"

echo "WORLD_RESIZE_GATE_PASS (A=160x120 -> B=${W}x${H} sprites=$drawn/$want max_channel_diff=$MAXD)"
