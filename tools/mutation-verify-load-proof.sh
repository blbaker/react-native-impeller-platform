#!/usr/bin/env bash
# MUTATION TEST for FP-06 (tools/ci-load-proof.sh and the frame-synchronous ci-scroll it relies on).
# Each arm runs tools/ci-scroll.sh on the plain staged binary while a CPU hog loads every core
# (tools/lib/cpu-hog.sh) and RNI_TEST_FRAME_DELAY_MS stretches every windowed loop iteration
# (base/TestSync.h). The hog alone made the old deadline lose its race only sometimes (2 merge
# runs under ASan); the frame delay makes the slow box deterministic so a mutant cannot survive
# by luck.
#   C   control: the clean gate PASSES under the same hog + frame delay (the frame-synchronous
#       capture is what makes it pass)
#   M1  ci-scroll's B/C/D capture goes back to the fixed deadline it had before FP-06
#       (--frames 400 --screenshot-after 60 ms from process start): the capture lands before
#       the scroll's frame -> "two notches down is a 80pt offset ..."
#   M2  the engine's frame-wait never waits: --screenshot-after-frames N captures the first
#       painted frame whatever N is -> B/C/D read the resting frame and fail, fast (no ceiling)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
. tools/lib/cpu-hog.sh
DELAY_MS="${LOAD_PROOF_FRAME_DELAY_MS:-25}"
GATE="tools/ci-scroll.sh"
ENG="engine/host/main.cpp"
BACKUP="$(mktemp -d)"
cp "$GATE" "$BACKUP/ci-scroll.sh"; cp "$ENG" "$BACKUP/main.cpp"
restore() { cp "$BACKUP/ci-scroll.sh" "$GATE"; cp "$BACKUP/main.cpp" "$ENG"; }
trap 'hog_stop; restore; echo "(sources restored; rebuild with tools/engine-build.sh)" >&2' EXIT

build() { bash tools/engine-build.sh linux x64 > "$1" 2>&1 || { tail -20 "$1" >&2; echo "MUTATE_FAIL: build failed" >&2; exit 1; }; }
gate() {  # log -> sets GATE_RC, GATE_SEC
  local t0; t0=$(date +%s)
  hog_alive || { echo "MUTATE_FAIL: the CPU hog is not running" >&2; exit 1; }
  set +e
  env -u RNI_BIN RNI_TEST_FRAME_DELAY_MS="$DELAY_MS" bash "$GATE" > "$1" 2>&1; GATE_RC=$?
  set -e
  GATE_SEC=$(( $(date +%s) - t0 ))
  hog_alive || { echo "MUTATE_FAIL: the CPU hog died during the run" >&2; exit 1; }
}
mutate() {  # file old new
  python3 - "$1" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
n = s.count(old)
assert n == 1, "anchor found %dx in %s" % (n, p)
open(p, "w").write(s.replace(old, new, 1))
PY
}
expect_killed() {  # name log ERE
  if [ "$GATE_RC" = 0 ] || grep -q 'SCROLL_GATE_PASS' "$2"; then
    echo "MUTATE_FAIL: $1 SURVIVED -- ci-scroll stayed GREEN under the hog" >&2; exit 1
  fi
  grep -qE "$3" "$2" || { echo "MUTATE_FAIL: $1 killed for the WRONG reason:" >&2; grep -m3 'FAIL' "$2" >&2; exit 1; }
  echo "   $1 killed in ${GATE_SEC}s: $(grep -m1 -E "$3" "$2" | sed 's/^ *//' | cut -c1-220)"
}

echo "== build the clean engine, start the hog =="
build "$BACKUP/build-clean.log"
hog_start
sleep 1
echo "   hog: $HOG_KIND; frame delay ${DELAY_MS} ms per windowed loop iteration"

echo "== C: the clean frame-synchronous gate passes under the hog =="
gate "$BACKUP/c.log"
[ "$GATE_RC" = 0 ] && grep -q 'SCROLL_GATE_PASS' "$BACKUP/c.log" \
  || { grep -E 'FAIL|OK' "$BACKUP/c.log" | tail -8 >&2; echo "MUTATE_FAIL: the CLEAN ci-scroll failed under the hog + ${DELAY_MS} ms frames" >&2; exit 1; }
C_SEC=$GATE_SEC
echo "   C passed in ${C_SEC}s: $(tail -1 "$BACKUP/c.log" | cut -c1-120)"

echo "== M1: ci-scroll captures at a fixed 60 ms deadline again =="
mutate "$GATE" '              --width "$WIN_W" --height "$WIN_H" --frames "$RUN_FRAMES" \' \
  '              --width "$WIN_W" --height "$WIN_H" --frames 400 \'
mutate "$GATE" '              --screenshot "$shot" --screenshot-after-frames "$SHOT_FRAME" > "$log" 2>&1' \
  '              --screenshot "$shot" --screenshot-after 60 > "$log" 2>&1  # MUTANT M1'
gate "$BACKUP/m1.log"
expect_killed M1 "$BACKUP/m1.log" 'SCROLL_GATE_FAIL: two notches down is a 80pt offset'
restore

echo "== M2: the engine's frame-anchored capture never waits =="
mutate "$ENG" '        gScreenshotAfterFrames < 0 || frameIndex >= gScreenshotAfterFrames;' \
  '        true;  // MUTANT M2: the frame-wait never waits'
build "$BACKUP/build-m2.log"
gate "$BACKUP/m2.log"
expect_killed M2 "$BACKUP/m2.log" 'SCROLL_GATE_FAIL: (two notches down is a 80pt offset|every sampled row is identical)'
# fail fast: the never-waiting wait must not turn into a ceiling-length hang
[ "$GATE_SEC" -le $(( C_SEC + 60 )) ] \
  || { echo "MUTATE_FAIL: M2 failed only after ${GATE_SEC}s (clean run ${C_SEC}s): a hang, not a fast failure" >&2; exit 1; }
restore

hog_stop
echo "== RESTORE: clean engine rebuilt =="
build "$BACKUP/build-final.log"
trap - EXIT
rm -rf "$BACKUP"
echo "MUTATE_LOAD_PROOF_OK -- control green under the hog, 2 mutants, 2 killed, sources restored"
