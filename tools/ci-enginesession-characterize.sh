#!/usr/bin/env bash
# Characterization gate for the EngineSession extraction
# (refactor/engine-session): proves `tools/ci-all.sh` behaves identically
# before and after the refactor, modulo fields that vary from run to run for
# reasons that have nothing to do with the code under test (see
# tools/enginesession-normalize.sh / .sed for exactly which fields and why).
#
# Usage:
#   DISPLAY=:94 bash tools/ci-enginesession-characterize.sh [BEFORE_LOG]
#
# With no argument, diffs against the committed pre-refactor snapshot at
# tools/testdata/ci-all-enginesession-before.log. That snapshot is a
# ONE-TIME artifact of THIS refactor's own proof, not a standing output
# contract: a later, unrelated change to ci-all.sh's own output (a new
# gate, a changed pixel assertion) will legitimately change what ci-all.sh
# prints, and comparing against a frozen pre-refactor log forever after
# would make this script a maintenance trap, not a regression gate --
# which is why it is not wired into .github/workflows/ci.yml. Use the
# explicit-argument form for a later refactor of this kind:
#   git stash && DISPLAY=:94 bash tools/engine-build.sh linux x64 && \
#     DISPLAY=:94 bash tools/ci-all.sh > /tmp/before.log   # parent commit
#   git stash pop && DISPLAY=:94 bash tools/engine-build.sh linux x64
#   DISPLAY=:94 bash tools/ci-enginesession-characterize.sh /tmp/before.log
# That is "the approach that works in CI": it needs no committed golden
# file that silently drifts stale, and it is exactly how this script was
# used to prove the EngineSession extraction itself (see the commit that
# added tools/testdata/ci-all-enginesession-before.log).
#
# Pass line: ENGINESESSION_CHARACTERIZE_PASS
set -euo pipefail
cd "$(dirname "$0")/.."

BEFORE_LOG="${1:-tools/testdata/ci-all-enginesession-before.log}"
[ -f "$BEFORE_LOG" ] || {
  echo "ENGINESESSION_CHARACTERIZE_FAIL: no before-log at $BEFORE_LOG" >&2
  exit 1
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "ci-enginesession-characterize: running ci-all.sh (this takes a while)"
AFTER_LOG="$WORK/ci-all-after.log"
if ! bash tools/ci-all.sh > "$AFTER_LOG" 2>&1; then
  echo "ENGINESESSION_CHARACTERIZE_FAIL: ci-all.sh itself failed" >&2
  tail -40 "$AFTER_LOG" >&2
  exit 1
fi

bash tools/enginesession-normalize.sh < "$BEFORE_LOG" > "$WORK/before.norm"
bash tools/enginesession-normalize.sh < "$AFTER_LOG" > "$WORK/after.norm"

if diff -u "$WORK/before.norm" "$WORK/after.norm" > "$WORK/diff.txt"; then
  echo "ENGINESESSION_CHARACTERIZE_PASS"
  exit 0
fi

echo "ENGINESESSION_CHARACTERIZE_FAIL: ci-all.sh output differs after normalization" >&2
cat "$WORK/diff.txt" >&2
exit 1
