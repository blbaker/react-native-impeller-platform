#!/usr/bin/env bash
# FP-23 gate: headless darwin on native Metal (`--headless --backend metal`): an offscreen BGRA8
# MTLTexture wrapped by SDK patch 0005 (ImpellerSurfaceCreateWrappedMetalTextureNew) and read back
# with ImpellerSurfaceReadPixels. Run it on a Mac with RNI_BIN set to the staged darwin binary.
# Every Metal run has MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1. Arms (each failure prints
# `METAL_HEADLESS FAIL <arm>: ...`; all arms run):
#   R  read-back: backend_select metal window=0, metal_offscreen ok=1 bgra8, gpu_backend context=metal
#      uploader=contents supersample=none, metal_readback layout=bgra8; headless default stays gles
#   CAPTURE  every capture exists and is not blank
#   P  core fixtures: headless Metal == windowed Metal capture per pixel (same px size and scale):
#      mean <= 0.5 and <= 0.5% of px off by > 24
#   C  channel order: the eng10 sprites' coloured pixels have the same dominant channel as windowed
#   SYNC  the FIRST frame read back (frame 1, right after the first draw) equals the last one on a
#      static fixture: a readback that does not wait for the GPU returns an empty buffer there
#   V  zero Metal validation errors (and the validation layer really was on)
# linux: `--headless --backend metal` is refused (exit 2 "darwin-only") and headless stays gles.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/host-window.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
WORK="$(mktemp -d)"
trap 'rni_kill_own; [ "${KEEP_WORKDIR:-0}" = 1 ] && echo "workdir kept: $WORK" || rm -rf "$WORK"' EXIT
FAILS=()
bad() { echo "METAL_HEADLESS FAIL $1: $2"; FAILS+=("$1"); }
FX="$ROOT/fixtures"
MC() { python3 "$ROOT/tools/metal_check.py" "$@"; }
kv() { sed -nE "s/.*[ ]$2=([0-9.]+).*/\1/p" <<< "$1" | head -1; }
within() { python3 -c "import sys; sys.exit(0 if float(sys.argv[1])<=float(sys.argv[3]) and float(sys.argv[2])<=float(sys.argv[4]) else 1)" "$@" 2>/dev/null; }
BU="$FX/eng-supersample/prebuilt/eng-supersample.bundle"

if [ "$(rni_host)" = linux ]; then
  BIN="${RNI_BIN:-$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller}"
  [ -x "$BIN" ] || { echo "METAL_HEADLESS FAIL: no engine at $BIN"; exit 1; }
  rc=0
  timeout 120 "$BIN" --headless --bundle "$BU" --app-name EngSupersample --probe-banner off --frames 2 \
    --backend metal > "$WORK/refuse.log" 2>&1 || rc=$?
  [ "$rc" = 2 ] && grep -q 'backend metal is darwin-only' "$WORK/refuse.log" \
    || bad R "linux --headless --backend metal not refused (rc=$rc: $(tail -1 "$WORK/refuse.log"))"
  timeout 120 "$BIN" --headless --bundle "$BU" --app-name EngSupersample --probe-banner off --frames 2 \
    --supersample-rnsvg 0 > "$WORK/default.log" 2>&1 || bad R "linux default headless run failed"
  grep -q 'backend_select backend=gles given=0 window=0' "$WORK/default.log" \
    || bad R "linux headless default is not gles: $(grep -m1 backend_select "$WORK/default.log")"
  [ "${#FAILS[@]}" = 0 ] || { echo "METAL_HEADLESS FAIL (${FAILS[*]})"; exit 1; }
  echo "METAL_HEADLESS PASS linux (metal refused off darwin, headless default gles; the Metal arms run on darwin)"
  exit 0
fi

BIN="${RNI_BIN:-$ROOT/packages-engine/engine-darwin-arm64/bin/rn-impeller}"
[ -x "$BIN" ] || { echo "METAL_HEADLESS FAIL: no engine at $BIN (set RNI_BIN)"; exit 1; }
export MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1
METAL_LOGS=()

run() {  # name mode(window|headless) -- engine args...
  local name="$1" mode="$2"; shift 3
  ( cd "$(dirname "$BIN")" && timeout 180 "$BIN" --"$mode" --probe-banner off --backend metal \
      --supersample-rnsvg 0 "$@" ) > "$WORK/$name.log" 2>&1
  local rc=$?
  [ "$rc" = 0 ] || bad CAPTURE "$name exited $rc: $(grep -m1 -iE 'fatal|assert' "$WORK/$name.log" || tail -1 "$WORK/$name.log")"
  grep -q 'backend_select backend=metal' "$WORK/$name.log" && METAL_LOGS+=("$WORK/$name.log")
  return 0
}
shot() {  # name -> the capture must exist and carry ink
  local p="$WORK/$1.ppm" b
  [ -s "$p" ] || { bad CAPTURE "$1: no capture ($(grep -m1 -iE 'readback|cannot write' "$WORK/$1.log" || echo 'no readback line'))"; return 1; }
  b="$(MC blank "$p")"
  [ "$(kv "$b" ink)" -ge 500 ] && [ "$(kv "$b" distinct)" -ge 2 ] || { bad CAPTURE "$1: blank capture ($b)"; return 1; }
}

echo "== R: read-back =="
( cd "$(dirname "$BIN")" && timeout 180 "$BIN" --headless --bundle "$BU" --app-name EngSupersample \
    --probe-banner off --frames 2 --supersample-rnsvg 4 ) > "$WORK/hdefault.log" 2>&1 || bad R "headless default run failed"
grep -q 'backend_select backend=gles given=0 window=0' "$WORK/hdefault.log" \
  || bad R "darwin headless default is not gles: $(grep -m1 backend_select "$WORK/hdefault.log")"
# The windowed reference fixes the pixel scale S; headless renders the same px size at --scale S.
run probe window -- --bundle "$BU" --app-name EngSupersample --width 400 --height 300 --frames 90 \
  --screenshot-after 800 --screenshot "$WORK/probe.ppm"
S="$(sed -nE 's/.*window px=[0-9x]+ points=[0-9.x]+ scale=([0-9.]+).*/\1/p' "$WORK/probe.log" | head -1)"
S="${S%%.*}"; S="${S:-1}"
W=$((400 * S)) H=$((300 * S))
echo "   window scale=$S -> headless ${W}x${H} px at --scale $S"
HARGS=(--width "$W" --height "$H" --scale "$S" --frames 90)
run h-probe headless -- --bundle "$BU" --app-name EngSupersample "${HARGS[@]}" --screenshot "$WORK/h-probe.ppm"
L="$WORK/h-probe.log"
grep -q 'backend_select backend=metal given=1 window=0' "$L" || bad R "$(grep -m1 backend_select "$L" || echo 'no backend_select')"
grep -q "metal_offscreen ok=1 texture=${W}x${H} pixel_format=bgra8" "$L" || bad R "$(grep -m1 metal_offscreen "$L" || echo 'no metal_offscreen line')"
grep -q '^rn-impeller: gpu_backend context=metal policy=metal uploader=contents supersample=none$' "$L" \
  || bad R "$(grep -m1 gpu_backend "$L" || echo 'no gpu_backend line')"
grep -q 'metal_readback layout=bgra8' "$L" || bad R "$(grep -m1 metal_readback "$L" || echo 'no metal_readback line')"
grep -q 'GL_RENDERER\|ANGLE backend' "$L" && bad R "headless Metal run touched EGL/ANGLE: $(grep -m1 'GL_RENDERER\|ANGLE backend' "$L")"
shot h-probe && echo "   $(grep -m1 metal_offscreen "$L" | cut -c14-)"

echo "== P: headless Metal vs windowed Metal, 400x300 points =="
FIXTURES="eng-supersample:EngSupersample eng05-aa:Eng05AA fp22-sdf-aa:Fp22SdfAa eng13-svg-dash:Eng13SvgDash
eng22-font-family:Eng22FontFamily eng23-line-height:Eng23LineHeight eng10-world-sprites:Eng10Sprites"
for f in $FIXTURES; do
  fx="${f%%:*}" app="${f#*:}" b="$FX/${f%%:*}/prebuilt/${f%%:*}.bundle"
  run "$fx-win" window -- --bundle "$b" --app-name "$app" --width 400 --height 300 --frames 90 \
    --screenshot-after 800 --screenshot "$WORK/$fx-win.ppm"
  run "$fx-hl" headless -- --bundle "$b" --app-name "$app" "${HARGS[@]}" --screenshot "$WORK/$fx-hl.ppm"
  shot "$fx-win" && shot "$fx-hl" || continue
  d="$(MC diff "$WORK/$fx-hl.ppm" "$WORK/$fx-win.ppm")"
  echo "   $fx: $d"
  [[ "$d" == *"size=${W}x${H} "* ]] || { bad P "$fx size: $d"; continue; }
  within "$(kv "$d" mean)" "$(kv "$d" over24_pct)" 0.5 0.5 || bad P "$fx headless Metal != windowed Metal: $d"
done

echo "== C: channel order on the sprites =="
if [ -s "$WORK/eng10-world-sprites-hl.ppm" ] && [ -s "$WORK/eng10-world-sprites-win.ppm" ]; then
  c="$(python3 - "$WORK/eng10-world-sprites-hl.ppm" "$WORK/eng10-world-sprites-win.ppm" "$ROOT/tools" <<'PY'
import sys
sys.path.insert(0, sys.argv[3])
from metal_check import read
wa, ha, a = read(sys.argv[1]); wb, hb, b = read(sys.argv[2])
same = flip = 0
for i in range(0, min(len(a), len(b)) - 2, 3):
    pb = b[i:i + 3]
    if max(pb) - min(pb) < 60: continue  # only clearly coloured px
    da = max(range(3), key=lambda k: a[i + k]); db = max(range(3), key=lambda k: pb[k])
    if da == db: same += 1
    elif {da, db} == {0, 2}: flip += 1
print(f"coloured={same + flip} same={same} rb_swapped={flip}")
PY
)"
  echo "   $c"
  [ "$(kv " $c" coloured)" -ge 1000 ] && [ "$(kv " $c" rb_swapped)" -le "$(( $(kv " $c" coloured) / 100 ))" ] \
    || bad C "red/blue swapped vs windowed Metal: $c"
else
  bad C "missing sprite captures"
fi

echo "== SYNC: first readback == last (static fixture) =="
run sync headless -- --bundle "$FX/eng05-aa/prebuilt/eng05-aa.bundle" --app-name Eng05AA --width "$W" --height "$H" --scale "$S" --frames 3 \
  --screenshot-first "$WORK/sync-first.ppm" --screenshot "$WORK/sync.ppm"
shot sync  # SYNC judges frame 1 even when the last capture is blank too
if [ ! -s "$WORK/sync-first.ppm" ] || [ ! -s "$WORK/sync.ppm" ]; then
  bad SYNC "missing frame-1 or last capture"
else
  d="$(MC diff "$WORK/sync-first.ppm" "$WORK/sync.ppm")"; bl="$(MC blank "$WORK/sync-first.ppm")"
  echo "   frame1 vs last: $d; frame1 $bl"
  { [ "$(kv "$bl" ink)" -ge 500 ] && within "$(kv "$d" mean)" "$(kv "$d" over24_pct)" 0.01 0.01; } \
    || bad SYNC "frame-1 readback raced the GPU (blank or != the settled frame): $d; $bl"
fi

echo "== V: Metal validation (MTL_DEBUG_LAYER + MTL_SHADER_VALIDATION) =="
[ "${#METAL_LOGS[@]}" -ge 15 ] || bad V "only ${#METAL_LOGS[@]} Metal runs to check"
verr=0
for l in "${METAL_LOGS[@]}"; do
  grep -q 'Metal API Validation Enabled' "$l" || { bad V "$(basename "$l"): validation layer was not on"; continue; }
  if grep -qiE 'failed assertion|validation error|MTLDebug|command buffer was aborted|shader validation.*(error|fault)' "$l"; then
    verr=$((verr + 1)); bad V "$(basename "$l"): $(grep -m1 -iE 'failed assertion|validation error|MTLDebug|aborted|shader validation' "$l" | cut -c1-200)"
  fi
done
echo "   metal_runs=${#METAL_LOGS[@]} validation_errors=$verr"

[ "${#FAILS[@]}" = 0 ] || { echo "METAL_HEADLESS FAIL (arms: ${FAILS[*]})"; exit 1; }
echo "METAL_HEADLESS PASS darwin (R CAPTURE P C SYNC V; metal runs ${#METAL_LOGS[@]}, validation errors 0)"
