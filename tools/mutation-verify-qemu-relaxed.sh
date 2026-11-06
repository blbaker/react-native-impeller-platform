#!/usr/bin/env bash
# MUTATION TEST for the qemu relaxations (tools/lib/qemu-timing.sh): a gate
# relaxed for qemu-aarch64 must still FAIL there on the defect it exists for.
#   Q1  ci-first-present (boot clock x20 + RNI_TIME_SCALE=20 under qemu): the
#       D-156 regression (windowed boot back to waitForJsIdle, the M1 of
#       tools/mutation-verify-first-present.sh) built into a SCRATCH arm64
#       package -> the qemu-relaxed gate must FAIL with "first frame is HOME".
# Control: the staged arm64 package passes the same qemu-relaxed gate, and the
# restored source rebuilds byte-identical to it. The staged package is never
# touched. Restore = cp + touch. Windows go to a private Xvfb (xvfb-run -a).
# The other relaxations only lengthen waits/timeouts (ci-exit-race, ci-scroll)
# or start the rn-core animation later (ci-rn-core anim, plus an ordering
# check); their assertions are unchanged, and their own mutation suites apply.
set -euo pipefail
cd "$(dirname "$0")/.."
. tools/lib/arm64-scratch-stage.sh
fail() { echo "QEMU_RELAXED_MUTATION_FAIL: $*"; exit 1; }
MAIN=engine/host/main.cpp
OLD='host.waitForJsQueueDrained(rni::testsync::ScaledMs(10000))'
NEW='host.waitForJsIdle(rni::testsync::ScaledMs(10000))'
W="$(mktemp -d "${TMPDIR:-/tmp}/mv-qemu-relaxed.XXXXXX")"
cp "$MAIN" "$W/main.cpp"
restore() { cmp -s "$W/main.cpp" "$MAIN" || { cp "$W/main.cpp" "$MAIN"; touch "$MAIN"; }; }
trap 'restore; [ "${KEEP_WORKDIR:-0}" = 1 ] && echo "workdir kept: $W" || rm -rf "$W"' EXIT
gate() {  # <bin-dir> <log>: the qemu-relaxed first-present gate on that arm64 package
  local rc=0
  RNI_BIN="$PWD/tools/arm64-run-engine.sh" RNI_ARM64_ENGINE_DIR="$1" RNI_ARM64_HOST_FONTS=1 \
    xvfb-run -a -s "-screen 0 1280x1024x24 -nolisten tcp" timeout 1200 bash tools/ci-first-present.sh > "$2" 2>&1 || rc=$?
  return "$rc"
}

echo "== control: staged arm64 package, qemu-relaxed ci-first-present =="
gate "$ARM64_PKGBIN" "$W/control.log" || { tail -6 "$W/control.log"; fail "control: the staged package fails the qemu-relaxed gate"; }
grep -q '^QEMU_TIMING_RELAXED: first-present' "$W/control.log" || fail "control: the gate did not take the qemu path"
echo "   $(grep -o 'FIRST_PRESENT_GATE_PASS.*' "$W/control.log")"

echo "== Q1: windowed boot waits for JS idle again (D-156), arm64 scratch package =="
python3 - "$MAIN" "$OLD" "$NEW" <<'PY' || fail "Q1 anchor not found"
import sys
p, a, b = sys.argv[1:4]
s = open(p).read()
if s.count(a) != 2:
    sys.exit(f"anchor found {s.count(a)}x, expected 2 (bundle + surface drain)")
open(p, "w").write(s.replace(a, b))
PY
touch "$MAIN"
arm64_stage "$W/q1" "$W/build-q1.log" || { restore; fail "Q1 build"; }
restore
arm64_same_as_staged "$W/q1" && fail "Q1: mutant binary identical to the staged one (not compiled in)"
if gate "$W/q1/bin" "$W/q1.log"; then tail -6 "$W/q1.log"; fail "Q1 SURVIVED the qemu-relaxed gate"; fi
grep -q 'FIRST_PRESENT_GATE_FAIL: first frame is HOME' "$W/q1.log" \
  || { tail -6 "$W/q1.log"; fail "Q1 killed by the wrong assertion"; }
echo "   killed: $(grep -o 'FIRST_PRESENT_GATE_FAIL.*' "$W/q1.log" | cut -c1-140)"

echo "== restored source rebuilds byte-identical to the staged package =="
arm64_stage "$W/restored" "$W/build-restored.log" || fail "restored build"
arm64_same_as_staged "$W/restored" || fail "restored: differs from the staged package"
echo "QEMU_RELAXED_MUTATION_PASS (Q1 D-156 regression killed under qemu by 'first frame is HOME'; control passes; restored == staged)"
