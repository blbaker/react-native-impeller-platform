#!/usr/bin/env bash
# FP-41 gate: expo-blur <BlurView> blurs what is BEHIND it (SaveLayer backdrop filter).
#
# fixtures/fp41-backdrop (committed prebuilt bundle, expo 57 + expo-blur, node-free), headless
# 400x300 at --supersample-rnsvg 0 and 4. Each supersample renders Fp41Backdrop and Fp41NoBlur
# (same tree, no BlurViews). tools/backdrop_check.py then asserts, per supersample:
#   blurred  colour sd inside the dark blur view and inside the light one in a scrolled ScrollView
#            is < 15% of a control painted with the same tint over the same stripes, unblurred
#   tint     their mean = backdrop mean blended with expo-blur's tint colour (getBackgroundColor.ts)
#   child    the BlurView's child paints crisp on top
#   outside  every pixel outside the blur views equals the no-blur reference (max diff 2)
# Rebuild the bundle: tools/build-fp41-backdrop-bundle.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BUNDLE="$ROOT/fixtures/fp41-backdrop/prebuilt/fp41-backdrop.bundle"
fail() { echo "BACKDROP_FAIL: $*" >&2; exit 1; }
[ -s "$BUNDLE" ] || fail "no committed bundle at $BUNDLE"
if [ -n "${RNI_BIN:-}" ]; then
  BIN="$RNI_BIN"
elif [ "$(uname -s)" = Darwin ]; then
  BIN="$ROOT/packages-engine/engine-darwin-arm64/bin/rn-impeller"
else
  BIN="$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller"
fi
[ -x "$BIN" ] || fail "no engine binary at $BIN (build it: tools/engine-build.sh, or set RNI_BIN)"
echo "engine: $BIN ($(sha256sum "$BIN" 2>/dev/null | cut -c1-12))"

WORK="$(mktemp -d)"
cleanup() { [ "${KEEP_WORKDIR:-0}" = 1 ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

run() {  # app supersample
  local app="$1" ss="$2" tag="$1-ss$2" rc=0
  ( cd "$(dirname "$BIN")" && timeout 180 "$BIN" --bundle "$BUNDLE" --app-name "$app" --headless \
      --width 400 --height 300 --probe-banner off --supersample-rnsvg "$ss" \
      --screenshot "$WORK/$tag.ppm" ) > "$WORK/$tag.log" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || { tail -15 "$WORK/$tag.log" >&2; fail "$tag exited $rc"; }
  grep -qE '^rn-impeller: scene_nodes=[1-9]' "$WORK/$tag.log" || fail "$tag: nothing mounted"
  grep -q "^rn-impeller: supersample_rnsvg=$ss" "$WORK/$tag.log" || fail "$tag: supersample_rnsvg is not $ss"
  [ -s "$WORK/$tag.ppm" ] || fail "$tag: no screenshot"
  grep -h 'gl_validation' "$WORK/$tag.log" || true
}

rc=0
for ss in 0 4; do
  echo "== supersample $ss =="
  run Fp41Backdrop "$ss"
  run Fp41NoBlur "$ss"
  python3 tools/backdrop_check.py "$WORK/Fp41Backdrop-ss$ss.ppm" "$WORK/Fp41NoBlur-ss$ss.ppm" "ss$ss" || rc=1
done
[ "$rc" -eq 0 ] || fail "see BACKDROP_FAIL lines above"
echo "BACKDROP_PASS"
