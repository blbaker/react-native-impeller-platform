#!/usr/bin/env bash
# Does mutation-verify-concave.py actually go red? A verifier that only ever
# prints VERIFY_OK is the exact defect it exists to catch, one level up.
# Each mutant is applied to a COPY of the tree; the real files are never touched.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/tools" "$WORK/fixtures/concave-probe"
cp "$ROOT/tools/ci-concave.sh" "$ROOT/tools/mutation-verify-concave.py" "$WORK/tools/"
cp "$ROOT/fixtures/concave-probe/index.js" "$WORK/fixtures/concave-probe/"

G="$WORK/tools/ci-concave.sh"; F="$WORK/fixtures/concave-probe/index.js"
G0="$(cat "$G")"; F0="$(cat "$F")"
kills=0; survivors=()

# run the verifier against $WORK rather than $HOME/projects/...
run() { HOME="$WORK/home" python3 - "$WORK" <<'PY' 2>&1 || true
import pathlib, runpy, sys
root = pathlib.Path(sys.argv[1])
src = (root / "tools/mutation-verify-concave.py").read_text()
src = src.replace('pathlib.Path.home() / "projects/react-native-impeller"', f'pathlib.Path("{root}")')
exec(compile(src, "mv", "exec"), {"__name__": "__main__"})
PY
}

mutate() { # name, sed-target-file, from, to
  local name="$1" file="$2" from="$3" to="$4"
  printf '%s' "$G0" > "$G"; printf '%s' "$F0" > "$F"
  python3 - "$file" "$from" "$to" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
assert sys.argv[2] in s, f"ANCHOR NOT FOUND: {sys.argv[2]!r} -- the code this mutant targets moved"
p.write_text(s.replace(sys.argv[2], sys.argv[3], 1))
PY
  if run | grep -q VERIFY_FAIL; then
    echo "  KILLED   $name"; kills=$((kills+1))
  else
    echo "  SURVIVED $name"; survivors+=("$name")
  fi
}

echo "== baseline must be green =="
printf '%s' "$G0" > "$G"; printf '%s' "$F0" > "$F"
run | grep -q VERIFY_OK || { echo "MUTVERIFY_FAIL: clean tree is not green"; exit 1; }
echo "  ok  clean tree -> VERIFY_OK"

echo "== mutants =="
# 1. a wrong expected value -- the ORIGINAL defect, restated
mutate "want[E] 4600 -> 4500 (stale ledger value)" "$G" \
  "want=[6400,3200,4800,4800,4600]" "want=[6400,3200,4800,4800,4500]"
# 2. a wrong wrong-answer column -- the C-hull defect, restated
mutate "hull[C] 5600 -> 6400 (hull confused with bbox)" "$G" \
  "hull=[6400,3200,5600,6400,6400]" "hull=[6400,3200,6400,6400,6400]"
# 3. fixture geometry reverted to the un-failable E
mutate "fixture E reverted to the notched pentagon" "$F" \
  "'M10 10 L50 55 L90 10 L90 90 L10 90 Z'" "'M10 50 L30 35 L50 10 L90 50 L50 90 Z'"
# 4. verdict collapsed to a constant
mutate "verdict branch CONVEX-HULL deleted" "$G" \
  'verdict="CONVEX-HULL"' 'verdict="TRUE-AREA"'
# 5. the clearance tripwire removed
mutate "clearance precondition deleted" "$G" \
  "cannot distinguish true from hull" "clearance check removed"

printf '%s' "$G0" > "$G"; printf '%s' "$F0" > "$F"
echo
if [ ${#survivors[@]} -eq 0 ]; then
  echo "MUTVERIFY_PASS: $kills/5 mutants killed"
else
  echo "MUTVERIFY_FAIL: survivors: ${survivors[*]}"; exit 1
fi
