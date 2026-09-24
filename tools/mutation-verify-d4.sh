#!/usr/bin/env bash
# MUTATION VERIFY D4: prove the gate goes RED when the crossing is removed.
#
# A gate that has only ever been green proves nothing. The specific claim under
# test is "D4 detects native-perfect + JS-silent", so the mutant is exactly that
# build: delete the emit, leave every other line of the resize path intact.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/portable-timeout.sh"  # portable timeout (mac fallback)
cd $HOME/projects/react-native-impeller
export DISPLAY=:0
SRC=engine/host/main.cpp
cp "$SRC" /tmp/d4.pristine
restore() { cp /tmp/d4.pristine "$SRC"; }
trap restore EXIT

run() {
  bash tools/engine-build.sh >/tmp/d4-build.log 2>&1 || { echo "BUILD_FAIL"; return; }
  timeout 900 bash tools/ci-d4-dimensions-crossing.sh 2>&1 | tail -3
}

echo "=== BASELINE (pristine) ==="
run

echo
echo "=== MUTANT: delete the emit. Native resize stays perfect, JS is never told. ==="
python3 - <<'PY'
import re
p="engine/host/main.cpp"
s=open(p).read()
s2=s.replace(
 '''    host.deviceEvents()->emit("didUpdateDimensions",
                              host.displayMetrics()->toDimensionsDynamic());''',
 '''    // MUTANT: emit removed''')
assert s2!=s, "mutation did not apply"
open(p,"w").write(s2)
print("emit removed")
PY
run
restore

echo
echo "=== RESTORED BASELINE ==="
run
