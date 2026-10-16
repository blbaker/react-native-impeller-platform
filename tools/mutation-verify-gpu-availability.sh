#!/usr/bin/env bash
# MUTATION TEST for tools/ci-gpu-availability.sh (FP-31). Each mutant edits ENGINE
# SOURCE, rebuilds, and must turn the gate red for its own reason.
#
#   M1  the main paint loop ignores the switch (RECORD runs while unavailable) -> A:
#       the records counter advances inside the unavailable window
#   M2  the raster side ignores the switch (frames already queued still draw and
#       present) -> B (150 ms raster delay keeps frames queued at the flip): draws
#       advance inside the window
#   M3  the IO upload path ignores the switch -> A: uploads advance inside the window
#   M4  no repaint on restore (the listener never asks the scheduler for a frame;
#       JS is idle by then) -> A: no frame after the restore
#   M5  the restore frame may be damage-clipped (ConsumeRestore never forces a
#       full repaint) -> D: the restore frame is a partial repaint
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
unset RNI_BIN

FILES=(engine/host/main.cpp engine/host/WindowRasterizer.cpp engine/scenegraph/IoUploaderGl.cpp engine/base/GpuAvailability.cpp)
BACKUP="$(mktemp -d)"
for f in "${FILES[@]}"; do cp "$f" "$BACKUP/$(basename "$f")"; done
restore() { for f in "${FILES[@]}"; do cp "$BACKUP/$(basename "$f")" "$f"; done; }
trap 'restore; echo "(engine source restored; rebuild with tools/engine-build.sh)" >&2' EXIT

build() { bash tools/engine-build.sh linux x64 > "$1" 2>&1 || { tail -20 "$1" >&2; echo "MUTATE_FAIL: build failed" >&2; exit 1; }; }
gate()  { bash tools/ci-gpu-availability.sh > "$1" 2>&1; }

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
  if grep -q 'GPU_AVAILABILITY_PASS' "$2" || ! grep -q 'GPU_AVAILABILITY_FAIL' "$2"; then
    echo "MUTATE_FAIL: $1 SURVIVED -- ci-gpu-availability stayed GREEN" >&2; tail -5 "$2" >&2; exit 1
  fi
  grep -qE "$3" "$2" || { echo "MUTATE_FAIL: $1 killed for the WRONG reason:" >&2; grep -m3 FAIL "$2" >&2; exit 1; }
  echo "   $1 killed: $(grep -m1 -E "$3" "$2" | cut -c1-220)"
}

echo "== M1: main paint loop ignores the switch =="
mutate engine/host/main.cpp '    if (!rni::gpu::Available()) {
      rni::gpu::Note(rni::gpu::Counter::kSkippedFrame);' '    if (false) {  // MUTANT M1: RECORD while unavailable
      rni::gpu::Note(rni::gpu::Counter::kSkippedFrame);'
build "$BACKUP/m1-build.log"; gate "$BACKUP/m1.log" || true
expect_killed M1 "$BACKUP/m1.log" 'A: records advanced [0-9]+ -> [0-9]+ while the GPU was unavailable'
restore

echo "== M2: raster side ignores the switch =="
mutate engine/host/WindowRasterizer.cpp '  if (!gpuSection.available()) {' '  if (false) {  // MUTANT M2: draw + present while unavailable'
build "$BACKUP/m2-build.log"; gate "$BACKUP/m2.log" || true
expect_killed M2 "$BACKUP/m2.log" 'B: draws advanced [0-9]+ -> [0-9]+ while the GPU was unavailable'
restore

echo "== M3: IO upload path ignores the switch =="
mutate engine/scenegraph/IoUploaderGl.cpp '    if (!gpuSection.available()) {' '    if (false) {  // MUTANT M3: upload while unavailable'
build "$BACKUP/m3-build.log"; gate "$BACKUP/m3.log" || true
expect_killed M3 "$BACKUP/m3.log" 'A: uploads advanced [0-9]+ -> [0-9]+ while the GPU was unavailable'
restore

echo "== M4: no repaint on restore =="
mutate engine/base/GpuAvailability.cpp '  if (fn) fn();  // asks the scheduler for the repaint' '  (void)fn;  // MUTANT M4: no repaint request'
build "$BACKUP/m4-build.log"; gate "$BACKUP/m4.log" || true
expect_killed M4 "$BACKUP/m4.log" 'A: no frame after the restore'
restore

echo "== M5: restore frame not forced to a full repaint =="
mutate engine/host/main.cpp 'rasterizer.partialRepaint() && !rni::gpu::ConsumeRestore();' 'rasterizer.partialRepaint();  // MUTANT M5'
build "$BACKUP/m5-build.log"; gate "$BACKUP/m5.log" || true
expect_killed M5 "$BACKUP/m5.log" 'D: restore frame was a damage-clipped partial repaint'
restore

echo "== RESTORE: clean engine must be GREEN =="
build "$BACKUP/final-build.log"
gate "$BACKUP/final.log" || { tail -15 "$BACKUP/final.log" >&2; echo "MUTATE_FAIL: gate RED after restore" >&2; exit 1; }
echo "   $(tail -1 "$BACKUP/final.log")"
trap - EXIT
rm -rf "$BACKUP"
echo "MUTATION_VERIFY_GPU_AVAILABILITY_PASS"
