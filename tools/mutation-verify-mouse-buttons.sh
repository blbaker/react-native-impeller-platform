#!/usr/bin/env bash
# MUTATION VERIFICATION for tools/ci-mouse-buttons.sh (desktop-input-gap item 6).
#
#   M1  left-only filter restored in the REAL callback (only the real-XTest arm
#       g can see this: synthetic events enter below the callback)
#   M2  middle and right swapped in the W3C button mapping
#   M3  a right press starts an RN touch (Pressable onPress fires)
#   M4  modifiers dropped from pointer events
set -euo pipefail
cd "$(dirname "$0")/.."
GS="engine/host/GlfwSurface.cpp"
MAIN="engine/host/main.cpp"
FH="engine/fabric/FabricHost.cpp"

BAK="$(mktemp -d)"
cp "$GS" "$BAK/GlfwSurface.cpp"; cp "$MAIN" "$BAK/main.cpp"; cp "$FH" "$BAK/FabricHost.cpp"
restore() { cp "$BAK/GlfwSurface.cpp" "$GS"; cp "$BAK/main.cpp" "$MAIN"; cp "$BAK/FabricHost.cpp" "$FH"; }
trap 'restore; bash tools/engine-build.sh linux x64 > /dev/null 2>&1 || true; echo "logs: $BAK"' EXIT

fail() { echo "MUTATION_VERIFY_FAIL: $*" >&2; exit 1; }

grep -q "// MUTANT" "$GS" "$FH" && fail "mutant residue already in the tree -- restore it first (git diff)"
grep -q "fabric.dispatchPointerButton(ev.x" "$MAIN" \
  || fail "the fix is NOT in the tree (no extra-button wiring) -- a passing gate here would be blind"

run_gate() {
  set +e
  bash tools/ci-mouse-buttons.sh > "$1" 2>&1
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
  if grep -q MOUSE_BUTTONS_GATE_PASS "$2"; then
    fail "$1 SURVIVED: the gate passed with this defect in the binary"
  fi
  grep -qE "MOUSE_BUTTONS_GATE_FAIL: .*($3)" "$2" || {
    tail -25 "$2" >&2
    fail "$1 was killed, but not by the expected assertion ('$3'); see the tail above"
  }
  echo "   OK: $1 killed -> $(grep -m1 'MOUSE_BUTTONS_GATE_FAIL' "$2")"
}

echo "== control: unmutated tree must PASS =="
run_gate "$BAK/control.log" || { tail -40 "$BAK/control.log" >&2; fail "gate fails on the UNMUTATED tree"; }
grep -q MOUSE_BUTTONS_GATE_PASS "$BAK/control.log" || fail "control did not print MOUSE_BUTTONS_GATE_PASS"
echo "   OK: control passes"

echo "== M1: left-only filter in the REAL callback =="
mutate "$GS" \
'    if (action != GLFW_PRESS && action != GLFW_RELEASE) return;
    double cx = 0.0, cy = 0.0;
    glfwGetCursorPos(w, &cx, &cy);
    const bool down = action == GLFW_PRESS;' \
'    if (action != GLFW_PRESS && action != GLFW_RELEASE) return;
    if (button != GLFW_MOUSE_BUTTON_LEFT) return;  // MUTANT M1
    double cx = 0.0, cy = 0.0;
    glfwGetCursorPos(w, &cx, &cy);
    const bool down = action == GLFW_PRESS;'
run_gate "$BAK/m1.log" || true
expect_killed M1 "$BAK/m1.log" "REAL button callback drops this button"
restore

echo "== M2: middle and right swapped =="
mutate "$GS" \
'      case GLFW_MOUSE_BUTTON_MIDDLE: w3c = 1; break;
      case GLFW_MOUSE_BUTTON_RIGHT: w3c = 2; break;' \
'      case GLFW_MOUSE_BUTTON_MIDDLE: w3c = 2; break;  // MUTANT M2
      case GLFW_MOUSE_BUTTON_RIGHT: w3c = 1; break;'
run_gate "$BAK/m2.log" || true
expect_killed M2 "$BAK/m2.log" "maps it to the wrong W3C button|mapped to the wrong W3C button"
restore

echo "== M3: a right press starts an RN touch =="
mutate "$MAIN" \
'        fabric.dispatchPointerButton(ev.x, ev.y, ev.down, ev.button,' \
'        // MUTANT M3: non-left buttons also drive the touch path
        if (ev.down) fabric.beginTouchCapture(ev.x, ev.y);
        else fabric.endTouchCapture(ev.x, ev.y);
        fabric.dispatchPointerButton(ev.x, ev.y, ev.down, ev.button,'
run_gate "$BAK/m3.log" || true
expect_killed M3 "$BAK/m3.log" "non-left button started an RN touch"
restore

echo "== M4: modifiers dropped from pointer events =="
mutate "$FH" \
'  event.shiftKey = shift;
  event.ctrlKey = ctrl;' \
'  event.shiftKey = false;  // MUTANT M4
  event.ctrlKey = false;'
run_gate "$BAK/m4.log" || true
expect_killed M4 "$BAK/m4.log" "modifiers are dropped from pointer events"
restore

echo "MUTATION_VERIFY_MOUSE_BUTTONS_PASS: control PASS, M1-M4 each FAIL the gate"
