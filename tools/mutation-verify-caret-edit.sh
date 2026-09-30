#!/usr/bin/env bash
# MUTATION VERIFICATION for tools/ci-caret-edit.sh (desktop-input-gap item 2a).
#
# ci-caret-edit.sh was written AFTER the fix, so it had never been seen to fail.
# Each mutant below puts back one piece of the pre-item-2a behaviour (or
# breaks one piece of the new caret/UTF-8 code), rebuilds, and requires the
# gate to FAIL on the assertion that names that defect.
#
#   M1  caret pinned to end again (dispatchKey ignores the persisted caret)
#       -> arm A fails: buffer becomes 'abcdefX', not 'abcXdef'
#   M2  ASCII-only filter restored in Utf8EncodeAppend
#       -> arm C fails: the emoji (and e-acute) are silently dropped
#   M3  Backspace pops a single BYTE instead of a whole codepoint
#       -> arm C fails: invalid UTF-8 after removing the emoji
#   M4  caret painted at end regardless of tiCaret_
#       -> arm E fails: no pixel difference after Left x3
#
# The gate rebuilds the engine itself (tools/engine-build.sh) before packing,
# so each mutant is compiled into the binary it tests. The trap restores the
# source; the final step rebuilds the clean tree so the staged binary is the
# real one again.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC_FABRIC="engine/fabric/FabricHost.cpp"
SRC_SCENE="engine/scenegraph/SceneGraph.cpp"

BAK="$(mktemp -d)"
cp "$SRC_FABRIC" "$BAK/FabricHost.cpp"
cp "$SRC_SCENE" "$BAK/SceneGraph.cpp"
restore() {
  cp "$BAK/FabricHost.cpp" "$SRC_FABRIC"
  cp "$BAK/SceneGraph.cpp" "$SRC_SCENE"
}
trap 'restore; bash tools/engine-build.sh linux x64 > /dev/null 2>&1 || true; echo "logs: $BAK"' EXIT

fail() { echo "MUTATION_VERIFY_FAIL: $*" >&2; exit 1; }

grep -q "// MUTANT" "$SRC_FABRIC" && fail "mutant residue already in $SRC_FABRIC -- restore it first (git diff)"
grep -q "// MUTANT" "$SRC_SCENE" && fail "mutant residue already in $SRC_SCENE -- restore it first (git diff)"
grep -q "size_t caret = sceneGraph_->textInputCaretFor(tag);" "$SRC_FABRIC" \
  || fail "the fix is NOT in the tree (no persisted-caret read in dispatchKey) -- a passing gate here would be blind"

run_gate() {
  set +e
  bash tools/ci-caret-edit.sh > "$1" 2>&1
  local rc=$?
  set -e
  return $rc
}

mutate() {  # $1 = file, $2 = old text, $3 = new text
  python3 - "$1" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
assert s.count(old) == 1, "mutant anchor not found exactly once in %s: %r" % (p, old[:80])
open(p, "w").write(s.replace(old, new, 1))
PY
}

expect_killed() {  # $1 = name, $2 = log, $3 = ERE the FAIL line must carry
  if grep -q CARET_EDIT_GATE_PASS "$2"; then
    fail "$1 SURVIVED: the gate passed with this defect in the binary"
  fi
  grep -qE "CARET_EDIT_GATE_FAIL: .*($3)" "$2" || {
    tail -25 "$2" >&2
    fail "$1 was killed, but not by the expected assertion ('$3'); see the tail above"
  }
  echo "   OK: $1 killed -> $(grep -m1 'CARET_EDIT_GATE_FAIL' "$2")"
}

echo "== control: unmutated tree must PASS =="
run_gate "$BAK/control.log" || { tail -40 "$BAK/control.log" >&2; fail "gate fails on the UNMUTATED tree"; }
grep -q CARET_EDIT_GATE_PASS "$BAK/control.log" || fail "control did not print CARET_EDIT_GATE_PASS"
echo "   OK: control passes"

echo "== M1: caret pinned to end again (ignores the persisted caret) =="
mutate "$SRC_FABRIC" \
'  std::string value = sceneGraph_->textInputValueFor(tag);
  size_t caret = sceneGraph_->textInputCaretFor(tag);
  if (caret > value.size()) caret = value.size();  // defensive clamp' \
'  // MUTANT M1: pinned to end again, ignoring the persisted caret
  std::string value = sceneGraph_->textInputValueFor(tag);
  size_t caret = value.size();'
run_gate "$BAK/m1.log" || true
expect_killed M1 "$BAK/m1.log" "abcXdef|caret should be 4|End\+Left x3 left caret at pos="
restore

echo "== M2: ASCII-only filter restored (rejects anything >= 0x80) =="
mutate "$SRC_FABRIC" \
'bool Utf8EncodeAppend(std::string* out, unsigned int cp) {
  if (cp < 0x20 || cp == 0x7F) return false;
  if (cp >= 0xD800 && cp <= 0xDFFF) return false;
  if (cp > 0x10FFFF) return false;' \
'bool Utf8EncodeAppend(std::string* out, unsigned int cp) {
  // MUTANT M2: pre-item-2a ASCII-only filter restored
  if (cp < 0x20 || cp >= 0x7F) return false;
  if (cp >= 0xD800 && cp <= 0xDFFF) return false;
  if (cp > 0x10FFFF) return false;'
run_gate "$BAK/m2.log" || true
expect_killed M2 "$BAK/m2.log" "emoji.*dropped|onChangeText after typing e-acute|after typing e-acute"
restore

echo "== M3: Backspace pops a single BYTE instead of a whole codepoint =="
mutate "$SRC_FABRIC" \
'    case KeyAction::Backspace: {
      // Deletes ONE WHOLE CODEPOINT before the caret, never a single byte --
      // popping a byte off a multi-byte sequence (the pre-item-2a behaviour)
      // corrupts the buffer into invalid UTF-8.
      if (caret > 0) {
        size_t prev = Utf8PrevBoundary(value, caret);
        value.erase(prev, caret - prev);
        caret = prev;
        textChanged = true;
      }
      break;
    }' \
'    case KeyAction::Backspace: {
      // MUTANT M3: pops a single byte, pre-item-2a behaviour
      if (caret > 0) {
        value.erase(caret - 1, 1);
        caret = caret - 1;
        textChanged = true;
      }
      break;
    }'
run_gate "$BAK/m3.log" || true
expect_killed M3 "$BAK/m3.log" "INVALID_UTF8|not valid UTF-8|single-byte-pop|emoji removed WHOLE"
restore

echo "== M4: caret painted at end regardless of tiCaret_ =="
mutate "$SRC_SCENE" \
'        if (focused && !showPlaceholder) {
          const std::string upto = tiEditValue_.substr(0, tiCaret_);' \
'        if (focused && !showPlaceholder) {
          // MUTANT M4: caret painted at end-of-text regardless of tiCaret_
          const std::string upto = tiEditValue_;
          (void)tiCaret_;'

run_gate "$BAK/m4.log" || true
expect_killed M4 "$BAK/m4.log" "NOT repainted after Left|did not move left"
restore

echo "MUTATION_VERIFY_CARET_PASS: control PASS, M1-M4 each FAIL the gate"
