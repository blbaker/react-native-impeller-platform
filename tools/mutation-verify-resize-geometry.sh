#!/usr/bin/env bash
# MUTATION TEST for tools/ci-resize-geometry.sh (FP-30). Each mutant edits ENGINE
# SOURCE, rebuilds, and must turn the gate red for its own reason.
#
#   M1  no discard: ShouldDiscard never drops a frame -> A: the old-size frames
#       queued at the resize present on the new window
#   M2  no wait: BeginResize returns at once (no frame produced, no wait) -> A:
#       the resize returns to the OS still showing the old-size frame
#   M3  wait without timeout: the 1 s cap is gone -> B: the platform thread
#       hangs on the hung raster thread (rc 124)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
unset RNI_BIN

RS="engine/host/ResizeSync.cpp"
BACKUP="$(mktemp -d)"
cp "$RS" "$BACKUP/ResizeSync.cpp"
restore() { cp "$BACKUP/ResizeSync.cpp" "$RS"; }
trap 'restore; echo "(engine source restored; rebuild with tools/engine-build.sh)" >&2' EXIT

build() { bash tools/engine-build.sh linux x64 > "$1" 2>&1 || { tail -20 "$1" >&2; echo "MUTATE_FAIL: build failed" >&2; exit 1; }; }
gate()  { bash tools/ci-resize-geometry.sh > "$1" 2>&1; }

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
  if grep -q 'RESIZE_GEOMETRY_PASS' "$2" || ! grep -q 'RESIZE_GEOMETRY_FAIL' "$2"; then
    echo "MUTATE_FAIL: $1 SURVIVED -- ci-resize-geometry stayed GREEN" >&2; tail -5 "$2" >&2; exit 1
  fi
  grep -qE "$3" "$2" || { echo "MUTATE_FAIL: $1 killed for the WRONG reason:" >&2; grep -m3 FAIL "$2" >&2; exit 1; }
  echo "   $1 killed: $(grep -m1 -E "$3" "$2" | cut -c1-220)"
}

echo "== M1: no stale-size discard =="
mutate "$RS" '  if (expected == 0 || expected == Pack(w, h)) return false;' \
'  if (true) return false;  // MUTANT M1: never discard'
build "$BACKUP/m1-build.log"; gate "$BACKUP/m1.log" || true
expect_killed M1 "$BACKUP/m1.log" 'A: stale-size frame presented: present [0-9]+ is [0-9]+x[0-9]+ on a [0-9]+x[0-9]+ window'
restore

echo "== M2: no resize wait =="
mutate "$RS" '  if (!didReceiveFrame_.load(std::memory_order_acquire)) {' \
'  if (true) {  // MUTANT M2: return to the OS at once'
build "$BACKUP/m2-build.log"; gate "$BACKUP/m2.log" || true
expect_killed M2 "$BACKUP/m2.log" 'A: resize [0-9]+ returned to the OS showing a [0-9]+x[0-9]+ frame on a [0-9]+x[0-9]+ window'
restore

echo "== M3: resize wait without its 1 s timeout =="
mutate "$RS" '      if (std::chrono::steady_clock::now() > deadline) {' \
'      if (false && std::chrono::steady_clock::now() > deadline) {  // MUTANT M3: no cap'
build "$BACKUP/m3-build.log"; gate "$BACKUP/m3.log" || true
expect_killed M3 "$BACKUP/m3.log" 'B: hang: the platform thread waited for the resize frame without a timeout \(rc 124\)'
restore

echo "== RESTORE: clean engine must be GREEN =="
build "$BACKUP/final-build.log"
gate "$BACKUP/final.log" || { tail -15 "$BACKUP/final.log" >&2; echo "MUTATE_FAIL: gate RED after restore" >&2; exit 1; }
echo "   $(tail -1 "$BACKUP/final.log")"
trap - EXIT
rm -rf "$BACKUP"
echo "MUTATION_VERIFY_RESIZE_GEOMETRY_PASS"
