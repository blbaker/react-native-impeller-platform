#!/usr/bin/env bash
# ENG-19: prove tools/ci-nativewind.sh FAILS when any one package shim the
# shim-free NativeWind app depends on is removed. Package-only mutants (JS), so
# no engine rebuild. Each edits the live package tree, runs the gate, restores.
#   M1 no reanimated redirect (the pre-ENG-19 package)   -> arm A (bundle)
#   M2 redirect ALWAYS stubs, even when installed         -> arm C
#   M3 PlatformColorValueTypes not in SELF_REEXPORTS      -> arm B (mounts 0)
#   M4 Image.js not shimmed                               -> arm B (throws)
#   M5 stub createAnimatedComponent paints nothing       -> arm B
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

IDX="package/src/metro-shims/index.js"
STUB="package/src/metro-shims/shims/reanimated.impeller.js"
BACKUP="$(mktemp -d)"
cp "$IDX" "$BACKUP/IDX"; cp "$STUB" "$BACKUP/STUB"
restore() { cp "$BACKUP/IDX" "$IDX"; cp "$BACKUP/STUB" "$STUB"; }
trap 'restore; rm -rf "$BACKUP"' EXIT

PASS=0; TOTAL=0
mutate() {  # $1 file  $2 old  $3 new  (exact, must occur exactly once)
  python3 - "$1" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
n = s.count(old)
assert n == 1, f"anchor found {n}x in {p}: {old[:60]!r}"
open(p, "w").write(s.replace(old, new))
PY
}
run_mutant() {  # $1 name  $2 ERE the FAIL line must match
  TOTAL=$((TOTAL + 1))
  echo "--- $1"
  if bash tools/ci-nativewind.sh > /tmp/mvnw-gate.log 2>&1; then
    echo "   NOT CAUGHT: gate still passed"
  elif grep -qE "NATIVEWIND_GATE_FAIL: ($2):" /tmp/mvnw-gate.log; then
    echo "   caught: $(grep NATIVEWIND_GATE_FAIL /tmp/mvnw-gate.log | head -1 | cut -c1-170)"
    PASS=$((PASS + 1))
  else
    echo "   killed, but not by the expected arm ($2):"
    grep NATIVEWIND_GATE_FAIL /tmp/mvnw-gate.log | head -1 | sed 's/^/     /'
  fi
  restore
}

echo "MUTATION_VERIFY_NATIVEWIND_START"

mutate "$IDX" "    if (platform === 'impeller' && moduleName === REANIMATED) {" \
              "    if (false && moduleName === REANIMATED) {  // MUTANT M1"
# M1 also kills C's 'missing STUB' line; C runs first, so accept C or A.
run_mutant "M1 no reanimated redirect" "A|C"

mutate "$IDX" "      try {
        return baseResolve(context, moduleName, platform);
      } catch (error) {
        return {type: 'sourceFile', filePath: path.join(SHIM_DIR, REANIMATED_SHIM)};
      }" "      return {type: 'sourceFile', filePath: path.join(SHIM_DIR, REANIMATED_SHIM)};  // MUTANT M2"
run_mutant "M2 always stubs, even when installed" "C"

mutate "$IDX" "  'react-native/Libraries/StyleSheet/PlatformColorValueTypes.js',
" "  // MUTANT M3
"
run_mutant "M3 PlatformColorValueTypes not redirected" "B"

mutate "$IDX" "  'react-native/Libraries/Image/Image.js': 'Image.impeller.js',
" "  // MUTANT M4
"
run_mutant "M4 Image.js not shimmed" "B"

# createAnimatedComponent is what react-native-css wraps a transition/animation
# component with. A stub that returns a component painting NOTHING must make
# the blue transition box vanish -- proving the fixture really drives the
# animated path (an Animated.View-only mutant is equivalent: the identity wrap
# hides it).
mutate "$STUB" "const id = (c) => c;" "const id = () => () => null;  // MUTANT M5"
run_mutant "M5 stub createAnimatedComponent paints nothing" "B"

echo
if [ "$PASS" -eq "$TOTAL" ]; then
  echo "MUTATION_VERIFY_NATIVEWIND_PASS ($PASS/$TOTAL)"
else
  echo "MUTATION_VERIFY_NATIVEWIND_FAIL ($PASS/$TOTAL)"
  exit 1
fi
