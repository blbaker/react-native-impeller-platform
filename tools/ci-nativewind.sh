#!/usr/bin/env bash
# ENG-19 gate: a scratch React Native app with NO app-side Metro shims bundles
# and paints a NativeWind className box on the impeller platform.
#
# THE BUG. Every NativeWind / Gluestack app carried its own Metro shims (HostApp:
# metro-shims/Image.impeller-stub.js, reanimated-stub.js, and
# StyleSheet/PlatformColorValueTypes.js in a private self re-export list).
# Without them: react-native-css require()s react-native-reanimated (no
# Worklets module on this engine, and an app that does not install it cannot
# even bundle), reads RN.Image on every render, and PlatformColor resolves to a
# self re-export that exports undefined (ENGINE-LEDGER ENG-19).
#
# THE FIXTURE IS THE ACCEPTANCE PROBE. fixtures/eng19-nativewind is a stock RN
# base app + NativeWind 5 rc.0 / react-native-css 3.1 rc.0 / Tailwind 4.1.12
# (HostApp's pins), whose metro.config.js is ONLY withImpeller + withNativewind.
# react-native-reanimated is NOT installed. All three pieces are load-bearing
# for this app, measured: no reanimated stub -> Metro fails to bundle; no
# PlatformColorValueTypes redirect -> scene_nodes=0; no Image shim -> fatal
# "Cannot convert undefined value to object".
#
#   A. BUNDLE. Metro bundles the scratch app (needs node + npm; NO_NPM=1 or a
#      box without npm skips to the committed prebuilt bundle).
#   B. PAINT. Headless render: scene_nodes > 0, no JS exception, the
#      bg-red-500 box centre is Tailwind red-500 (251,44,54) and the
#      bg-blue-600 + transition-colors box is blue-600 (21,93,252), each
#      within 6 levels, and the page outside both is white.
#   C. RESOLVER. withImpeller hands 'react-native-reanimated' to the stub only
#      when the app has NOT installed it: a fake upstream that resolves it is
#      returned untouched; one that throws gets the stub; other platforms are
#      never redirected.
#
# The Mac (no node) runs B only: RNI_BIN=<darwin rn-impeller> bash tools/ci-nativewind.sh
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { echo "NATIVEWIND_GATE_FAIL: $*" >&2; exit 1; }

ENGINE="${RNI_BIN:-$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller}"
[ -x "$ENGINE" ] || fail "no engine binary at $ENGINE (set RNI_BIN)"
FIX="$ROOT/fixtures/eng19-nativewind"
PREBUILT="$FIX/prebuilt/eng19-nativewind.bundle"

WORK="$(mktemp -d)"
KEEP="${KEEP_WORKDIR:-0}"
cleanup() { rni_kill_own; [ "$KEEP" = "1" ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

HAVE_NPM=0
if [ "${NO_NPM:-0}" != "1" ] && command -v node > /dev/null && command -v npm > /dev/null; then
  HAVE_NPM=1
fi

if [ "$HAVE_NPM" = "1" ]; then
  echo "== C. resolver: stub only when the app has no reanimated =="
  node - "$ROOT/package/src/metro-shims" <<'JS' > "$WORK/resolver.txt" 2>&1 || { cat "$WORK/resolver.txt" >&2; fail "C: resolver probe crashed"; }
const {withImpeller, SHIM_DIR} = require(process.argv[2]);
const path = require('path');
const stub = path.join(SHIM_DIR, 'reanimated.impeller.js');
const real = {type: 'sourceFile', filePath: '/app/node_modules/react-native-reanimated/lib/index.js'};
const ctx = {originModulePath: '/app/index.js', resolveRequest: () => { throw new Error('no upstream'); }};
const installed = withImpeller({resolver: {resolveRequest: () => real}}).resolver.resolveRequest;
const missing = withImpeller({resolver: {resolveRequest: () => { throw new Error('Unable to resolve'); }}}).resolver.resolveRequest;
const r1 = installed(ctx, 'react-native-reanimated', 'impeller');
console.log('installed', r1.filePath === real.filePath ? 'KEPT' : 'REPLACED:' + r1.filePath);
let r2;
try { r2 = missing(ctx, 'react-native-reanimated', 'impeller'); } catch (e) { r2 = {threw: e.message}; }
console.log('missing', r2 && r2.filePath === stub ? 'STUB' : 'NOSTUB:' + JSON.stringify(r2));
let r3;
try { r3 = missing(ctx, 'react-native-reanimated', 'ios'); } catch (e) { r3 = 'THREW'; }
console.log('ios', r3 === 'THREW' ? 'UNTOUCHED' : 'REDIRECTED:' + JSON.stringify(r3));
JS
  sed 's/^/   /' "$WORK/resolver.txt"
  grep -q '^installed KEPT$' "$WORK/resolver.txt" \
    || fail "C: an app that INSTALLED react-native-reanimated got the stub instead of its own package"
  grep -q '^missing STUB$' "$WORK/resolver.txt" \
    || fail "C: an app WITHOUT react-native-reanimated did not get the package stub"
  grep -q '^ios UNTOUCHED$' "$WORK/resolver.txt" \
    || fail "C: the reanimated redirect leaked onto a non-impeller platform"
  echo "   OK C: installed kept, missing stubbed, other platforms untouched"

  echo "== A. a scratch NativeWind app with no app shims bundles =="
  set +e
  bash tools/build-nativewind-bundle.sh "$WORK/nw.bundle" > "$WORK/build.log" 2>&1
  rc=$?
  set -e
  sed 's/^/   /' "$WORK/build.log" | tail -6
  [ "$rc" -eq 0 ] && [ -s "$WORK/nw.bundle" ] \
    || fail "A: Metro could not bundle the shim-free NativeWind app (rc=$rc): $(grep -m1 -E 'Unable|Error' "$WORK/build.log" | cut -c1-160)"
  grep -q '__impellerStub' "$WORK/nw.bundle" \
    || fail "A: the bundle does not carry the package's reanimated stub"
  BUNDLE="$WORK/nw.bundle"
  echo "   OK A: bundled $(wc -c < "$BUNDLE") bytes, reanimated stub from the package"
  if [ "${UPDATE_PREBUILT:-0}" = "1" ]; then
    mkdir -p "$(dirname "$PREBUILT")"; cp "$BUNDLE" "$PREBUILT"; echo "   updated $PREBUILT"
  fi
else
  echo "== A/C. SKIPPED (no node/npm): painting the committed prebuilt bundle =="
  BUNDLE="${RNI_TEST_BUNDLE:-$PREBUILT}"
  [ -s "$BUNDLE" ] || fail "no prebuilt bundle at $BUNDLE"
fi

echo "== B. the className boxes paint =="
set +e
"$ENGINE" --bundle "$BUNDLE" --app-name Eng19NativeWind --probe-banner off \
  --width 320 --height 300 --supersample-rnsvg 0 --headless \
  --screenshot "$WORK/nw.ppm" > "$WORK/nw.log" 2>&1
rc=$?
set -e
[ "$rc" -eq 0 ] || { tail -20 "$WORK/nw.log" >&2; fail "B: headless render exited $rc"; }
if grep -q 'js-exception' "$WORK/nw.log"; then
  grep -m2 'js-exception' "$WORK/nw.log" >&2
  fail "B: the app threw at runtime: $(grep -m1 'js-exception' "$WORK/nw.log" | cut -c1-160)"
fi
n="$(sed -n 's/^rn-impeller: scene_nodes=\([0-9]*\)$/\1/p' "$WORK/nw.log" | tail -1)"
[ -n "$n" ] && [ "$n" -gt 0 ] || fail "B: scene_nodes=${n:-none}: the app mounted nothing"
python3 - "$WORK/nw.ppm" > "$WORK/px.txt" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
parts, i = [], 0
while len(parts) < 4:
    while d[i:i + 1].isspace():
        i += 1
    s = i
    while not d[i:i + 1].isspace():
        i += 1
    parts.append(d[s:i])
w, h, px = int(parts[1]), int(parts[2]), d[i + 1:]
sx, sy = w / 320, h / 300
for name, (x, y) in {'red': (120, 70), 'blue': (120, 190), 'page': (300, 280)}.items():
    o = (int(y * sy) * w + int(x * sx)) * 3
    print(name, *px[o:o + 3])
PY
sed 's/^/   /' "$WORK/px.txt"
near() {  # $1 name $2 r $3 g $4 b
  read -r _ r g b < <(grep "^$1 " "$WORK/px.txt")
  python3 -c "import sys; sys.exit(0 if max(abs($r-$2),abs($g-$3),abs($b-$4)) <= 6 else 1)"
}
near red 251 44 54 || fail "B: the bg-red-500 box is $(grep '^red ' "$WORK/px.txt" | cut -d' ' -f2-), not Tailwind red-500 (251 44 54): className did not paint"
near blue 21 93 252 || fail "B: the bg-blue-600 transition box is $(grep '^blue ' "$WORK/px.txt" | cut -d' ' -f2-), not blue-600 (21 93 252): the Animated path did not paint"
near page 255 255 255 || fail "B: the page is not white outside the boxes"
echo "   OK B: red-500 and blue-600 boxes painted (scene_nodes=$n)"

echo "NATIVEWIND_GATE_PASS (a shim-free NativeWind app bundles and paints on impeller)"
