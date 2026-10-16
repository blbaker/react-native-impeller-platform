#!/usr/bin/env bash
# MUTATION TEST for tools/ci-raster-thread.sh (FP-15). Each mutant edits ENGINE
# SOURCE, rebuilds, and must turn the gate red for its own reason.
#
#   M1  raster runs on the main thread again (the raster runner is the
#       platform thread, Flutter's merged-thread mode) -> A: the queued frame
#       presents BEFORE main's stall begins
#   M2  pipeline depth 0: Consume only hands out an item once the next one is
#       queued behind it (no buffered frame), so the raster thread waits for the
#       next record -> A: the queued frame presents only after the stall ends
#   M3  teardown destroys the context before joining the raster thread (the GPU
#       objects are released on main, then the raster thread is joined)
#       -> GPU objects released with no GL context current (the gpu_release
#       read-back is checked before the exit code; the mutant also segfaults)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
unset RNI_BIN

RT="engine/host/RasterThread.cpp"
WR="engine/host/WindowRasterizer.cpp"
PL="engine/host/Pipeline.h"
BACKUP="$(mktemp -d)"
cp "$RT" "$BACKUP/RasterThread.cpp"
cp "$WR" "$BACKUP/WindowRasterizer.cpp"
cp "$PL" "$BACKUP/Pipeline.h"
restore() { cp "$BACKUP/RasterThread.cpp" "$RT"; cp "$BACKUP/WindowRasterizer.cpp" "$WR"; cp "$BACKUP/Pipeline.h" "$PL"; }
trap 'restore; echo "(engine source restored; rebuild with tools/engine-build.sh)" >&2' EXIT

build() { bash tools/engine-build.sh linux x64 > "$1" 2>&1 || { tail -20 "$1" >&2; echo "MUTATE_FAIL: build failed" >&2; exit 1; }; }
gate()  { bash tools/ci-raster-thread.sh > "$1" 2>&1; }

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
  if grep -q 'RASTER_THREAD_PASS' "$2" || ! grep -q 'RASTER_THREAD_FAIL' "$2"; then
    echo "MUTATE_FAIL: $1 SURVIVED -- ci-raster-thread stayed GREEN" >&2; tail -5 "$2" >&2; exit 1
  fi
  grep -qE "$3" "$2" || { echo "MUTATE_FAIL: $1 killed for the WRONG reason:" >&2; grep -m3 -E 'FAIL|^A' "$2" >&2; exit 1; }
  echo "   $1 killed: $(grep -m1 -E "$3" "$2" | sed 's/^ *//' | cut -c1-220)"
}

echo "== M1: raster runs on the main thread again =="
mutate "$RT" 'RasterThread::RasterThread(bool threaded) : threaded_(threaded) {' \
'RasterThread::RasterThread(bool threaded) : threaded_(false && threaded) {  // MUTANT M1'
build "$BACKUP/m1-build.log"; gate "$BACKUP/m1.log" || true
expect_killed M1 "$BACKUP/m1.log" '^A: the queued frame presented [0-9.]+ ms BEFORE the stall began'
restore

echo "== M2: pipeline depth 0 (raster waits for the next record) =="
mutate "$PL" '      if (queue_.empty()) return PipelineConsumeResult::kNoneAvailable;' \
'      if (queue_.size() < 2) return PipelineConsumeResult::kNoneAvailable;  // MUTANT M2: no buffered item'
build "$BACKUP/m2-build.log"; gate "$BACKUP/m2.log" || true
expect_killed M2 "$BACKUP/m2.log" '^A: the queued frame presented [0-9.]+ ms after the stall began, past its'
restore

echo "== M3: teardown destroys the context before joining the raster thread =="
mutate "$WR" '      surface_.releaseGpu();
    }
  });
  raster_.Join();' '    }
  });
  if (started_) surface_.releaseGpu();  // MUTANT M3: on main, before the join
  raster_.Join();'
build "$BACKUP/m3-build.log"; gate "$BACKUP/m3.log" || true
expect_killed M3 "$BACKUP/m3.log" 'GPU objects released with NO GL context current'
restore

echo "== RESTORE: clean engine must be GREEN =="
build "$BACKUP/final-build.log"
gate "$BACKUP/final.log" || { tail -15 "$BACKUP/final.log" >&2; echo "MUTATE_FAIL: gate RED after restore" >&2; exit 1; }
echo "   $(tail -1 "$BACKUP/final.log")"
trap - EXIT
rm -rf "$BACKUP"
echo "MUTATE_RASTER_THREAD_OK -- 3 mutants, 3 killed, engine restored and green"
