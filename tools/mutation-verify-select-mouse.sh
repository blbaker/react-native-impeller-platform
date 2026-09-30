#!/usr/bin/env bash
# MUTATION VERIFICATION for tools/ci-select-mouse.sh (desktop-input-gap item 4b).
#
#   M1  drag does not extend (moves while the button is held are ignored)
#   M2  click count never increments (no double/triple click)
#   M3  Shift on a press is dropped (Shift+click does not extend)
#   M4  no distance check on the multi-click rule (distant clicks count as a
#       double click)
set -euo pipefail
cd "$(dirname "$0")/.."
GS="engine/host/GlfwSurface.cpp"
MAIN="engine/host/main.cpp"

BAK="$(mktemp -d)"
cp "$GS" "$BAK/GlfwSurface.cpp"
cp "$MAIN" "$BAK/main.cpp"
restore() { cp "$BAK/GlfwSurface.cpp" "$GS"; cp "$BAK/main.cpp" "$MAIN"; }
trap 'restore; bash tools/engine-build.sh linux x64 > /dev/null 2>&1 || true; echo "logs: $BAK"' EXIT

fail() { echo "MUTATION_VERIFY_FAIL: $*" >&2; exit 1; }

grep -q "// MUTANT" "$GS" "$MAIN" && fail "mutant residue already in the tree -- restore it first (git diff)"
grep -q "fabric.dragTextSelection(x, y)" "$MAIN" \
  || fail "the fix is NOT in the tree (no dragTextSelection call) -- a passing gate here would be blind"

run_gate() {
  set +e
  bash tools/ci-select-mouse.sh > "$1" 2>&1
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
  if grep -q SELECT_MOUSE_GATE_PASS "$2"; then
    fail "$1 SURVIVED: the gate passed with this defect in the binary"
  fi
  grep -qE "SELECT_MOUSE_GATE_FAIL: .*($3)" "$2" || {
    tail -25 "$2" >&2
    fail "$1 was killed, but not by the expected assertion ('$3'); see the tail above"
  }
  echo "   OK: $1 killed -> $(grep -m1 'SELECT_MOUSE_GATE_FAIL' "$2")"
}

echo "== control: unmutated tree must PASS =="
run_gate "$BAK/control.log" || { tail -40 "$BAK/control.log" >&2; fail "gate fails on the UNMUTATED tree"; }
grep -q SELECT_MOUSE_GATE_PASS "$BAK/control.log" || fail "control did not print SELECT_MOUSE_GATE_PASS"
echo "   OK: control passes"

echo "== M1: drag does not extend =="
mutate "$MAIN" \
'    const bool selectionDrag = fabric.dragTextSelection(x, y);' \
'    // MUTANT M1: drag ignored
    const bool selectionDrag = false;'
run_gate "$BAK/m1.log" || true
expect_killed M1 "$BAK/m1.log" "dragging does not extend a selection"
restore

echo "== M2: click count never increments =="
mutate "$GS" \
'        (near && nowMs - lastPressMs_ <= kMultiClickMs) ? clickCount_ + 1 : 1;' \
'        1;  // MUTANT M2: no multi-click'
run_gate "$BAK/m2.log" || true
expect_killed M2 "$BAK/m2.log" "double click does not select a word|triple click does not select the line"
restore

echo "== M3: Shift on a press is dropped =="
mutate "$GS" \
'    pressShift_ = (glfwMods & GLFW_MOD_SHIFT) != 0;' \
'    pressShift_ = false;  // MUTANT M3: Shift dropped'
run_gate "$BAK/m3.log" || true
expect_killed M3 "$BAK/m3.log" "Shift\+click does not extend"
restore

echo "== M4: no distance check on multi-click =="
mutate "$GS" \
'    const bool near = std::fabs(screenX - lastPressX_) <= kMultiClickSlopPx &&
                      std::fabs(screenY - lastPressY_) <= kMultiClickSlopPx;' \
'    const bool near = true;  // MUTANT M4: no slop check'
run_gate "$BAK/m4.log" || true
expect_killed M4 "$BAK/m4.log" "counted as a double click"
restore

echo "MUTATION_VERIFY_SELECT_MOUSE_PASS: control PASS, M1-M4 each FAIL the gate"
