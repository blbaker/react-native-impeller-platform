#!/usr/bin/env bash
# MUTATION TEST for tools/ci-vsync.sh (FP-11). Each mutant edits ENGINE SOURCE
# (engine/host/FrameScheduler.cpp), rebuilds, and must turn the gate red for
# its own reason.
#
#   M1  free-running: swap interval 0 and no software clock (the probe picks
#       kFree instead of kSoftware) -> arm A (pacing)
#   M2  dedupe removed: every RequestFrame queues its own BeginFrame, so the
#       NativeAnimated continuation plus the damage wake double the frames
#       -> arm B (double frames)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SRC="engine/host/FrameScheduler.cpp"
BACKUP="$(mktemp -d)"
cp "$SRC" "$BACKUP/FrameScheduler.cpp"
restore() { cp "$BACKUP/FrameScheduler.cpp" "$SRC"; }
trap 'restore; echo "(engine source restored; rebuild with tools/engine-build.sh)" >&2' EXIT

build() { bash tools/engine-build.sh linux x64 > "$1" 2>&1 || { tail -20 "$1" >&2; echo "MUTATE_FAIL: build failed" >&2; exit 1; }; }
gate()  { RNI_BIN="$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller" bash tools/ci-vsync.sh > "$1" 2>&1; }

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
  if grep -q 'VSYNC PASS' "$2" || ! grep -q 'VSYNC FAIL' "$2"; then
    echo "MUTATE_FAIL: $1 SURVIVED -- ci-vsync stayed GREEN" >&2; exit 1
  fi
  grep -qE "$3" "$2" || { echo "MUTATE_FAIL: $1 killed for the WRONG reason:" >&2; grep -m3 'FAIL' "$2" >&2; exit 1; }
  echo "   $1 killed: $(grep -m1 -E "$3" "$2" | sed 's/^ *//' | cut -c1-200)"
}

echo "== M1: swap interval 0 + no software clock (free-running) =="
# FP-15 made the constructor read options.source into a local `src`.
mutate "$SRC" '  const int interval = src == Source::kFree || src == Source::kSoftware ? 0 : 1;' \
  '  const int interval = 0;  // MUTANT M1'
mutate "$SRC" '    source_ = Source::kSoftware;' '    source_ = Source::kFree;  // MUTANT M1'
build "$BACKUP/m1-build.log"; gate "$BACKUP/m1.log" || true
expect_killed M1 "$BACKUP/m1.log" 'VSYNC FAIL A pacing'
restore

echo "== M2: RequestFrame dedupe removed (double frames) =="
mutate "$SRC" '  if (!pending_.compare_exchange_strong(expected, 1, std::memory_order_acq_rel)) {' \
  '  if (pending_.fetch_add(1, std::memory_order_acq_rel) < expected) {  // MUTANT M2'
build "$BACKUP/m2-build.log"; gate "$BACKUP/m2.log" || true
expect_killed M2 "$BACKUP/m2.log" 'VSYNC FAIL B double frames'
restore

echo "== RESTORE: clean engine must be GREEN =="
build "$BACKUP/final-build.log"
gate "$BACKUP/final.log" || { tail -15 "$BACKUP/final.log" >&2; echo "MUTATE_FAIL: gate RED after restore" >&2; exit 1; }
echo "   $(grep -m1 'A: median' "$BACKUP/final.log" | sed 's/^ *//')"
trap - EXIT
rm -rf "$BACKUP"
echo "MUTATE_VSYNC_OK -- 2 mutants, 2 killed, engine restored and green"
