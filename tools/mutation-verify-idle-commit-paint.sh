#!/usr/bin/env bash
# MUTATION VERIFY for ci-idle-commit-paint.sh's lost-frame arm.
#
# The arm (ICP_LOSE_FRAMES=N) loses each swap's own frame after its request
# was consumed, the way a nil Metal drawable or a failed draw loses it. The fix
# (host/UnpresentedDamage.h) has three parts, each with a runtime mutant
# (--idle-mutant N, no rebuild):
#
#   M4 no re-ask at all (the 0.6.0 loop)           -> swap stays off screen
#   M5 a lost frame counts as presented            -> loop thinks it is caught up
#   M6 a lost frame does not wake the parked loop  -> re-ask waits out the
#                                                     1000 ms idle budget
#
# Each must FAIL the arm, for the on-screen reason. Controls:
#   HEAD with the loss                -> PASS (the fix recovers)
#   M4 WITHOUT the loss               -> PASS (M4 breaks nothing else, so its
#                                        failure above is the lost frame's)
# Then HEAD once more, so a run that left something behind is caught.
#
# Linux: needs an X display (DISPLAY=:95 from a private Xvfb is fine).
# Mac (no npm): RNI_BIN=<darwin rn-impeller> bash tools/mutation-verify-idle-commit-paint.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
GATE="tools/ci-idle-commit-paint.sh"
LOSE="${ICP_LOSE_FRAMES:-1}"
MODE="${ICP_MODE:-light}"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/mv-icp.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT

run() {  # $1 name, $2 lose count (0 = no loss), $3 extra engine flags
  local name="$1" lose="$2" extra="$3"
  ICP_MODE="$MODE" ICP_LOSE_FRAMES="$lose" ICP_EXTRA_FLAGS="$extra" \
    bash "$GATE" > "$OUT/$name.log" 2>&1
  local rc=$?
  if grep -q 'IDLE_COMMIT_PAINT SKIP' "$OUT/$name.log"; then
    echo "MUTATION_VERIFY INCONCLUSIVE: the gate SKIPPED ($name: no X display)"
    exit 2
  fi
  return $rc
}

verdict() { grep -m1 '^VERDICT' "$OUT/$1.log" || echo "(no verdict)"; }
fails=0
expect_pass() {
  if run "$1" "$2" "$3"; then
    echo "  $1: PASS (expected)  $(verdict "$1")"
  else
    echo "  $1: FAIL (expected PASS)  $(verdict "$1")"
    grep -E 'swap [0-9]|lost frames|unpresented|test_lost' "$OUT/$1.log" | head -12 | sed 's/^/    /'
    fails=$((fails + 1))
  fi
}
expect_fail() {  # $4 = the verdict text that names the right reason
  if run "$1" "$2" "$3"; then
    echo "  $1: PASS (SURVIVED: the gate cannot see this mutant)  $(verdict "$1")"
    fails=$((fails + 1))
  elif grep -q "$4" "$OUT/$1.log"; then
    echo "  $1: FAIL (caught)  $(verdict "$1")"
  else
    echo "  $1: FAIL but for another reason  $(verdict "$1")"
    fails=$((fails + 1))
  fi
}

echo "== mode=$MODE lose=$LOSE =="
expect_pass head-loss "$LOSE" ""
expect_pass m4-noloss 0 "--idle-mutant 4"
expect_fail m4-loss "$LOSE" "--idle-mutant 4" "were not on screen"
expect_fail m5-loss "$LOSE" "--idle-mutant 5" "were not on screen"
expect_fail m6-loss "$LOSE" "--idle-mutant 6" "were not on screen"
expect_pass head-after "$LOSE" ""

if [ "$fails" -eq 0 ]; then
  echo "MUTATION_VERIFY_IDLE_COMMIT_PAINT PASS (3 of 3 mutants caught, 3 controls green)"
  exit 0
fi
echo "MUTATION_VERIFY_IDLE_COMMIT_PAINT FAIL ($fails check(s) wrong)"
exit 1
