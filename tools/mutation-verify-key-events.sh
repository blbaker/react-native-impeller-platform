#!/usr/bin/env bash
# MUTATION VERIFICATION for tools/ci-key-events.sh (desktop-input-gap item 1).
#
# ci-key-events.sh was written AFTER the fix, so it had never been seen to
# fail. Each mutant below puts back one piece of the pre-fix key callback (or
# breaks one piece of the new path), rebuilds, and requires the gate to FAIL
# on the assertion that names that defect. A mutant that survives means the
# gate is blind to that defect.
#
#   M1  old filter: only Backspace/Enter/KP_Enter forwarded, release dropped
#   M2  modifiers dropped (shift/ctrl/alt/meta/caps all read as 0)
#   M3  key release dropped (the old `if (action == GLFW_RELEASE) return;`)
#   M4  glfwSetKeyCallback body no-ops: only the REAL XTest arm can see this;
#       the synthetic arm calls dispatchKeyEvent directly and stays green
#
# The gate rebuilds the engine itself (tools/engine-build.sh) before packing,
# so each mutant is compiled into the binary it tests. The trap restores the
# source; the final step rebuilds the clean tree so the staged binary is the
# real one again.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="engine/host/GlfwSurface.cpp"

BAK="$(mktemp -d)"
cp "$SRC" "$BAK/GlfwSurface.cpp"
restore() { cp "$BAK/GlfwSurface.cpp" "$SRC"; }
trap 'restore; bash tools/engine-build.sh linux x64 > /dev/null 2>&1 || true; echo "logs: $BAK"' EXIT

fail() { echo "MUTATION_VERIFY_FAIL: $*" >&2; exit 1; }

grep -q "// MUTANT" "$SRC" && fail "mutant residue already in $SRC -- restore it first (git diff)"
grep -q "void GlfwSurface::dispatchKeyEvent" "$SRC" \
  || fail "the fix is NOT in the tree (no dispatchKeyEvent) -- a passing gate here would be blind"

run_gate() {
  set +e
  bash tools/ci-key-events.sh > "$1" 2>&1
  local rc=$?
  set -e
  return $rc
}

mutate() {  # $1 = old text, $2 = new text
  python3 - "$SRC" "$1" "$2" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
assert s.count(old) == 1, "mutant anchor not found exactly once: %r" % old[:80]
open(p, "w").write(s.replace(old, new))
PY
}

expect_killed() {  # $1 = name, $2 = log, $3 = ERE the FAIL line must carry
  if grep -q KEY_EVENTS_GATE_PASS "$2"; then
    fail "$1 SURVIVED: the gate passed with this defect in the binary"
  fi
  grep -qE "KEY_EVENTS_GATE_FAIL: .*($3)" "$2" || {
    tail -20 "$2" >&2
    fail "$1 was killed, but not by the expected assertion ('$3'); see the tail above"
  }
  echo "   OK: $1 killed -> $(grep -m1 'KEY_EVENTS_GATE_FAIL' "$2")"
}

DISPATCH_TOP='  std::string w3cKey, w3cCode;
  if (!TranslateGlfwKey(key, scancode, &w3cKey, &w3cCode)) return;'

echo "== control: unmutated tree must PASS =="
run_gate "$BAK/control.log" || { tail -25 "$BAK/control.log" >&2; fail "gate fails on the UNMUTATED tree"; }
grep -q KEY_EVENTS_GATE_PASS "$BAK/control.log" || fail "control did not print KEY_EVENTS_GATE_PASS"
echo "   OK: control passes"

echo "== M1: old filter (Backspace/Enter only, release dropped) =="
mutate "$DISPATCH_TOP" "  // MUTANT M1: pre-fix filter
  if (action == GLFW_RELEASE) return;
  if (key != GLFW_KEY_BACKSPACE && key != GLFW_KEY_ENTER &&
      key != GLFW_KEY_KP_ENTER) return;
$DISPATCH_TOP"
run_gate "$BAK/m1.log" || true
expect_killed M1 "$BAK/m1.log" "key_event type=down|ArrowLeft"
restore

echo "== M2: modifiers dropped =="
mutate "  ev.shift = (mods & GLFW_MOD_SHIFT) != 0;
  ev.ctrl = (mods & GLFW_MOD_CONTROL) != 0;
  ev.alt = (mods & GLFW_MOD_ALT) != 0;
  ev.meta = (mods & GLFW_MOD_SUPER) != 0;
  ev.capsLock = (mods & GLFW_MOD_CAPS_LOCK) != 0;" "  // MUTANT M2: modifiers dropped
  (void)mods;
  ev.shift = ev.ctrl = ev.alt = ev.meta = ev.capsLock = false;"
run_gate "$BAK/m2.log" || true
expect_killed M2 "$BAK/m2.log" "shift=1"
restore

echo "== M3: key release dropped =="
mutate "$DISPATCH_TOP" "  // MUTANT M3: release dropped
  if (action == GLFW_RELEASE) return;
$DISPATCH_TOP"
run_gate "$BAK/m3.log" || true
expect_killed M3 "$BAK/m3.log" "type=up|KEYUP"
restore

echo "== M4: real key callback no-ops (synthetic path still works) =="
mutate "    if (!self) return;
    self->dispatchKeyEvent(key, scancode, action, mods);" "    // MUTANT M4: callback registered but forwards nothing
    (void)self; (void)key; (void)scancode; (void)action; (void)mods;"
run_gate "$BAK/m4.log" || true
expect_killed M4 "$BAK/m4.log" "REAL key press|never fired"
restore

echo "MUTATION_VERIFY_KEY_EVENTS_PASS: control PASS, M1-M4 each FAIL the gate"
