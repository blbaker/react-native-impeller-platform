#!/usr/bin/env bash
# Proves tools/ci-unpresented-damage.sh can fail. Each mutant is a copy of
# engine/host/UnpresentedDamage.h with one part of the schedule broken; the
# gate must FAIL on every mutant and PASS on the real header.
#
#   M1 no-progress-reset   the 0.8.1-candidate header: a present does not end
#                          the failure run (PR #35 darwin failure)
#   M2 keep-deadline       a present resets the count but not the pending
#                          backoff deadline
#   M3 no-backoff          every re-ask is immediate (a failing draw spins)
#   M4 reset-every-check   the count never grows (same spin, other wrong fix)
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)" || exit 1

SRC=engine/host/UnpresentedDamage.h
WORK="$(mktemp -d "${TMPDIR:-/tmp}/udm.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
FAILS=0

run() {  # run <name> <expect pass|fail> <header dir>
  local out rc
  out="$(UD_HEADER_DIR="$3" bash tools/ci-unpresented-damage.sh 2>&1)"
  rc=$?
  local first
  first="$(printf '%s\n' "$out" | grep -m1 -E 'FAIL [A-D]|GATE_(PASS|FAIL)' | sed 's/^ *//')"
  if [ "$2" = pass ] && [ $rc -eq 0 ]; then
    echo "  $1: PASS (expected)"
  elif [ "$2" = fail ] && [ $rc -ne 0 ] && printf '%s\n' "$out" | grep -q UNPRESENTED_DAMAGE_GATE_FAIL; then
    echo "  $1: FAIL (caught)  $first"
  else
    echo "  $1: WRONG (expected $2, rc=$rc)  $first"
    FAILS=$((FAILS + 1))
  fi
}

mutant() {  # mutant <name> <perl -0pe expression>
  mkdir -p "$WORK/$1"
  perl -0pe "$2" "$SRC" > "$WORK/$1/UnpresentedDamage.h"
  if cmp -s "$SRC" "$WORK/$1/UnpresentedDamage.h"; then
    echo "  $1: WRONG (the mutation matched nothing; the header changed shape)"
    FAILS=$((FAILS + 1))
    return 1
  fi
}

run head pass engine/host
mutant m1 's/    if \(presentedRevision != lastPresented_\) \{.*?\n    \}\n//s' &&
  run m1-no-progress-reset fail "$WORK/m1"
# shellcheck disable=SC2016  # $1 is perl's capture, not a shell variable
mutant m2 's/(lastPresented_ = presentedRevision;\n      consecutive_ = 0;\n)      retryAtUs_ = 0;\n/$1/' &&
  run m2-keep-deadline fail "$WORK/m2"
mutant m3 's/if \(n <= 2\) return 0;/return 0;/' &&
  run m3-no-backoff fail "$WORK/m3"
mutant m4 's/    \+\+consecutive_;/    consecutive_ = 0;\n    ++consecutive_;/' &&
  run m4-reset-every-check fail "$WORK/m4"
run head-after pass engine/host

if [ "$FAILS" -ne 0 ]; then
  echo "MUTATION_VERIFY_UNPRESENTED_DAMAGE_FAIL ($FAILS wrong)"
  exit 1
fi
echo "MUTATION_VERIFY_UNPRESENTED_DAMAGE_PASS (4 of 4 mutants caught, 2 controls green)"
