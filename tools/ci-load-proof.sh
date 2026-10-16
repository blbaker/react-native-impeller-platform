#!/usr/bin/env bash
# FP-06 GATE: the sanitizer suites pass under load.
# The merge job's ASan run failed ci-scroll twice while two lanes kept the box busy (a capture
# deadline in ms landed before the scroll's frame), though the plain binary passed. FP-06 made the
# windowed/XTest gates frame-synchronous (engine-reported events + RNI_TIME_SCALE ceilings) and the
# timing gates relative to a control arm run under the same load. This gate proves it:
#   1. builds the ASan+UBSan and TSan binaries (before the hog, so the hog loads the gates, not ninja)
#   2. starts a CPU hog on every core (stress-ng --cpu, else busy python loops; tools/lib/cpu-hog.sh)
#      and proves it loads the box: >= 85% of all CPU time busy over a 2 s sample
#   3. tools/ci-sanitize.sh and tools/ci-tsan.sh each pass LOAD_PROOF_ROUNDS (3) times in a row with
#      the hog alive for the whole of every run (a run that outlived its hog proves nothing)
# Env: LOAD_PROOF_ROUNDS, LOAD_PROOF_SUITES (default both suites), RNI_HOG_WORKERS (default nproc).
set -uo pipefail
cd "$(dirname "$0")/.."
. tools/lib/cpu-hog.sh
ROUNDS="${LOAD_PROOF_ROUNDS:-3}"
read -r -a SUITES <<<"${LOAD_PROOF_SUITES:-tools/ci-sanitize.sh tools/ci-tsan.sh}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ci-load-proof.XXXX")"
fail() { echo "LOAD_PROOF_FAIL: $*"; exit 1; }
trap 'hog_stop' EXIT

# Busy share of all CPU time over $1 seconds, in percent (from /proc/stat).
busy_pct() {
  local a b
  a="$(head -1 /proc/stat)"; sleep "$1"; b="$(head -1 /proc/stat)"
  awk -v a="$a" -v b="$b" 'BEGIN {
    na = split(a, x); split(b, y); tot = 0; idle = 0
    for (i = 2; i <= na; i++) tot += y[i] - x[i]
    idle = (y[5] - x[5]) + (y[6] - x[6])
    printf "%d\n", (tot > 0) ? 100 * (tot - idle) / tot : 0 }'
}

echo "== 1. build the instrumented binaries (no hog yet)"
for s in "${SUITES[@]}"; do
  bash "$s" --build-only > "$WORK/build-$(basename "$s" .sh).log" 2>&1 \
    || { tail -15 "$WORK/build-$(basename "$s" .sh).log"; fail "$s --build-only failed"; }
  echo "built: $s"
done

echo "== 2. CPU hog"
hog_start
sleep 1
hog_alive || fail "the hog did not start ($HOG_KIND)"
BUSY="$(busy_pct 2)"
echo "hog: $HOG_KIND, box busy ${BUSY}% over 2 s"
[ "$BUSY" -ge 85 ] || fail "the hog loads only ${BUSY}% of the box (< 85%): this run would not prove anything about load"

echo "== 3. suites x$ROUNDS under the hog (RNI_TIME_SCALE=${RNI_TIME_SCALE:-4 from the suites})"
for s in "${SUITES[@]}"; do
  n="$(basename "$s" .sh)"
  for r in $(seq "$ROUNDS"); do
    t0=$(date +%s)
    bash "$s" > "$WORK/$n-$r.log" 2>&1; rc=$?
    dt=$(( $(date +%s) - t0 ))
    if [ "$rc" != 0 ]; then
      grep -E '^(ok|SANITIZE_FAIL|TSAN_FAIL)|FAIL' "$WORK/$n-$r.log" | tail -12
      fail "$s round $r of $ROUNDS failed under the hog after ${dt}s (log $WORK/$n-$r.log)"
    fi
    hog_alive || fail "the hog died during $s round $r: that round was not under load"
    echo "ok $s round $r/$ROUNDS ${dt}s: $(tail -1 "$WORK/$n-$r.log" | cut -c1-120)"
  done
done
BUSY_END="$(busy_pct 2)"
hog_stop
echo "LOAD_PROOF_PASS (${SUITES[*]} each ${ROUNDS}x in a row under $HOG_KIND; busy ${BUSY}% at start, ${BUSY_END}% at end)"
