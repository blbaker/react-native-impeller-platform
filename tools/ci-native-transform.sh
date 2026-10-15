#!/usr/bin/env bash
# NATIVE-DRIVEN ANIMATED TRANSFORM GATE (Mac ledger DS-INPUT-SPIN, internal request).
#
# With useNativeDriver: true, RN's C++ TransformAnimatedNode sends `transform`
# as an operation list ([{rotate: <radians>}]). SceneGraph::updateViewProps
# only took a flat 16-number matrix, so every native rotate/translate/scale was
# skipped with no log line: the peer's 100x20 bar stayed 100x20 on every frame
# while nativeanimated_ticks counted 30.
#
# Renders the committed fixtures/native-transform bundle headless at
# --frames 1/11/21/31 per app and checks (tools/native_transform_check.py):
#   A  the peer's rotate probe: bounding box matches the rotation angle the
#      curve gives at each frame, all four differ, pivot stays at the centre
#   B  negative arm: same tree, loop never started -> 100x20 on every frame
#   C  opacity pulse (skeleton style): centre luma follows the curve
#   D  translateX/translateY/scale: centre and size follow the curve
#   E  cost: a native-driven loop runs 0 JS timers and 0 React commits during
#      the frames; a JS-driven control MUST show both non-zero (instrument check)
#
# Node-free: bundle is committed (rebuild: tools/build-fixture-bundle.sh
# native-transform NativeRotateProbe). Engine: RNI_BIN wins; linux builds and
# uses its staged package; darwin uses the staged engine-darwin-arm64.
# --supersample-rnsvg is PINNED to 0 (darwin defaults to 4).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BUNDLE="$ROOT/fixtures/native-transform/prebuilt/native-transform.bundle"
fail() { echo "NT_FAIL: $*" >&2; exit 1; }

OS="$(uname -s)"
[ -s "$BUNDLE" ] || fail "no committed bundle at $BUNDLE"
if [ -n "${RNI_BIN:-}" ]; then
  BIN="$RNI_BIN"
elif [ "$OS" = Darwin ]; then
  BIN="$ROOT/packages-engine/engine-darwin-arm64/bin/rn-impeller"
elif [ "$OS" = Linux ]; then
  case "$(uname -m)" in x86_64) ARCH=x64 ;; aarch64) ARCH=arm64 ;; *) fail "unsupported arch $(uname -m)" ;; esac
  bash tools/engine-build.sh linux "$ARCH" > "${TMPDIR:-/tmp}/ci-native-transform-build.log" 2>&1 \
    || { tail -20 "${TMPDIR:-/tmp}/ci-native-transform-build.log" >&2; fail "engine build failed"; }
  BIN="$ROOT/packages-engine/engine-linux-$ARCH/bin/rn-impeller"
else
  fail "unsupported OS $OS"
fi
[ -x "$BIN" ] || fail "no engine binary at $BIN (set RNI_BIN)"
echo "engine: $BIN ($( (shasum -a 256 "$BIN" 2>/dev/null || sha256sum "$BIN") | cut -c1-12))"

WORK="$(mktemp -d)"
cleanup() { [ "${KEEP_WORKDIR:-0}" = 1 ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

# The Mac has no GNU timeout; every run is bounded by --frames anyway.
TO=(); command -v timeout >/dev/null && TO=(timeout 120)

render() {  # app frames
  local app="$1" k="$2" rc=0
  # cwd = the engine dir: the darwin binary links ./libimpeller.dylib.
  ( cd "$(dirname "$BIN")" && "${TO[@]}" "$BIN" --headless --bundle "$BUNDLE" \
      --app-name "$app" --width 400 --height 300 --probe-banner off \
      --supersample-rnsvg 0 --frames "$k" --screenshot "$WORK/$app-$k.ppm" ) \
    > "$WORK/$app-$k.log" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || { tail -15 "$WORK/$app-$k.log" >&2; fail "$app --frames $k exited $rc"; }
  grep -q '^rn-impeller: supersample_rnsvg=0' "$WORK/$app-$k.log" \
    || fail "$app --frames $k: supersample_rnsvg is not 0 ($(grep -m1 -o 'supersample_rnsvg=[0-9]*' "$WORK/$app-$k.log"))"
  [ -s "$WORK/$app-$k.ppm" ] || fail "$app --frames $k wrote no screenshot"
}

echo "== render =="
for k in 1 11 21 31; do
  render NativeRotateProbe "$k"
  render NativeOpacityPulse "$k"
  render NativeTranslateScale "$k"
done
render NativeRotateIdle 1
render NativeRotateIdle 31
# JS-driven control: requestAnimationFrame keeps JS busy, so the headless
# per-frame idle wait runs to its 5 s cap. One frame is enough to see JS work.
render JsRotateProbe 1

python3 tools/native_transform_check.py "$WORK"
