#!/usr/bin/env bash
# FP-05 gate: KHR_debug validation (engine/base/GlValidation.*). Node-free: committed prebuilt
# bundles, staged binary (or RNI_BIN), never rebuilds. Every arm runs with RNI_GL_VALIDATION=1
# and must report gl_validation_errors=0 on every context it created.
#
#   A  clean arms, windowed (xvfb) and headless, over the fixtures that reach our own GL calls:
#      NativeRotateProbe (animated), Eng21Nearest (<world> setPixels upload), EngSupersample and
#      EngSupersampleRoot at N=4 (offscreen FBO paths), FirstPresent
#   B  plant: RNI_TEST_GL_BAD_BIND=1 must be COUNTED (>= 1) in both modes, proving the callback is
#      live on this driver, and RNI_GL_VALIDATION=abort must die (SIGABRT) on it
#   C  RNI_GL_VALIDATION unset prints gl_validation=off and installs nothing
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
fail() { echo "GL_VALIDATION_FAIL: $*" >&2; exit 1; }

if [ -n "${RNI_BIN:-}" ]; then BIN="$RNI_BIN"
elif [ "$(uname -s)" = Darwin ]; then BIN="$ROOT/packages-engine/engine-darwin-arm64/bin/rn-impeller"
else BIN="$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller"; fi
[ -x "$BIN" ] || fail "no engine binary at $BIN (build with tools/engine-build.sh or set RNI_BIN)"
echo "engine: $BIN ($( (shasum -a 256 "$BIN" 2>/dev/null || sha256sum "$BIN") | cut -c1-12))"

WORK="$(mktemp -d)"
cleanup() { [ "${KEEP_WORKDIR:-0}" = 1 ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT
WIN=(); [ "$(uname -s)" = Linux ] && WIN=(xvfb-run -a -s "-screen 0 1280x1024x24")
FX="$ROOT/fixtures"
declare -A BUNDLE=(
  [NativeRotateProbe]="$FX/native-transform/prebuilt/native-transform.bundle"
  [Eng21Nearest]="$FX/eng21-world-nearest/prebuilt/eng21-world-nearest.bundle"
  [EngSupersample]="$FX/eng-supersample/prebuilt/eng-supersample.bundle"
  [EngSupersampleRoot]="$FX/eng-supersample-root/prebuilt/eng-supersample-root.bundle"
  [FirstPresent]="$FX/first-present/prebuilt/first-present.bundle"
)
APPS=(NativeRotateProbe Eng21Nearest EngSupersample EngSupersampleRoot FirstPresent)
for a in "${APPS[@]}"; do [ -s "${BUNDLE[$a]}" ] || fail "no committed bundle for $a"; done

run() {  # tag mode(window|headless) app [env...] -> sets RC, log $WORK/tag.log
  local tag="$1" mode="$2" app="$3"; shift 3
  local args=(--bundle "${BUNDLE[$app]}" --app-name "$app" --width 320 --height 240 --supersample-rnsvg 4)
  if [ "$mode" = window ]; then args+=(--window --scale 1 --frames 8); else args+=(--headless --probe-banner off --frames 8); fi
  RC=0
  local pre=(); [ "$mode" = window ] && pre=("${WIN[@]}")
  ( cd "$(dirname "$BIN")" && env "$@" timeout 300 ${pre[@]+"${pre[@]}"} "$BIN" "${args[@]}" ) \
    > "$WORK/$tag.log" 2>&1 || RC=$?
}
errors_of() { sed -n 's/^rn-impeller: gl_validation_errors=\([0-9]*\) .*/\1/p' "$1" | tail -1; }

echo "== A: clean fixtures, zero GL errors =="
for mode in window headless; do
  for app in "${APPS[@]}"; do
    tag="A-$mode-$app"
    run "$tag" "$mode" "$app" RNI_GL_VALIDATION=1
    [ "$RC" -eq 0 ] || { tail -15 "$WORK/$tag.log" >&2; fail "A $mode $app exited $RC"; }
    grep -qE '^rn-impeller: scene_nodes=[1-9]' "$WORK/$tag.log" || fail "A $mode $app mounted nothing"
    grep -q '^rn-impeller: gl_validation=on mode=count context=1' "$WORK/$tag.log" \
      || fail "A $mode $app: validation was not installed on the context"
    n="$(errors_of "$WORK/$tag.log")"
    [ "$n" = 0 ] || { grep 'gl_validation:' "$WORK/$tag.log" | head -5 >&2; fail "A $mode $app: gl_validation_errors=${n:-missing}"; }
    echo "   $mode $app: gl_validation_errors=0"
  done
done

echo "== B: planted GL error is counted, and aborts in abort mode =="
for mode in window headless; do
  tag="B-$mode"
  run "$tag" "$mode" NativeRotateProbe RNI_GL_VALIDATION=1 RNI_TEST_GL_BAD_BIND=1
  [ "$RC" -eq 0 ] || fail "B $mode exited $RC in count mode"
  n="$(errors_of "$WORK/$tag.log")"
  [ "${n:-0}" -ge 1 ] || fail "B $mode: planted glBindTexture error not counted (gl_validation_errors=${n:-missing})"
  echo "   $mode count: gl_validation_errors=$n"
  run "$tag-abort" "$mode" NativeRotateProbe RNI_GL_VALIDATION=abort RNI_TEST_GL_BAD_BIND=1
  { [ "$RC" -eq 134 ] || [ "$RC" -eq 6 ]; } || fail "B $mode abort: exit $RC, expected SIGABRT (134)"
  echo "   $mode abort: exit $RC"
done

echo "== C: off by default =="
run C headless NativeRotateProbe RNI_GL_VALIDATION=0
[ "$RC" -eq 0 ] || fail "C exited $RC"
grep -q '^rn-impeller: gl_validation=off' "$WORK/C.log" || fail "C: no gl_validation=off line"
grep -q 'gl_validation=on' "$WORK/C.log" && fail "C: validation installed while off"

echo "GL_VALIDATION_PASS ${#APPS[@]} fixtures x windowed+headless, planted error counted + aborts"
