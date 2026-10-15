#!/usr/bin/env bash
# FP-21 gate: darwin native Metal windowed backend (CAMetalLayer + ImpellerContextCreateMetalNew).
# Run it on the Mac through `bash tools/parity-mac.sh gate tools/ci-metal.sh` (RNI_BIN = staged darwin bin).
# Every Metal run has MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1. Arms (each failure prints
# `METAL_GATE FAIL <arm>: ...`; all arms run, so a mutant's own arm is always visible):
#   R  read-back: default darwin window = metal, gpu_backend context=metal uploader=contents
#      supersample=none, supersample_rnsvg=0, layer bgra8 / framebuffer_only=0 / contents_scale=backing
#   CAPTURE  every capture exists and is not blank (captures read the drawable BEFORE present)
#   P  fixture parity: 7 fixtures, Metal N=0 vs ANGLE N=4, mean <= 1.0 and <= 2% of px off by > 24
#   AA icon-edge metric on the eng-supersample chevron vs an ANGLE N=16 reference: Metal N=0 must
#      carry real AA (>= 15% partial edge px, >= 3 levels, error <= 0.9 x ANGLE N=0's)
#   S  style-audit grid (windowed Metal, 1200x2100 at --scale 1): every LANDED + KEEP tile PASS
#   F  tools/ci-first-present.sh green on the default (Metal) backend
#   Z  resize inside a main-thread stall repaints (painted_during >= 1) at the new 2x size, == ANGLE
#   V  zero Metal validation errors (and the validation layer really was on)
# linux: Metal is refused (exit 2) and the default stays gles.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/host-window.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
WORK="$(mktemp -d)"
trap 'rni_kill_own; [ "${KEEP_WORKDIR:-0}" = 1 ] && echo "workdir kept: $WORK" || rm -rf "$WORK"' EXIT
FAILS=()
bad() { echo "METAL_GATE FAIL $1: $2"; FAILS+=("$1"); }
FX="$ROOT/fixtures"
MC() { python3 "$ROOT/tools/metal_check.py" "$@"; }
kv() { sed -nE "s/.*[ ]$2=([0-9.]+).*/\1/p" <<< "$1" | head -1; }

if [ "$(rni_host)" = linux ]; then
  BIN="${RNI_BIN:-$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller}"
  [ -x "$BIN" ] || { echo "METAL_GATE FAIL: no engine at $BIN"; exit 1; }
  BU="$FX/eng-supersample/prebuilt/eng-supersample.bundle"
  for mode in --headless --window; do
    rc=0
    rni_xrun "$WORK/xauth" timeout 120 "$BIN" $mode --bundle "$BU" --app-name EngSupersample --probe-banner off \
      --frames 3 --backend metal > "$WORK/refuse$mode.log" 2>&1 || rc=$?
    [ "$rc" = 2 ] && grep -q 'backend metal is darwin-only' "$WORK/refuse$mode.log" \
      || bad R "linux $mode --backend metal not refused (rc=$rc: $(tail -1 "$WORK/refuse$mode.log"))"
  done
  rni_xrun "$WORK/xauth" timeout 120 "$BIN" --window --bundle "$BU" --app-name EngSupersample --probe-banner off \
    --frames 3 > "$WORK/default.log" 2>&1 || bad R "linux default windowed run failed"
  grep -q 'backend_select backend=gles given=0 window=1' "$WORK/default.log" \
    || bad R "linux default is not gles: $(grep -m1 backend_select "$WORK/default.log")"
  [ "${#FAILS[@]}" = 0 ] || { echo "METAL_GATE FAIL (${FAILS[*]})"; exit 1; }
  echo "METAL_GATE PASS linux (metal refused off darwin, windowed default gles; the Metal arms run on darwin)"
  exit 0
fi

BIN="${RNI_BIN:-$ROOT/packages-engine/engine-darwin-arm64/bin/rn-impeller}"
[ -x "$BIN" ] || { echo "METAL_GATE FAIL: no engine at $BIN (set RNI_BIN)"; exit 1; }
export MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1
METAL_LOGS=()

run() {  # name backend|default ss|default -- engine args...
  local name="$1" be="$2" ss="$3"; shift 4
  local extra=()
  [ "$be" = default ] || extra+=(--backend "$be")
  [ "$ss" = default ] || extra+=(--supersample-rnsvg "$ss")
  ( cd "$(dirname "$BIN")" && timeout 180 "$BIN" --window --probe-banner off "${extra[@]}" "$@" ) \
    > "$WORK/$name.log" 2>&1
  local rc=$?
  [ "$rc" = 0 ] || bad CAPTURE "$name exited $rc: $(grep -m1 -iE 'fatal|assert' "$WORK/$name.log" || tail -1 "$WORK/$name.log")"
  grep -q 'backend_select backend=metal' "$WORK/$name.log" && METAL_LOGS+=("$WORK/$name.log")
  return 0
}
shot() {  # name -> the capture must exist and carry ink
  local p="$WORK/$1.ppm" b
  [ -s "$p" ] || { bad CAPTURE "$1: no capture ($(grep -m1 'readback failed' "$WORK/$1.log" || echo 'no readback line'))"; return 1; }
  b="$(MC blank "$p")"
  [ "$(kv "$b" ink)" -ge 500 ] && [ "$(kv "$b" distinct)" -ge 2 ] || { bad CAPTURE "$1: blank capture ($b)"; return 1; }
}

echo "== R: read-back (default darwin window, no --backend / --supersample-rnsvg) =="
BU="$FX/eng-supersample/prebuilt/eng-supersample.bundle"
run default default default -- --bundle "$BU" --app-name EngSupersample --width 300 --height 300 \
  --frames 90 --screenshot-after 800 --screenshot "$WORK/default.ppm"
L="$WORK/default.log"
grep -q 'backend_select backend=metal given=0 window=1' "$L" || bad R "default is not metal: $(grep -m1 backend_select "$L")"
grep -q '^rn-impeller: gpu_backend context=metal policy=metal uploader=contents supersample=none$' "$L" \
  || bad R "$(grep -m1 gpu_backend "$L" || echo 'no gpu_backend line')"
grep -q 'supersample_rnsvg=0$' "$L" || bad R "metal default supersample: $(grep -m1 supersample_rnsvg "$L")"
lay="$(grep -m1 'metal_layer' "$L")"; sc="$(grep -m1 'layer contents_scale' "$L")"
[[ "$lay" == *"pixel_format=bgra8 framebuffer_only=0"* ]] || bad R "layer: ${lay:-no metal_layer line}"
[ -n "$sc" ] && [ "$(kv "$sc" contents_scale)" = "$(kv "$sc" backing_scale)" ] || bad R "contents_scale != backing: $sc"
grep -q 'metal_context ok=1' "$L" || bad R "no metal_context ok=1"
grep -q 'metal_capture_queue shared=1' "$L" || bad R "capture blit is not on Impeller's queue (unordered readback)"
grep -q 'gpu_release gl_current=0 backend=metal' "$L" || bad R "Metal GPU not released on exit"
shot default && echo "   $(grep -m1 metal_layer "$L" | cut -c14-) $(grep -m1 metal_present "$L" | cut -c14-)"

echo "== P: Metal N=0 vs ANGLE N=4, windowed 400x300 points =="
FIXTURES="eng-supersample:EngSupersample eng05-aa:Eng05AA fp22-sdf-aa:Fp22SdfAa eng13-svg-dash:Eng13SvgDash
eng22-font-family:Eng22FontFamily eng23-line-height:Eng23LineHeight eng10-world-sprites:Eng10Sprites"
for f in $FIXTURES; do
  fx="${f%%:*}" app="${f#*:}"
  for arm in metal:0 gles:4; do
    run "$fx-${arm%%:*}" "${arm%%:*}" "${arm#*:}" -- --bundle "$FX/$fx/prebuilt/$fx.bundle" --app-name "$app" \
      --width 400 --height 300 --frames 90 --screenshot-after 800 --screenshot "$WORK/$fx-${arm%%:*}.ppm"
  done
  shot "$fx-metal" && shot "$fx-gles" || continue
  d="$(MC diff "$WORK/$fx-metal.ppm" "$WORK/$fx-gles.ppm")"
  echo "   $fx: $d"
  python3 -c "import sys; m,p=float(sys.argv[1]),float(sys.argv[2]); sys.exit(0 if m<=1.0 and p<=2.0 else 1)" \
    "$(kv "$d" mean)" "$(kv "$d" over24_pct)" 2>/dev/null || bad P "$fx Metal vs ANGLE N=4 out of tolerance: $d"
done

echo "== AA: chevron edge vs ANGLE N=16 =="
for arm in gles:0 gles:16; do
  run "aa-${arm/:/}" "${arm%%:*}" "${arm#*:}" -- --bundle "$BU" --app-name EngSupersample --width 400 --height 300 \
    --frames 90 --screenshot-after 800 --screenshot "$WORK/aa-${arm/:/}.ppm"
done
S="$(sed -nE 's/.*window px=[0-9x]+ points=[0-9.x]+ scale=([0-9.]+).*/\1/p' "$WORK/eng-supersample-metal.log" | head -1)"
S="${S%%.*}"; S="${S:-1}"
if [ -s "$WORK/aa-gles16.ppm" ] && [ -s "$WORK/aa-gles0.ppm" ] && [ -s "$WORK/eng-supersample-metal.ppm" ]; then
  box=($((20 * S)) $((20 * S)) $((240 * S)) $((240 * S)))
  met="$(MC aa "$WORK/eng-supersample-metal.ppm" "$WORK/aa-gles16.ppm" "${box[@]}")"
  g0="$(MC aa "$WORK/aa-gles0.ppm" "$WORK/aa-gles16.ppm" "${box[@]}")"
  g4="$(MC aa "$WORK/eng-supersample-gles.ppm" "$WORK/aa-gles16.ppm" "${box[@]}")"
  echo "   metal N=0: $met"; echo "   ANGLE N=0: $g0"; echo "   ANGLE N=4: $g4"
  python3 - "$met" "$g0" <<'PY' || bad AA "Metal N=0 edge is not anti-aliased: metal [$met] vs ANGLE N=0 [$g0]"
import re, sys
m = dict(re.findall(r"(\w+)=([0-9.]+)", sys.argv[1])); g = dict(re.findall(r"(\w+)=([0-9.]+)", sys.argv[2]))
ok = float(m["partial_pct"]) >= 15 and int(m["levels"]) >= 3 and float(m["err"]) <= 0.9 * float(g["err"]) \
     and int(m["ink"]) >= 5000
sys.exit(0 if ok else 1)
PY
else
  bad AA "missing AA captures (metal / ANGLE N=0 / ANGLE N=16)"
fi

echo "== S: style-audit grid, windowed Metal =="
eval "$(sed -n '/^LANDED=(/,/^)/p;/^KEEP=(/,/^)/p' "$ROOT/tools/ci-style-audit.sh")"
run grid metal default -- --bundle "$FX/style-audit/prebuilt/style-audit.bundle" --app-name probe --width 600 \
  --height 1050 --scale 1 --initial-url probe://grid --frames 150 --screenshot-after 1500 --screenshot "$WORK/grid.ppm"
if shot grid; then
  grep -q 'window px=1200x2100 ' "$WORK/grid.log" || bad S "grid window: $(grep -m1 'window px' "$WORK/grid.log")"
  python3 "$ROOT/tools/style-audit-measure.py" "$WORK/grid.ppm" "$FX/style-audit/index.js" > "$WORK/tiles.txt"
  sbad=""
  for e in "${LANDED[@]}" "${KEEP[@]}"; do
    t="${e%%:*}"
    [ "$(awk -v t="$t" '$1=="TILE" && $3==t {print $4}' "$WORK/tiles.txt")" = PASS ] || sbad="$sbad $t"
  done
  [ -z "$sbad" ] && echo "   $((${#LANDED[@]} + ${#KEEP[@]})) LANDED+KEEP tiles PASS; $(grep TILES_FAILING "$WORK/tiles.txt")" \
    || bad S "tiles not PASS on Metal:$sbad"
fi

echo "== F: ci-first-present on the default (Metal) backend =="
KEEP_WORKDIR=1 bash "$ROOT/tools/ci-first-present.sh" > "$WORK/fp.out" 2>&1; frc=$?
fpw="$(sed -n 's/^workdir kept: //p' "$WORK/fp.out" | tail -1)"
if [ "$frc" != 0 ]; then
  bad F "ci-first-present failed: $(grep -m1 FIRST_PRESENT_GATE_FAIL "$WORK/fp.out" || tail -1 "$WORK/fp.out")"
elif [ -z "$fpw" ] || ! grep -q 'backend_select backend=metal' "$fpw/run.log"; then
  bad F "ci-first-present did not run on Metal ($(grep -m1 backend_select "$fpw/run.log" 2>/dev/null || echo 'no log'))"
else
  # Not in V: darwin-run-interactive.sh does not forward MTL_* to the child.
  cp "$fpw/run.log" "$WORK/first-present.log"
  echo "   $(grep -m1 FIRST_PRESENT_GATE_PASS "$WORK/fp.out")"
fi
[ -z "$fpw" ] || rm -rf "$fpw"

echo "== Z: resize inside a 1.2 s main-thread stall =="
for be in metal:0 gles:4; do
  run "rs-${be%%:*}" "${be%%:*}" "${be#*:}" -- --bundle "$BU" --app-name EngSupersample --width 400 --height 300 \
    --frames 60 --resize-after-frames 10:500x400 --stall-after-frames 10:1200 --screenshot-after-frames 50 \
    --screenshot "$WORK/rs-${be%%:*}.ppm"
done
pd="$(sed -nE 's/.*painted_during=([0-9]+).*/\1/p' "$WORK/rs-metal.log" | head -1)"
[ "${pd:-0}" -ge 1 ] || bad Z "nothing painted during the stall (painted_during=${pd:-none})"
grep -q "resize px=$((500 * S))x$((400 * S)) " "$WORK/rs-metal.log" || bad Z "no resize to $((500 * S))x$((400 * S)) px"
if shot rs-metal && shot rs-gles; then
  d="$(MC diff "$WORK/rs-metal.ppm" "$WORK/rs-gles.ppm")"
  echo "   painted_during=$pd $d"
  [[ "$d" == *"size=$((500 * S))x$((400 * S)) "* ]] || bad Z "capture after resize is not $((500 * S))x$((400 * S)): $d"
  python3 -c "import sys; sys.exit(0 if float(sys.argv[1])<=1.0 and float(sys.argv[2])<=2.0 else 1)" \
    "$(kv "$d" mean)" "$(kv "$d" over24_pct)" 2>/dev/null || bad Z "resized Metal frame != ANGLE: $d"
fi

echo "== V: Metal validation (MTL_DEBUG_LAYER + MTL_SHADER_VALIDATION) =="
[ "${#METAL_LOGS[@]}" -ge 10 ] || bad V "only ${#METAL_LOGS[@]} Metal runs to check"
verr=0
for l in "${METAL_LOGS[@]}"; do
  grep -q 'Metal API Validation Enabled' "$l" || { bad V "$(basename "$l"): validation layer was not on"; continue; }
  if grep -qiE 'failed assertion|validation error|MTLDebug|command buffer was aborted|shader validation.*(error|fault)' "$l"; then
    verr=$((verr + 1)); bad V "$(basename "$l"): $(grep -m1 -iE 'failed assertion|validation error|MTLDebug|aborted|shader validation' "$l" | cut -c1-200)"
  fi
done
echo "   metal_runs=${#METAL_LOGS[@]} validation_errors=$verr"

[ "${#FAILS[@]}" = 0 ] || { echo "METAL_GATE FAIL (arms: ${FAILS[*]})"; exit 1; }
echo "METAL_GATE PASS darwin (R CAPTURE P AA S F Z V; metal runs ${#METAL_LOGS[@]}, validation errors 0)"
