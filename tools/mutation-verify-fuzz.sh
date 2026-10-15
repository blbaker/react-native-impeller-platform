#!/usr/bin/env bash
# FP-52 mutant: the fuzz gate must catch a missing bounds check in the SVG path parser.
#   A. Tokenizer::readFlag loses `if (i_ >= s_.size()) return false;`, so an arc whose
#      flags are cut off by the end of `d` ("M0 0A1 1 0") reads one char past the
#      buffer. tools/fuzz-run.sh svg-path 120 must CRASH from the committed seeds with
#      an ASan heap-buffer-overflow in readFlag (no seed contains the crasher; the
#      fuzzer has to truncate one).
# The source is restored by a trap and engine/build-fuzz rebuilt clean.
set -uo pipefail
cd "$(dirname "$0")/.."
SRC="engine/svg/SvgPath.cpp"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mut-fuzz.XXXX")"
cp "$SRC" "$WORK/SvgPath.cpp.orig"
restore() {
  cp "$WORK/SvgPath.cpp.orig" "$SRC"
  cmake --build engine/build-fuzz -j"$(nproc)" --target rn-impeller > "$WORK/restore-build.log" 2>&1 \
    || echo "MUTATION_WARN: clean fuzz rebuild failed (log $WORK/restore-build.log)"
}
trap restore EXIT
fail() { echo "MUTATION_FAIL: $*"; exit 1; }

python3 - "$SRC" <<'PY' || fail "anchor not found exactly once in $SRC"
import sys
p = sys.argv[1]; s = open(p).read()
a = """  bool readFlag(bool* out) {
    skipSeparators();
    if (i_ >= s_.size()) return false;
"""
if s.count(a) != 1: sys.exit(1)
open(p, "w").write(s.replace(a, """  bool readFlag(bool* out) {
    skipSeparators();
"""))
PY
grep -q 'if (i_ >= s_.size()) return false;' "$SRC" || fail "mutant removed every bounds check, not one"
echo "== mutant A: readFlag without its bounds check"
FUZZ_OUT="$WORK/a" bash tools/fuzz-run.sh svg-path 120 > "$WORK/a.out" 2>&1
rc=$?
[ -f "$WORK/a/build.log" ] && ! grep -q 'FAILED' "$WORK/a/build.log" || fail "mutant build failed"
if [ "$rc" = 0 ]; then
  tail -3 "$WORK/a.out"; fail "mutant A SURVIVED: 120 s of svg-path fuzzing found no over-read"
fi
grep -a -q 'ERROR: AddressSanitizer: heap-buffer-overflow' "$WORK/a/fuzz.log" \
  || { grep -a -m3 'ERROR' "$WORK/a/fuzz.log"; fail "mutant A crashed, but not with a heap-buffer-overflow"; }
grep -a -m1 -E '^\s+#[0-9]+ 0x.* in .*readFlag' "$WORK/a/fuzz.log" > "$WORK/a.frame" \
  || fail "mutant A's overflow is not in readFlag"
units="$(grep -a -o 'stat::number_of_executed_units: [0-9]*' "$WORK/a/fuzz.log" | grep -o '[0-9]*$')"
echo "FAIL (expected): svg-path heap-buffer-overflow in Tokenizer::readFlag after ${units:-?} executions"
sed 's/(BuildId.*//; s|.*/engine/|engine/|' "$WORK/a.frame"
echo "MUTATION_PASS fuzz (A killed)"
