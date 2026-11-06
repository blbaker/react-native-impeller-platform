#!/usr/bin/env bash
# MUTATION VERIFICATION for tools/ci-touch-scroll.sh.
#
# The gate was written before the fix and watched failing on the old engine
# (no onScrollBeginDrag at all). Each mutant below removes ONE property the
# gate claims to prove; each must be killed by the arm aimed at it.
#
#   M1 no claim        a drag never becomes a scroll          -> A: no begin-drag
#   M2 no JS cancel    the pressed row keeps its touch         -> A: no touchcancel
#   M3 no slop         any move is a drag, even tap jitter     -> D: jitter tap
#   M4 no paging       a paged release just stops              -> C1: settle 600
#   M5 mouse scrolls   desktop mouse drags scroll too          -> E: mouse drag
#   M6 no fling        a moving lift just stops                -> B: no momentum
#   M7 cancel = move   tcancel's far-away point scrolls        -> G: end at 390
set -euo pipefail
cd "$(dirname "$0")/.."
FH="engine/fabric/FabricHostTouchScroll.cpp"
MAIN="engine/host/main.cpp"
BAK="$(mktemp -d)"
cp "$FH" "$BAK/fh.cpp"
cp "$MAIN" "$BAK/main.cpp"
# cp, not cp -p: the restored file must be NEWER than the mutant's object or
# ninja keeps the mutant linked in.
restore() { cp "$BAK/fh.cpp" "$FH"; cp "$BAK/main.cpp" "$MAIN"; touch "$FH" "$MAIN"; }
trap 'restore; rm -rf "$BAK"' EXIT
fail() { echo "MUTATION_VERIFY_FAIL: $*" >&2; exit 1; }

grep -q 'TS_MUTANT' "$FH" "$MAIN" && fail "mutant residue already in the tree (grep TS_MUTANT) -- restore it first"
grep -q 'touchScrollMove' "$FH" || fail "the fix is not in the tree -- a passing gate here would be blind"

build() { bash tools/engine-build.sh > "$BAK/build.log" 2>&1 || { tail -20 "$BAK/build.log" >&2; fail "$1 tree did not build"; }; }
run_gate() {  # $1 log; exit status comes from the gate, not a pipe
  set +e
  RNI_SKIP_BUILD=1 bash tools/ci-touch-scroll.sh > "$1" 2>&1
  local rc=$?
  set -e
  return $rc
}
# mutate FILE OLD NEW: exactly one occurrence, tagged TS_MUTANT.
mutate() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
assert s.count(old) == 1, "anchor not found once: " + old[:60]
open(p, "w").write(s.replace(old, new + " /* TS_MUTANT */"))
PY
}
# expect NAME LOG PATTERN: the gate failed, and on the arm aimed at it.
expect() {
  if run_gate "$2"; then fail "$1 SURVIVED: the gate passes with this property removed"; fi
  grep -q "TOUCH_SCROLL_GATE_FAIL: $3" "$2" || {
    grep -E 'GATE_FAIL|exited' "$2" | tail -3 >&2
    fail "$1 was killed, but not by the arm aimed at it (want '$3')"
  }
  echo "   OK: $1 killed ($(grep -o 'TOUCH_SCROLL_GATE_FAIL: [A-Z0-9]*' "$2"))"
}

echo "== control: unmutated tree must PASS =="
build control
run_gate "$BAK/control.log" || { tail -20 "$BAK/control.log" >&2; fail "the gate fails on the UNMUTATED tree"; }
grep -q TOUCH_SCROLL_GATE_PASS "$BAK/control.log" || fail "control did not print TOUCH_SCROLL_GATE_PASS"
echo "   OK: control passes"

echo "== M1 no claim =="
mutate "$FH" "  if (t.state.tag == 0) return false;" "  return false;"
build M1; expect M1 "$BAK/m1.log" "A: no onScrollBeginDrag"; restore

echo "== M2 no JS cancel =="
mutate "$FH" "  cancelTouchCapture(x, y);
  endTextSelectionDrag();" "  endTextSelectionDrag();"
build M2; expect M2 "$BAK/m2.log" "A: JS never got touchcancel"; restore

echo "== M3 no slop =="
mutate "$FH" "if (std::fabs(dx) <= ts::kSlopPt && std::fabs(dy) <= ts::kSlopPt) return false;" \
  "if (dx == 0.0f && dy == 0.0f) return false;"
build M3; expect M3 "$BAK/m3.log" "D: a tap with 4 pt of jitter"; restore

echo "== M4 no paging =="
mutate "$FH" "  if (g.paging && g.page > 0.0f) {" "  if (false) {"
build M4; expect M4 "$BAK/m4.log" "C1: a 400 pt drag"; restore

echo "== M5 mouse drags scroll =="
python3 - "$MAIN" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
assert s.count("    if (surface.inputIsTouch()) {") == 2
open(p, "w").write(s.replace("    if (surface.inputIsTouch()) {", "    if (true) { /* TS_MUTANT */"))
PY
build M5; expect M5 "$BAK/m5.log" "E: a MOUSE drag scrolled"; restore

echo "== M6 no fling =="
mutate "$FH" "  } else if (ts::Flings(v, g.decel)) {" "  } else if (false) {"
build M6; expect M6 "$BAK/m6.log" "B: no onMomentumScrollBegin"; restore

echo "== M7 cancel handled as a move =="
mutate "$MAIN" "      const bool scrolling = surface.touchCancelling()
                                 ? fabric.touchScrollUp(x, y, true)
                                 : fabric.touchScrollMove(x, y);" \
  "      const bool scrolling = fabric.touchScrollMove(x, y);"
build M7; expect M7 "$BAK/m7.log" "G: a cancel should end the drag"; restore

echo "== restore + rebuild + control again (the restore must take) =="
trap - EXIT
restore
build restored
run_gate "$BAK/final.log" || { tail -20 "$BAK/final.log" >&2; fail "the gate fails after restore -- a mutant is still linked in"; }
grep -c TS_MUTANT "$FH" "$MAIN" | grep -q ':[1-9]' && fail "TS_MUTANT marker left in the tree"
rm -rf "$BAK"
echo "MUTATION_VERIFY_PASS (7/7 killed: claim, JS cancel, slop, paging, touch-only, fling, cancel)"
