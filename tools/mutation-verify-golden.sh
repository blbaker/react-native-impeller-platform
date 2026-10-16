#!/usr/bin/env bash
# MUTATION TEST for tools/ci-golden.sh (FP-51). Golden-side mutants edit a COPY of the goldens
# (GOLDEN_DIR) and run the real gate; the engine mutant edits ENGINE SOURCE, rebuilds, and runs it.
#
#   G1  every golden pixel moved by 1 level (1-LSB colour shift)     must PASS (tolerance works)
#   G2  every golden channel +8                                       must FAIL on every case
#   G3  every golden shifted 1 px sideways (1 px offset)              must FAIL on every case
#   G4  one golden deleted                                            must FAIL "missing golden"
#   G5  one golden replaced by another case's image                   must FAIL that case
#   E1  engine paints the root 1 px to the right                      must FAIL on every case
# Cases whose FAIL line is absent in G2/G3/E1 mean the FIXTURE cannot see the defect: fix the case list.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
unset RNI_BIN
. tools/lib/golden-render.sh
golden_backend=linux-gles
CASES="$(golden_cases | cut -d'|' -f1)"
N="$(echo "$CASES" | wc -w)"

FILE=engine/host/FrameItem.cpp
BACKUP="$(mktemp -d)"; cp "$FILE" "$BACKUP/FrameItem.cpp"
restore() { cp "$BACKUP/FrameItem.cpp" "$FILE"; }
trap 'restore; echo "(engine source restored; rebuild with tools/engine-build.sh)" >&2' EXIT

gate() {  # log [env...]: runs the real gate against $GOLDEN_DIR if set
  GOLDEN_DIR="${GOLDEN_DIR:-}" GOLDEN_DIFF_DIR="$BACKUP/diff" bash tools/ci-golden.sh > "$1" 2>&1
}
variant() {  # name mutate-args... : a golden tree with every png mutated
  local d="$BACKUP/g-$1"; shift
  mkdir -p "$d/$golden_backend"
  for c in $CASES; do python3 tools/golden_compare.py mutate "tools/golden/$golden_backend/$c.png" "$d/$golden_backend/$c.png" "$@"; done
  echo "$d"
}
must_fail_all() {  # name log
  grep -q '^GOLDEN_PASS$' "$2" && { echo "MUTATE_FAIL: $1 SURVIVED, gate stayed GREEN" >&2; exit 1; }
  for c in $CASES; do
    grep -q "^GOLDEN_FAIL $golden_backend/$c:" "$2" || { echo "MUTATE_FAIL: $1 not seen by case $c (fixture blind to it)" >&2; grep FAIL "$2" | head -5 >&2; exit 1; }
  done
  echo "   $1 killed on all $N cases, e.g. $(grep -m1 '^GOLDEN_FAIL' "$2" | cut -c1-200)"
}

echo "== G1: 1-LSB colour shift must PASS =="
GOLDEN_DIR="$(variant lsb --lsb)" gate "$BACKUP/g1.log" || { grep FAIL "$BACKUP/g1.log" | head -5 >&2; echo "MUTATE_FAIL: G1 1-LSB shift failed the gate (tolerance too tight)" >&2; exit 1; }
echo "   G1 passed: $(grep -m1 '^GOLDEN_PASS linux-gles/text' "$BACKUP/g1.log" | cut -c1-160)"
grep -q 'max_channel_delta=1 ' "$BACKUP/g1.log" || { echo "MUTATE_FAIL: G1 shift was not seen as delta 1 (mutant did nothing)" >&2; exit 1; }

echo "== G2: +8 colour shift must FAIL =="
GOLDEN_DIR="$(variant add8 --add 8)" gate "$BACKUP/g2.log" || true; must_fail_all G2 "$BACKUP/g2.log"

echo "== G3: 1 px offset must FAIL =="
GOLDEN_DIR="$(variant shift1 --shift-x 1)" gate "$BACKUP/g3.log" || true; must_fail_all G3 "$BACKUP/g3.log"

echo "== G4: missing golden must FAIL =="
d="$BACKUP/g-missing"; mkdir -p "$d"; cp -r "tools/golden/$golden_backend" "$d/"; rm "$d/$golden_backend/svg.png"
GOLDEN_DIR="$d" gate "$BACKUP/g4.log" && { echo "MUTATE_FAIL: G4 missing golden did not fail" >&2; exit 1; }
grep -q "^GOLDEN_FAIL $golden_backend/svg: missing golden" "$BACKUP/g4.log" || { echo "MUTATE_FAIL: G4 wrong reason" >&2; grep FAIL "$BACKUP/g4.log" | head -3 >&2; exit 1; }
echo "   G4 killed: $(grep -m1 'missing golden' "$BACKUP/g4.log" | cut -c1-160)"

echo "== G5: golden of another case must FAIL =="
d="$BACKUP/g-swap"; mkdir -p "$d"; cp -r "tools/golden/$golden_backend" "$d/"; cp "$d/$golden_backend/text.png" "$d/$golden_backend/svg.png"
GOLDEN_DIR="$d" gate "$BACKUP/g5.log" && { echo "MUTATE_FAIL: G5 swapped golden did not fail" >&2; exit 1; }
grep -q "^GOLDEN_FAIL $golden_backend/svg:" "$BACKUP/g5.log" || { echo "MUTATE_FAIL: G5 wrong reason" >&2; grep FAIL "$BACKUP/g5.log" | head -3 >&2; exit 1; }
echo "   G5 killed: $(grep -m1 "GOLDEN_FAIL $golden_backend/svg" "$BACKUP/g5.log" | cut -c1-160)"

echo "== E1: engine paints 1 px right =="
python3 - "$FILE" <<'PY'
import sys
p = sys.argv[1]
old = "item->painted = scene.paint(builder, pointScale, item->jobs.get(), &damage, culled);"
s = open(p).read()
assert s.count(old) == 1, "anchor found %dx" % s.count(old)
open(p, "w").write(s.replace(old, "ImpellerDisplayListBuilderTranslate(builder, 1, 0);  // MUTANT E1\n    " + old, 1))
PY
bash tools/engine-build.sh linux x64 > "$BACKUP/e1-build.log" 2>&1 || { tail -20 "$BACKUP/e1-build.log" >&2; echo "MUTATE_FAIL: E1 build failed" >&2; exit 1; }
GOLDEN_DIR="" gate "$BACKUP/e1.log" || true; must_fail_all E1 "$BACKUP/e1.log"
restore

echo "== RESTORE: clean engine must be GREEN =="
bash tools/engine-build.sh linux x64 > "$BACKUP/final-build.log" 2>&1 || { tail -20 "$BACKUP/final-build.log" >&2; echo "MUTATE_FAIL: restore build failed" >&2; exit 1; }
gate "$BACKUP/final.log" || { tail -15 "$BACKUP/final.log" >&2; echo "MUTATE_FAIL: gate RED after restore" >&2; exit 1; }
trap - EXIT; rm -rf "$BACKUP"
echo "MUTATION_VERIFY_PASS ci-golden: 6 mutants killed or tolerated as designed"
