#!/usr/bin/env bash
# SC-23: prove tools/ci-os-appearance.sh FAILS when any one piece is removed.
#   M1 the watcher never reports a change                 -> B
#   M2 an OS change beats the app's setColorScheme        -> D
#   M3 boot ignores the OS/hook scheme                    -> A
#   M4 --color-scheme no longer beats the OS              -> C
#   M5 the change event carries the wrong payload key     -> B
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FILES=(engine/host/OsAppearance.cpp engine/modules/PlatformModules.h engine/host/main.cpp)
BACKUP="$(mktemp -d)"
for f in "${FILES[@]}"; do mkdir -p "$BACKUP/$(dirname "$f")"; cp "$f" "$BACKUP/$f"; done
BUILD_CMD="${RNI_BUILD_CMD:-bash tools/engine-build.sh linux x64}"
restore() { for f in "${FILES[@]}"; do cp "$BACKUP/$f" "$f"; done; }
trap 'restore; eval "$BUILD_CMD" > /tmp/mvosa-restore.log 2>&1 || true; rm -rf "$BACKUP"' EXIT

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
  if ! eval "$BUILD_CMD" > /tmp/mvosa-build.log 2>&1; then
    echo "   BUILD FAILED: a mutant that does not compile proves nothing"
    grep -E 'error:' /tmp/mvosa-build.log | head -3 | sed 's/^/     /'
  elif bash tools/ci-os-appearance.sh > /tmp/mvosa-gate.log 2>&1; then
    echo "   NOT CAUGHT: gate still passed"
  elif grep -qE "OS_APPEARANCE_GATE_FAIL: ($2)" /tmp/mvosa-gate.log; then
    echo "   caught: $(grep OS_APPEARANCE_GATE_FAIL /tmp/mvosa-gate.log | head -1 | cut -c1-170)"
    PASS=$((PASS + 1))
  else
    echo "   killed, but not by the expected arm ($2):"
    grep OS_APPEARANCE_GATE_FAIL /tmp/mvosa-gate.log | head -1 | sed 's/^/     /'
  fi
  restore
}

echo "MUTATION_VERIFY_OS_APPEARANCE_START"

mutate engine/host/OsAppearance.cpp '        cb(now);' '        (void)cb;  // MUTANT M1'
run_mutant "M1 watcher never reports" "B: "

mutate engine/modules/PlatformModules.h '    if (appOverride || colorScheme == scheme) return false;' \
        '    if (colorScheme == scheme) return false;  // MUTANT M2'
run_mutant "M2 OS change beats the app override" "D: "

mutate engine/host/main.cpp '    const std::string os = rni::ResolveSystemScheme(windowMode);' \
        '    const std::string os = "";  // MUTANT M3'
run_mutant "M3 boot ignores the OS scheme" "A: "

mutate engine/host/main.cpp '  if (!colorSchemeGiven) {' '  if (true) {  // MUTANT M4'
run_mutant "M4 flag no longer beats the OS" "C: "

mutate engine/host/main.cpp '"appearanceChanged", folly::dynamic::object("colorScheme", scheme));' \
        '"appearanceChanged", folly::dynamic::object("scheme", scheme));  // MUTANT M5'
run_mutant "M5 wrong payload key" "B: "

echo
if [ "$PASS" -eq "$TOTAL" ]; then
  echo "MUTATION_VERIFY_OS_APPEARANCE_PASS ($PASS/$TOTAL)"
else
  echo "MUTATION_VERIFY_OS_APPEARANCE_FAIL ($PASS/$TOTAL)"
  exit 1
fi
