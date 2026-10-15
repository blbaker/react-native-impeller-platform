#!/usr/bin/env bash
# MUTATION TEST for tools/ci-native-transform.sh. Each mutant edits ENGINE
# SOURCE (never the fixture), rebuilds, and must turn the gate red FOR ITS OWN
# REASON; the source is restored and the clean engine re-gated at the end.
#
#   M1  drop the operation-list branch in SceneGraph::updateViewProps
#       -> the original DS-INPUT-SPIN defect: ticks count, transform skipped.
#          Expect arm A (rotate) to name it.
#   M2  stop counting JS timer callbacks (ReactHost timer-fire hook)
#       -> js_timers would read 0 for ANY app, so arm E's zero for the native
#          loop would prove nothing. Expect the JS-driven control to catch it.
#   M3  stop counting mounting transactions (SceneGraph::applyMutations)
#       -> same, for mount_tx.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SG="engine/scenegraph/SceneGraph.cpp"
HOSTCPP="engine/runtime/ReactHost.cpp"
BACKUP="$(mktemp -d)"
cp "$SG" "$BACKUP/SceneGraph.cpp"
cp "$HOSTCPP" "$BACKUP/ReactHost.cpp"
restore() { cp "$BACKUP/SceneGraph.cpp" "$SG"; cp "$BACKUP/ReactHost.cpp" "$HOSTCPP"; }
trap 'restore; echo "(engine source restored; rebuild with tools/engine-build.sh)" >&2' EXIT

build() { bash tools/engine-build.sh linux x64 > "$1" 2>&1 || { tail -20 "$1" >&2; echo "MUTATE_FAIL: build failed" >&2; exit 1; }; }
gate()  { bash tools/ci-native-transform.sh > "$1" 2>&1; }

mutate() {  # file old new
  python3 - "$1" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
n = s.count(old)
assert n == 1, "anchor found %dx in %s" % (n, p)
open(p, "w").write(s.replace(old, new, 1))
PY
}

expect_killed() {  # name log ERE
  if ! grep -q 'NT_FAIL' "$2"; then
    echo "MUTATE_FAIL: $1 SURVIVED -- ci-native-transform stayed GREEN" >&2; exit 1
  fi
  grep -qE "$3" "$2" || { echo "MUTATE_FAIL: $1 killed for the WRONG reason:" >&2; grep -m3 'FAIL' "$2" >&2; exit 1; }
  echo "   $1 killed: $(grep -m1 -E "$3" "$2" | sed 's/^ *//' | cut -c1-150)"
}

echo "== M1: transform operation list ignored again =="
mutate "$SG" '      if (!flatMatrix) {
        react::Transform ops;' '      if (!flatMatrix) continue;  // MUTANT M1
      if (false) {
        react::Transform ops;'
build "$BACKUP/m1-build.log"; gate "$BACKUP/m1.log" || true
expect_killed M1 "$BACKUP/m1.log" 'rotate frozen|rotate frame [0-9]+: bbox'
restore

echo "== M2: JS timer counter never increments =="
mutate "$HOSTCPP" '        fired->fetch_add(1, std::memory_order_relaxed);' '        (void)fired;  // MUTANT M2'
build "$BACKUP/m2-build.log"; gate "$BACKUP/m2.log" || true
expect_killed M2 "$BACKUP/m2.log" 'control shows js_timers=0'
restore

echo "== M3: mounting-transaction counter never increments =="
mutate "$SG" '    mountTransactions_.fetch_add(1, std::memory_order_relaxed);' '    // MUTANT M3'
build "$BACKUP/m3-build.log"; gate "$BACKUP/m3.log" || true
expect_killed M3 "$BACKUP/m3.log" 'control shows mount_tx=0'
restore

echo "== RESTORE: clean engine must be GREEN =="
build "$BACKUP/final-build.log"
gate "$BACKUP/final.log" || { tail -15 "$BACKUP/final.log" >&2; echo "MUTATE_FAIL: gate RED after restore" >&2; exit 1; }
echo "   $(grep -o 'NATIVE_TRANSFORM_PASS.\{0,60\}' "$BACKUP/final.log")"
trap - EXIT
rm -rf "$BACKUP"
echo "MUTATE_NATIVE_TRANSFORM_OK -- 3 mutants, 3 killed, engine restored and green"
