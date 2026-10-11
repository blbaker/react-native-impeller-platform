#!/usr/bin/env bash
# ENG-18: prove tools/ci-window-type.sh FAILS when any one piece of the fix is
# removed. Each mutant edits the live tree, rebuilds, runs the gate.
#   M1 main() never hands --type to RunWindowed           -> arm A
#   M2 --screenshot captures before the typing finishes   -> arm A
#   M3 <BS> edits the buffer directly, skipping the key path -> arm C
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MAIN="engine/host/main.cpp"
BACKUP="$(mktemp -d)"
cp "$MAIN" "$BACKUP/MAIN"
BUILD_CMD="${RNI_BUILD_CMD:-bash tools/engine-build.sh linux x64}"
restore() { cp "$BACKUP/MAIN" "$MAIN"; }
trap 'restore; eval "$BUILD_CMD" > /tmp/mvwt-restore.log 2>&1 || true; rm -rf "$BACKUP"' EXIT

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
  if ! eval "$BUILD_CMD" > /tmp/mvwt-build.log 2>&1; then
    echo "   BUILD FAILED: a mutant that does not compile proves nothing"
    grep -E 'error:' /tmp/mvwt-build.log | head -3 | sed 's/^/     /'
  elif bash tools/ci-window-type.sh > /tmp/mvwt-gate.log 2>&1; then
    echo "   NOT CAUGHT: gate still passed"
  elif grep -qE "WINDOW_TYPE_GATE_FAIL: ($2):" /tmp/mvwt-gate.log; then
    echo "   caught: $(grep WINDOW_TYPE_GATE_FAIL /tmp/mvwt-gate.log | head -1 | cut -c1-170)"
    PASS=$((PASS + 1))
  else
    echo "   killed, but not by the expected arm ($2):"
    grep WINDOW_TYPE_GATE_FAIL /tmp/mvwt-gate.log | head -1 | sed 's/^/     /' || true
  fi
  restore
}

echo "MUTATION_VERIFY_WINDOW_TYPE_START"

mutate "$MAIN" "    gWindowedTypeSpec = typeSpec;  // ENG-18" \
               "    (void)typeSpec;  // MUTANT M1"
run_mutant "M1 windowed run never sees --type" "A"

mutate "$MAIN" "        typePlan && typeDone && frameIndex >= typeDoneFrame + 2;" \
               "        typePlan;  // MUTANT M2"
run_mutant "M2 capture before typing" "A"

mutate "$MAIN" "          case TypeToken::Backspace:
            pressKey(\"Backspace\", false);" \
               "          case TypeToken::Backspace:
            fabric.dispatchKey(rni::FabricHost::KeyAction::Backspace, 0);  // MUTANT M3"
run_mutant "M3 <BS> skips the key path" "C"

echo
if [ "$PASS" -eq "$TOTAL" ]; then
  echo "MUTATION_VERIFY_WINDOW_TYPE_PASS ($PASS/$TOTAL)"
else
  echo "MUTATION_VERIFY_WINDOW_TYPE_FAIL ($PASS/$TOTAL caught)"
  exit 1
fi
