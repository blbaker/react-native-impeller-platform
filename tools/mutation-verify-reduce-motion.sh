#!/usr/bin/env bash
# ENG-14: prove tools/ci-reduce-motion.sh FAILS when any one piece of the fix
# is removed. Each mutant edits the live tree, rebuilds, runs the gate, restores.
#   M1 the module is registered under the wrong name     -> D (REJECTED)
#   M2 RNI_REDUCE_MOTION is ignored (system value only)  -> A
#   M3 reduce motion answers the inverted value          -> A
#   M4 one getter (grayscale) never calls back           -> D
#   M5 the system read is skipped (always false)         -> C on a darwin host
#      with Reduce motion ON; on linux the system is false anyway, so M5 is
#      run only where it can be seen (RNI_M5=1 forces it).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

RH="engine/runtime/ReactHost.cpp"
AM="engine/modules/AccessibilityManagerModule.h"
BACKUP="$(mktemp -d)"
cp "$RH" "$BACKUP/RH"; cp "$AM" "$BACKUP/AM"
BUILD_CMD="${RNI_BUILD_CMD:-bash tools/engine-build.sh linux x64}"
restore() { cp "$BACKUP/RH" "$RH"; cp "$BACKUP/AM" "$AM"; }
trap 'restore; eval "$BUILD_CMD" > /tmp/mvrm-restore.log 2>&1 || true; rm -rf "$BACKUP"' EXIT

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
  if ! eval "$BUILD_CMD" > /tmp/mvrm-build.log 2>&1; then
    echo "   BUILD FAILED: a mutant that does not compile proves nothing"
    grep -E 'error:' /tmp/mvrm-build.log | head -3 | sed 's/^/     /'
  elif bash tools/ci-reduce-motion.sh > /tmp/mvrm-gate.log 2>&1; then
    echo "   NOT CAUGHT: gate still passed"
  elif grep -qE "REDUCE_MOTION_GATE_FAIL: ($2)" /tmp/mvrm-gate.log; then
    echo "   caught: $(grep REDUCE_MOTION_GATE_FAIL /tmp/mvrm-gate.log | head -1 | cut -c1-170)"
    PASS=$((PASS + 1))
  else
    echo "   killed, but not by the expected arm ($2):"
    grep REDUCE_MOTION_GATE_FAIL /tmp/mvrm-gate.log | head -1 | sed 's/^/     /'
  fi
  restore
}

echo "MUTATION_VERIFY_REDUCE_MOTION_START"

mutate "$RH" '  modules_->add("AccessibilityManager", [](auto inv) {' \
             '  modules_->add("AccessibilityManagerX", [](auto inv) {  // MUTANT M1'
run_mutant "M1 module registered under the wrong name" "D\(on\): a query REJECTED"

mutate "$AM" '    if (const char* o = std::getenv("RNI_REDUCE_MOTION")) {' \
             '    if (const char* o = nullptr) {  // MUTANT M2'
run_mutant "M2 RNI_REDUCE_MOTION ignored" "A: "

mutate "$AM" '    onSuccess.call(rt, v);' \
             '    onSuccess.call(rt, !v);  // MUTANT M3'
run_mutant "M3 reduce motion answers inverted" "A: "

mutate "$AM" '  void getCurrentGrayscaleState(jsi::Runtime& rt, jsi::Function onSuccess,
                                jsi::Function /*onError*/) {
    onSuccess.call(rt, false);' \
             '  void getCurrentGrayscaleState(jsi::Runtime& rt, jsi::Function onSuccess,
                                jsi::Function /*onError*/) {
    (void)rt; (void)onSuccess;  // MUTANT M4'
run_mutant "M4 grayscale getter never calls back" "D\(on\): query grayscale"

if [ "$(uname)" = "Darwin" ] && [ "$(defaults read com.apple.universalaccess reduceMotion 2>/dev/null || echo 0)" = "1" ] || [ "${RNI_M5:-0}" = "1" ]; then
  mutate "$AM" '    return ReadAccessibilitySettings().reduceMotion;' \
               '    return false;  // MUTANT M5'
  run_mutant "M5 system read skipped" "C: "
else
  echo "--- M5 skipped: the system reads Reduce motion OFF here, so 'always false' is invisible (run on a host with it ON)"
fi

echo
if [ "$PASS" -eq "$TOTAL" ]; then
  echo "MUTATION_VERIFY_REDUCE_MOTION_PASS ($PASS/$TOTAL)"
else
  echo "MUTATION_VERIFY_REDUCE_MOTION_FAIL ($PASS/$TOTAL)"
  exit 1
fi
