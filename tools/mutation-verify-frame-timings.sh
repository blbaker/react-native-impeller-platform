#!/usr/bin/env bash
# MUTATION TEST for tools/ci-frame-timings.sh (FP-01). Each mutant edits engine
# source, rebuilds, and must turn the gate red for its own reason; the source
# is restored and the clean engine re-gated at the end.
#
#   M1  skip raster_start on frames painted under --idle-skip -> arm B errors
#   M2  stamp present before raster_end -> arm A errors (out-of-order stamps)
#   M3  drop the last frame from the recorder's output -> n != presents
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MAIN="engine/host/main.cpp"
FT="engine/host/FrameTimings.cpp"
FI="engine/host/FrameItem.cpp"  # FP-13 moved the raster stamps here
WR="engine/host/WindowRasterizer.cpp"  # FP-15 moved the windowed present stamp here
BACKUP="$(mktemp -d)"
cp "$MAIN" "$BACKUP/main.cpp"
cp "$FT" "$BACKUP/FrameTimings.cpp"
cp "$FI" "$BACKUP/FrameItem.cpp"
cp "$WR" "$BACKUP/WindowRasterizer.cpp"
restore() { cp "$BACKUP/main.cpp" "$MAIN"; cp "$BACKUP/FrameTimings.cpp" "$FT"; cp "$BACKUP/FrameItem.cpp" "$FI"; cp "$BACKUP/WindowRasterizer.cpp" "$WR"; }
trap 'restore; echo "(engine source restored; rebuild with tools/engine-build.sh)" >&2' EXIT

build() { bash tools/engine-build.sh linux x64 > "$1" 2>&1 || { tail -20 "$1" >&2; echo "MUTATE_FAIL: build failed" >&2; exit 1; }; }
gate()  { bash tools/ci-frame-timings.sh > "$1" 2>&1; }

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
  if ! grep -q 'FRAME_TIMINGS_FAIL' "$2"; then
    echo "MUTATE_FAIL: $1 SURVIVED -- ci-frame-timings stayed GREEN" >&2; exit 1
  fi
  grep -qE "$3" "$2" || { echo "MUTATE_FAIL: $1 killed for the WRONG reason:" >&2; grep -m3 'FAIL' "$2" >&2; exit 1; }
  echo "   $1 killed: $(grep -m1 -E "$3" "$2" | sed 's/^ *//' | cut -c1-160)"
}

echo "== M1: no raster_start on idle-skip frames =="
# RasterFrame (raster thread) cannot see --idle-skip, so the mutant passes it through the environment.
mutate "$MAIN" '    else if (a == "--idle-skip") { idleSkip = true; idleSkipSet = true; }' \
  '    else if (a == "--idle-skip") { idleSkip = true; idleSkipSet = true; setenv("RNI_MUTANT_IDLE", "1", 1); }  // MUTANT M1'
mutate "$FI" '#include <cstdio>' '#include <cstdio>
#include <cstdlib>  // MUTANT M1'
mutate "$FI" '  if (item.timings) item.timings->RecordRasterStart();' \
  '  if (item.timings && !getenv("RNI_MUTANT_IDLE")) item.timings->RecordRasterStart();  // MUTANT M1'
build "$BACKUP/m1-build.log"; gate "$BACKUP/m1.log" || true
expect_killed M1 "$BACKUP/m1.log" 'FT_FAIL: idle: frame_timing_errors=[1-9]'
restore

echo "== M2: present stamped before raster_end =="
mutate "$FI" '  if (item.timings) item.timings->RecordRasterEnd();' \
'  if (item.timings) item.timings->RecordPresent();  // MUTANT M2
  if (item.timings) item.timings->RecordRasterEnd();'
mutate "$WR" '    item->timings->RecordPresent();
    item->timings->SetImageCacheBytes' '    item->timings->SetImageCacheBytes'
build "$BACKUP/m2-build.log"; gate "$BACKUP/m2.log" || true
expect_killed M2 "$BACKUP/m2.log" 'FT_FAIL: windowed: frame_timing_errors=[1-9]'
restore

echo "== M3: last frame dropped =="
mutate "$FT" '  for (size_t i = 0; i < recs_.size(); ++i) out.push_back(recs_[i]);' \
  '  for (size_t i = 0; i + 1 < recs_.size(); ++i) out.push_back(recs_[i]);  // MUTANT M3'
build "$BACKUP/m3-build.log"; gate "$BACKUP/m3.log" || true
expect_killed M3 "$BACKUP/m3.log" 'FT_FAIL: windowed: n=[0-9]+ does not match presents=[0-9]+'
restore

echo "== RESTORE: clean engine must be GREEN =="
build "$BACKUP/final-build.log"
gate "$BACKUP/final.log" || { tail -15 "$BACKUP/final.log" >&2; echo "MUTATE_FAIL: gate RED after restore" >&2; exit 1; }
echo "   $(grep -o 'FRAME_TIMINGS_PASS.*' "$BACKUP/final.log")"
trap - EXIT
rm -rf "$BACKUP"
echo "MUTATE_FRAME_TIMINGS_OK -- 3 mutants, 3 killed, engine restored and green"
