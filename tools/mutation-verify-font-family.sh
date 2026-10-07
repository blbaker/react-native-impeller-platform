#!/usr/bin/env bash
# ENG-22: prove tools/ci-font-family.sh FAILS when any one piece of the fix is
# removed. Each mutant edits the live tree, rebuilds, runs the gate, restores.
#   M1 Paragraph paint drops the family          -> arm A / C
#   M2 TextInput paint drops the family          -> arm D
#   M3 click-to-caret boundaries drop the family -> arm E
#   M4 Paragraph mount never records the family  -> arm A
#   M5 TextInput mount never records the family  -> arm D
#   M6 fonts never registered (both surfaces)    -> arm F
#   M7 ApplyFontFamily is a no-op                -> arm A
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SG="engine/scenegraph/SceneGraph.cpp"
MAIN="engine/host/main.cpp"
BACKUP="$(mktemp -d)"
cp "$SG" "$BACKUP/SG"; cp "$MAIN" "$BACKUP/MAIN"
BUILD_CMD="${RNI_BUILD_CMD:-bash tools/engine-build.sh linux x64}"
restore() { cp "$BACKUP/SG" "$SG"; cp "$BACKUP/MAIN" "$MAIN"; }
trap 'restore; eval "$BUILD_CMD" > /tmp/mvf-restore.log 2>&1 || true; rm -rf "$BACKUP"' EXIT

PASS=0; TOTAL=0
mutate() {  # $1 file  $2 old  $3 new  (exact, must occur exactly once)
  python3 - "$1" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
n = s.count(old)
assert n == 1, f"anchor found {n}x in {p}: {old[:60]!r}"
open(p, "w").write(s.replace(old, new))
PY
}
run_mutant() {  # $1 name  $2 ERE the FAIL line must match
  TOTAL=$((TOTAL + 1))
  echo "--- $1"
  if ! eval "$BUILD_CMD" > /tmp/mvf-build.log 2>&1; then
    echo "   BUILD FAILED: a mutant that does not compile proves nothing"
    grep -E 'error:' /tmp/mvf-build.log | head -3 | sed 's/^/     /'
  elif bash tools/ci-font-family.sh > /tmp/mvf-gate.log 2>&1; then
    echo "   NOT CAUGHT: gate still passed"
  elif grep -qE "FONT_FAMILY_GATE_FAIL: ($2)" /tmp/mvf-gate.log; then
    echo "   caught: $(grep FONT_FAMILY_GATE_FAIL /tmp/mvf-gate.log | head -1 | cut -c1-170)"
    PASS=$((PASS + 1))
  else
    echo "   killed, but not by the expected arm ($2):"
    grep FONT_FAMILY_GATE_FAIL /tmp/mvf-gate.log | head -1 | sed 's/^/     /'
  fi
  restore
}

echo "MUTATION_VERIFY_FONT_FAMILY_START"

mutate "$SG" "    ApplyFontFamily(style, node.fontFamily);  // ENG-22
    ApplyLineHeight(style, node.lineHeight, node.fontSize);  // ENG-23" "    ApplyLineHeight(style, node.lineHeight, node.fontSize);  // ENG-23 MUTANT M1"
run_mutant "M1 Paragraph paint drops the family" "A|C"

# ENG-25: TextInput paint builds its paragraph in BuildTextInputParagraph
# (shared with the multiline hit test), so M2 drops the family THERE.
mutate "$SG" "  ApplyFontFamily(style, node.fontFamily);  // ENG-22
  if (fg != nullptr)" "  if (fg != nullptr)  /* MUTANT M2 */"
run_mutant "M2 TextInput paint drops the family" "D"

mutate "$SG" "  ApplyFontFamily(style, node.fontFamily);
  for (size_t i = 1;" "  for (size_t i = 1;  /* MUTANT M3 */"
run_mutant "M3 click-to-caret boundaries drop the family" "E"

mutate "$SG" "          node.fontFamily = fragment.textAttributes.fontFamily;" \
             "          (void)0;  // MUTANT M4"
run_mutant "M4 Paragraph mount never records the family" "A|C"

mutate "$SG" "      node.fontFamily = attrs.fontFamily;  // ENG-22" \
             "      (void)0;  // MUTANT M5"
run_mutant "M5 TextInput mount never records the family" "D"

python3 - "$MAIN" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "  rni::RegisterFontDirs(surface.typography(), rni::FontDirsFrom(gFontDirs));"
assert s.count(old) == 2, s.count(old)
open(p, "w").write(s.replace(old, "  (void)gFontDirs;  // MUTANT M6"))
PY
run_mutant "M6 fonts never registered" "F"

mutate "$SG" "  if (!family.empty()) {
    ImpellerParagraphStyleSetFontFamily(style, family.c_str());
  }" "  (void)style; (void)family;  // MUTANT M7"
run_mutant "M7 ApplyFontFamily is a no-op" "A|C"

echo
if [ "$PASS" -eq "$TOTAL" ]; then
  echo "MUTATION_VERIFY_FONT_FAMILY_PASS ($PASS/$TOTAL)"
else
  echo "MUTATION_VERIFY_FONT_FAMILY_FAIL ($PASS/$TOTAL)"
  exit 1
fi
