#!/usr/bin/env bash
# Run a list of node-free gates against an engine (RNI_BIN), one log per gate,
# and print a PASS/FAIL summary. Usage: arm64-gates.sh <label> <gate> [gate...]
#   RNI_BIN=$PWD/tools/arm64-run-engine.sh bash tools/arm64-gates.sh arm64 style-audit supersample
set -uo pipefail
cd "$(dirname "$0")/.."
LABEL="$1"; shift
OUT="${GATES_OUT:-${TMPDIR:-/tmp}/arm64-gates/$LABEL}"
mkdir -p "$OUT"
: > "$OUT/summary.txt"
for g in "$@"; do
  t0=$(date +%s)
  timeout "${GATE_TIMEOUT:-1200}" bash "tools/ci-$g.sh" > "$OUT/$g.log" 2>&1
  rc=$?
  verdict=$( [ $rc -eq 0 ] && echo PASS || echo "FAIL(rc=$rc)" )
  line="$(printf '%-22s %-12s %4ss  %s' "$g" "$verdict" "$(( $(date +%s) - t0 ))" "$(grep -E '_PASS|_FAIL|PASS|FAIL' "$OUT/$g.log" | tail -1 | cut -c1-110)")"
  echo "$line" | tee -a "$OUT/summary.txt"
done
echo "DONE $LABEL" >> "$OUT/summary.txt"
