#!/usr/bin/env bash
# The lost-frame re-ask schedule (engine/host/UnpresentedDamage.h), replayed
# on a simulated clock. CPU only: no engine build, no GPU, no window.
#
# Why this exists next to ci-idle-commit-paint.sh: that gate drives the real
# window, so it only sees an ordering when the runner's timing produces it.
# On PR #35 (darwin run 39537571277) a JS commit landed while the loop was
# still parked after a present, the backoff count carried into the next
# commit's losses, and a fresh loss waited 730 ms. The PR #33 run had the
# other timing and was green on the same code. This gate replays both
# orderings, plus the no-spin backoff, every time.
#
#   UD_HEADER_DIR=<dir>  compile against <dir>/UnpresentedDamage.h instead
#                        (mutation-verify-unpresented-damage.sh uses this)
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)" || exit 1

HDR_DIR="${UD_HEADER_DIR:-engine/host}"
CXX="${CXX:-c++}"
if ! command -v "$CXX" >/dev/null 2>&1; then
  echo "UNPRESENTED_DAMAGE_GATE_FAIL: no C++ compiler ($CXX)"
  exit 1
fi
[ -f "$HDR_DIR/UnpresentedDamage.h" ] || {
  echo "UNPRESENTED_DAMAGE_GATE_FAIL: $HDR_DIR/UnpresentedDamage.h missing"
  exit 1
}

OUT="$(mktemp -d "${TMPDIR:-/tmp}/udg.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT

if ! "$CXX" -std=c++17 -O1 -Wall -Werror -I "$HDR_DIR" tools/unpresented-damage-test.cpp \
    -o "$OUT/udg" > "$OUT/build.log" 2>&1; then
  sed 's/^/  | /' "$OUT/build.log" | tail -20
  echo "UNPRESENTED_DAMAGE_GATE_FAIL: test did not compile"
  exit 1
fi
"$OUT/udg"
