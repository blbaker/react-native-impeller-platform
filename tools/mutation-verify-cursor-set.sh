#!/usr/bin/env bash
# MUTATION VERIFICATION for tools/ci-cursor-set.sh (SC-21). Each mutant must
# FAIL the gate and the FAIL line must name the row it breaks.
#   M1  se-resize falls through to arrow             -> row 13 (se-resize)
#   M2  not-allowed / no-drop map to arrow          -> row 8 (not-allowed)
#   M3  host applies the arrow for crosshair        -> row 2 (crosshair, applied)
set -euo pipefail
cd "$(dirname "$0")/.."
KH="engine/scenegraph/CursorKinds.h"; GS="engine/host/GlfwSurface.cpp"
BAK="$(mktemp -d)"
cp "$KH" "$BAK/KH"; cp "$GS" "$BAK/GS"
restore() { cp "$BAK/KH" "$KH"; cp "$BAK/GS" "$GS"; }
trap 'restore; bash tools/engine-build.sh linux x64 > /dev/null 2>&1 || true' EXIT
fail() { echo "MUTATION_VERIFY_FAIL: $*" >&2; exit 1; }

mutate() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
assert s.count(old) == 1, "mutant anchor not found exactly once in %s: %r" % (p, old[:80])
open(p, "w").write(s.replace(old, new, 1))
PY
}
run_gate() { bash tools/engine-build.sh linux x64 > "$BAK/build.log" 2>&1 || { tail "$BAK/build.log" >&2; fail "build"; }
  set +e; bash tools/ci-cursor-set.sh > "$1" 2>&1; set -e; }
expect_killed() {  # name log ERE
  grep -q CURSOR_SET_GATE_PASS "$2" && fail "$1 SURVIVED"
  grep -qE "CURSOR_SET_GATE_FAIL: .*($3)" "$2" || { tail -5 "$2" >&2; fail "$1 killed by the wrong assertion (wanted '$3')"; }
  echo "   OK: $1 killed -> $(grep -m1 CURSOR_SET_GATE_FAIL "$2")"
}

echo "== control =="
run_gate "$BAK/c.log"; grep -q CURSOR_SET_GATE_PASS "$BAK/c.log" || { tail -5 "$BAK/c.log" >&2; fail "control fails"; }
echo "   OK: control passes"

echo "== M1: se-resize falls through to arrow =="
mutate "$KH" '    case Cursor::SEResize:
    case Cursor::NWSEResize:' '    case Cursor::NWSEResize:'
run_gate "$BAK/m1.log"; expect_killed M1 "$BAK/m1.log" "row 13 "
restore

echo "== M2: not-allowed mapped to arrow =="
mutate "$KH" '    case Cursor::NotAllowed:
    case Cursor::NoDrop:
      return kCursorNotAllowed;' '    case Cursor::NoDrop:
      return kCursorNotAllowed;'
run_gate "$BAK/m2.log"; expect_killed M2 "$BAK/m2.log" "row 8 "
restore

echo "== M3: host applies arrow for crosshair =="
mutate "$GS" '  } else if (kind > 0 && kind < rni::kCursorKindCount && shapeCursors_[kind]) {' '  } else if (kind > 0 && kind < rni::kCursorKindCount && kind != rni::kCursorCrosshair && shapeCursors_[kind]) {'
run_gate "$BAK/m3.log"; expect_killed M3 "$BAK/m3.log" "row 2 "
restore
echo "MUTATION_VERIFY_PASS (3 mutants killed)"
