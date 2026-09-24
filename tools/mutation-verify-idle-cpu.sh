#!/usr/bin/env bash
# MUTATION VERIFY for ci-idle-cpu.sh (P12-01).
#
# Proves the idle-CPU gate can actually FAIL — a gate only watched PASS is not a
# gate. The three mutants are wired into RunWindowed's loop as runtime flags
# (--idle-mutant N) rather than source edits, so this script just runs the gate
# under each and asserts it goes RED for the RIGHT reason:
#
#   M1 always-dirty          -> repaints every frame -> idle %CPU high    (arm A)
#   M2 skip paint, keep poll -> busy-spins on the non-blocking poll       (arm A)
#                               (proves the SLEEP, not the paint-skip, drops CPU)
#   M3 never post the wake   -> off-thread bump stalls the full budget    (arm B)
#
# ⛔ HEAD MUST PASS FIRST. If HEAD does not pass, a red mutant proves nothing —
# the gate could be failing for an unrelated reason. And on a box with no real
# display the gate SKIPs (exit 0), so a mutant would also "pass"; detect the SKIP
# and refuse to certify, rather than reporting a false green.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
GATE="tools/ci-idle-cpu.sh"

run_gate() {  # $1 = IDLE_MUTANT (empty=HEAD); prints log to $2
  local mut="$1" out="$2"
  if [ -n "$mut" ]; then
    IDLE_MUTANT="$mut" bash "$GATE" > "$out" 2>&1 && return 0 || return 1
  else
    bash "$GATE" > "$out" 2>&1 && return 0 || return 1
  fi
}

OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT

echo "== HEAD must PASS =="
if run_gate "" "$OUT/head.log"; then
  if grep -q 'IDLE_CPU SKIP' "$OUT/head.log"; then
    echo "MUTATION_VERIFY INCONCLUSIVE: gate SKIPPED (no real display)."
    echo "  Idle-CPU is unmeasurable headless; run this on a box with DISPLAY=:0."
    tail -4 "$OUT/head.log"
    exit 2
  fi
  echo "  HEAD PASS"
else
  echo "MUTATION_VERIFY FAIL: HEAD did not pass the gate — fix that before trusting a mutant."
  tail -20 "$OUT/head.log"; exit 1
fi

# Each mutant MUST make the gate exit non-zero.
declare -A WHY=(
  [1]="always-dirty: idle CPU must exceed the budget (repaints every frame)"
  [2]="skip paint but keep the non-blocking poll: must busy-spin (the sleep is the fix)"
  [3]="never post the wake: off-thread bump must stall the full budget"
)
FAILED=0
for M in 1 2 3; do
  echo "== M$M: ${WHY[$M]} =="
  if run_gate "$M" "$OUT/m$M.log"; then
    echo "  SURVIVED — the gate PASSED with mutant M$M live. The gate is blind here."
    tail -12 "$OUT/m$M.log"
    FAILED=1
  else
    # Confirm it died on the intended arm, not an unrelated error.
    case "$M" in
      1|2) grep -q 'exceeds\|spinning\|idle-skip never engaged' "$OUT/m$M.log" \
             && echo "  CAUGHT (arm A: CPU)" \
             || { echo "  died but NOT on the CPU arm:"; tail -8 "$OUT/m$M.log"; FAILED=1; } ;;
      3)   grep -q 'off-thread repaint witness\|wake not posted\|stalled' "$OUT/m$M.log" \
             && echo "  CAUGHT (arm B: off-thread witness)" \
             || { echo "  died but NOT on the witness arm:"; tail -8 "$OUT/m$M.log"; FAILED=1; } ;;
    esac
  fi
done

if [ "$FAILED" = "0" ]; then
  echo "MUTATION_VERIFY PASS (HEAD green; M1/M2 caught on CPU, M3 caught on the off-thread witness)"
else
  echo "MUTATION_VERIFY FAIL (a mutant survived or died on the wrong arm — see above)"
  exit 1
fi
