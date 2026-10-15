#!/usr/bin/env bash
# MUTATION TEST for tools/ci-image-upload.sh (FP-17). Each mutant edits ENGINE
# SOURCE, rebuilds, and must turn the gate red for its own reason.
#
#   M1  upload on the raster thread again: the painter ignores the IO thread's
#       finished texture and queues the FP-14 raster-side upload
#       -> A: raster_p99 over 1.2 x the preloaded control
#   M2  hand off before the fence: the IO thread publishes the name and
#       completes the load as soon as the storage exists, before the pixels are
#       transferred and fenced -> B: presents show the poison storage
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
unset RNI_BIN

IP="engine/scenegraph/ImagePaint.cpp"
IO="engine/scenegraph/IoUploader.cpp"
BACKUP="$(mktemp -d)"
cp "$IP" "$BACKUP/ImagePaint.cpp"
cp "$IO" "$BACKUP/IoUploader.cpp"
restore() { cp "$BACKUP/ImagePaint.cpp" "$IP"; cp "$BACKUP/IoUploader.cpp" "$IO"; }
trap 'restore; echo "(engine source restored; rebuild with tools/engine-build.sh)" >&2' EXIT

build() { bash tools/engine-build.sh linux x64 > "$1" 2>&1 || { tail -20 "$1" >&2; echo "MUTATE_FAIL: build failed" >&2; exit 1; }; }
gate()  { bash tools/ci-image-upload.sh > "$1" 2>&1; }

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
  if grep -q 'IMAGE_UPLOAD_PASS' "$2" || ! grep -q 'IMAGE_UPLOAD_FAIL' "$2"; then
    echo "MUTATE_FAIL: $1 SURVIVED -- ci-image-upload stayed GREEN" >&2; tail -5 "$2" >&2; exit 1
  fi
  grep -qE "$3" "$2" || { echo "MUTATE_FAIL: $1 killed for the WRONG reason:" >&2; grep -m3 'FAIL' "$2" >&2; exit 1; }
  echo "   $1 killed: $(grep -m1 -E "$3" "$2" | sed 's/^ *//' | cut -c1-220)"
}

echo "== M1: upload on the raster thread again =="
mutate "$IP" 'if (const uint32_t ioName = io::Take(d.get()); ioName != 0) {' \
'if (const uint32_t ioName = 0 * io::Take(d.get()); ioName != 0) {  // MUTANT M1'
build "$BACKUP/m1-build.log"; gate "$BACKUP/m1.log" || true
expect_killed M1 "$BACKUP/m1.log" 'A: raster_p99 [0-9]+ us > 1.2 x control [0-9]+ us: upload time is in the raster frame'
restore

echo "== M2: hand off before the fence =="
mutate "$IO" '  HandOff(t, name);
' '  if (DelayMs() == 0) HandOff(t, name);  // MUTANT M2 (no-delay path unchanged)
'
mutate "$IO" '    glFlush();
    std::this_thread::sleep_for(' '    glFlush();
    HandOff(t, name);  // MUTANT M2: before the transfer and its fence
    std::this_thread::sleep_for('
build "$BACKUP/m2-build.log"; gate "$BACKUP/m2.log" || true
expect_killed M2 "$BACKUP/m2.log" 'B: [0-9]+ presents showed an image before its upload fence'
restore

echo "== RESTORE: clean engine must be GREEN =="
build "$BACKUP/final-build.log"
gate "$BACKUP/final.log" || { tail -15 "$BACKUP/final.log" >&2; echo "MUTATE_FAIL: gate RED after restore" >&2; exit 1; }
echo "   $(tail -1 "$BACKUP/final.log")"
trap - EXIT
rm -rf "$BACKUP"
echo "MUTATE_IMAGE_UPLOAD_OK -- 2 mutants, 2 killed, engine restored and green"
