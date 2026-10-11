#!/usr/bin/env bash
# SC-26 gate: NativeWind animate-* / transition-* and the Reanimated API move
# on impeller through the package's reanimated stub (JS-thread clock).
#
# Fixture: fixtures/sc26-nw-animate (see its header for the tile map). One
# headless capture; the engine's two 10 s JS-idle waits put it ~20 s after
# mount while the 60 s animations are mid-flight. tools/nw_animate_rules.py
# reads the elapsed time off the ref box and checks every other tile against
# the value its animation must have at that time:
#   ctl / spinPaused / pulsePaused  paused keyframes at a negative delay:
#                                   45 deg diamond, opacity 0.5 (exact)
#   ref seq repeat delay spring     withTiming/withSequence/withRepeat(reverse)/
#                                   withDelay/withSpring positions
#   inline                          inline withTiming in useAnimatedStyle
#   transitionColors                CSS transition colour blend
#   A. (node only) the stub still exports every name of the inert stub.
#      NW_ANIMATE_SKIP_A=1 skips it (mutation-verify proves the pixel arm alone).
#
# Node-free (B): RNI_BIN=<engine> bash tools/ci-nw-animate.sh. BUILD_BUNDLE=1
# rebuilds the prebuilt bundle from the current package/ first (needs npm).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { echo "NW_ANIMATE_GATE_FAIL: $*" >&2; exit 1; }

ENGINE="${RNI_BIN:-$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller}"
[ -x "$ENGINE" ] || fail "no engine binary at $ENGINE (set RNI_BIN)"
FIX="$ROOT/fixtures/sc26-nw-animate"
BUNDLE="${RNI_TEST_BUNDLE:-$FIX/prebuilt/sc26-nw-animate.bundle}"
if [ "${BUILD_BUNDLE:-0}" = "1" ] && [ -z "${RNI_TEST_BUNDLE:-}" ]; then
  NW_FIX="$FIX" bash tools/build-nativewind-bundle.sh "$BUNDLE" > /dev/null || fail "could not rebuild the bundle"
fi
[ -s "$BUNDLE" ] || fail "no bundle at $BUNDLE"

WORK="$(mktemp -d)"
KEEP="${KEEP_WORKDIR:-0}"
cleanup() { rni_kill_own; [ "$KEEP" = "1" ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

if [ "${NW_ANIMATE_SKIP_A:-0}" != 1 ] && command -v node > /dev/null; then
  echo "== A. the stub keeps the inert stub's API surface =="
  node - "$ROOT/package/src/metro-shims/shims/reanimated.impeller.js" <<'JS' > "$WORK/api.txt" 2>&1 || { cat "$WORK/api.txt" >&2; fail "A: API probe crashed"; }
const Module = require('module');
const id = (t) => t;
const rn = {
  Easing: {linear: id, quad: id, bezier: () => id, inOut: () => id, in: () => id, out: () => id},
  processColor: () => null, StyleSheet: {flatten: (s) => s},
  View: function View() {}, Text: function Text() {}, Image: function Image() {},
  ScrollView: function ScrollView() {}, FlatList: function FlatList() {},
};
const react = {forwardRef: (f) => ({$$typeof: 'forwardRef', render: f}), useRef: () => ({current: null})};
const load = Module._load;
Module._load = function (req) {
  if (req === 'react-native') return rn;
  if (req === 'react') return react;
  return load.apply(this, arguments);
};
const m = require(process.argv[2]);
const names = ['default', 'createAnimatedComponent', 'FadeIn', 'FadeOut', 'FadeInUp', 'FadeInDown',
  'FadeOutUp', 'FadeOutDown', 'ZoomIn', 'ZoomOut', 'SlideInDown', 'SlideOutDown', 'SlideInUp',
  'SlideOutUp', 'SlideInLeft', 'SlideOutLeft', 'SlideInRight', 'SlideOutRight', 'Layout',
  'LinearTransition', 'useSharedValue', 'useDerivedValue', 'useAnimatedStyle', 'useAnimatedProps',
  'useAnimatedRef', 'useAnimatedReaction', 'useAnimatedScrollHandler', 'useReducedMotion',
  'withTiming', 'withSpring', 'withDecay', 'withDelay', 'withRepeat', 'withSequence',
  'cancelAnimation', 'runOnJS', 'runOnUI', 'interpolate', 'Extrapolation', 'ReduceMotion',
  'Easing', 'cubicBezier', 'steps'];
const missing = names.filter((n) => m[n] === undefined);
console.log('missing', missing.join(',') || 'none');
const a = m.default;
const comps = ['View', 'Text', 'Image', 'ScrollView', 'FlatList'].filter((k) => !a[k] || a[k] === rn[k]);
console.log('unwrapped', comps.join(',') || 'none');
console.log('stub', m.__impellerStub === true ? 'yes' : 'no');
console.log('preset', m.FadeIn.duration(200).delay(50) === m.FadeIn ? 'chainable' : 'broken');
JS
  sed 's/^/   /' "$WORK/api.txt"
  grep -q '^missing none$' "$WORK/api.txt" || fail "A: the stub dropped exports: $(grep '^missing' "$WORK/api.txt")"
  grep -q '^unwrapped none$' "$WORK/api.txt" || fail "A: Animated components are the plain RN ones: $(grep '^unwrapped' "$WORK/api.txt")"
  grep -q '^stub yes$' "$WORK/api.txt" || fail "A: __impellerStub marker missing (ci-nativewind.sh greps it)"
  grep -q '^preset chainable$' "$WORK/api.txt" || fail "A: layout-animation presets are not chainable"
  echo "   OK A: inert API surface kept"
else
  echo "== A. SKIPPED (no node, or NW_ANIMATE_SKIP_A=1) =="
fi

echo "== B. one headless capture, animations mid-flight =="
set +e
"$ENGINE" --bundle "$BUNDLE" --app-name Sc26NwAnimate --probe-banner off \
  --width 420 --height 370 --supersample-rnsvg 0 --headless \
  --screenshot "$WORK/a.ppm" > "$WORK/a.log" 2>&1
rc=$?
set -e
[ "$rc" -eq 0 ] || { tail -20 "$WORK/a.log" >&2; fail "B: headless render exited $rc"; }
if grep -q 'js-exception' "$WORK/a.log"; then
  fail "B: the app threw: $(grep -m1 'js-exception' "$WORK/a.log" | cut -c1-200)"
fi
n="$(sed -n 's/^rn-impeller: scene_nodes=\([0-9]*\)$/\1/p' "$WORK/a.log" | tail -1)"
[ -n "$n" ] && [ "$n" -gt 0 ] || fail "B: scene_nodes=${n:-none}: the app mounted nothing"
set +e
python3 tools/nw_animate_rules.py "$WORK/a.ppm" > "$WORK/rules.txt" 2>&1
rc=$?
set -e
sed 's/^/   /' "$WORK/rules.txt"
[ "$rc" -eq 0 ] || fail "B: $(grep '^FAIL' "$WORK/rules.txt" | sed 's/^FAIL //' | paste -sd';' - | cut -c1-400)"
grep -q '^Traceback' "$WORK/rules.txt" && fail "B: rules crashed"
echo "   OK B: $(grep -c '^PASS' "$WORK/rules.txt") tiles at $(sed -n 's/^ELAPSED //p' "$WORK/rules.txt")"
echo "NW_ANIMATE_GATE_PASS (animate-*, transition-* and the Reanimated API move on impeller)"
