#!/usr/bin/env bash
# ENG-17: prove tools/ci-color-scheme.sh FAILS when any one piece of the fix
# is removed. Each mutant edits the live tree, rebuilds, runs the gate, restores.
#   M1 setColorScheme never emits appearanceChanged       -> A
#   M2 the payload key is wrong (not colorScheme)         -> A
#   M3 'unspecified' is stored literally                  -> B
#   M4 the event is sent even when nothing changed        -> C
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PM="engine/modules/PlatformModules.h"
BACKUP="$(mktemp -d)"
cp "$PM" "$BACKUP/PM"
BUILD_CMD="${RNI_BUILD_CMD:-bash tools/engine-build.sh linux x64}"
restore() { cp "$BACKUP/PM" "$PM"; }
trap 'restore; eval "$BUILD_CMD" > /tmp/mvcs-restore.log 2>&1 || true; rm -rf "$BACKUP"' EXIT

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
  if ! eval "$BUILD_CMD" > /tmp/mvcs-build.log 2>&1; then
    echo "   BUILD FAILED: a mutant that does not compile proves nothing"
    grep -E 'error:' /tmp/mvcs-build.log | head -3 | sed 's/^/     /'
  elif bash tools/ci-color-scheme.sh > /tmp/mvcs-gate.log 2>&1; then
    echo "   NOT CAUGHT: gate still passed"
  elif grep -qE "COLOR_SCHEME_GATE_FAIL: ($2)" /tmp/mvcs-gate.log; then
    echo "   caught: $(grep COLOR_SCHEME_GATE_FAIL /tmp/mvcs-gate.log | head -1 | cut -c1-170)"
    PASS=$((PASS + 1))
  else
    echo "   killed, but not by the expected arm ($2):"
    grep COLOR_SCHEME_GATE_FAIL /tmp/mvcs-gate.log | head -1 | sed 's/^/     /'
  fi
  restore
}

echo "MUTATION_VERIFY_COLOR_SCHEME_START"

mutate "$PM" '    emitDeviceEvent("appearanceChanged",' \
             '    if (false) emitDeviceEvent("appearanceChanged",  // MUTANT M1'
run_mutant "M1 no appearanceChanged event" "A: subscriber renders"

mutate "$PM" '                      prefs.setProperty(rt2, "colorScheme",' \
             '                      prefs.setProperty(rt2, "scheme",  // MUTANT M2'
run_mutant "M2 payload key is not colorScheme" "A: "

mutate "$PM" '    effective = requested == "unspecified" ? systemScheme : requested;' \
             '    effective = requested;  // MUTANT M3'
run_mutant "M3 unspecified stored literally" "B: "

mutate "$PM" '    if (effective == colorScheme) return false;' \
             '    // MUTANT M4: no change check'
run_mutant "M4 event sent on a no-op set" "C: "

echo
if [ "$PASS" -eq "$TOTAL" ]; then
  echo "MUTATION_VERIFY_COLOR_SCHEME_PASS ($PASS/$TOTAL)"
else
  echo "MUTATION_VERIFY_COLOR_SCHEME_FAIL ($PASS/$TOTAL)"
  exit 1
fi
