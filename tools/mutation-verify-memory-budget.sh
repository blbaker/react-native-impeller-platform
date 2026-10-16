#!/usr/bin/env bash
# MUTATION VERIFICATION for tools/ci-memory-budget.sh (FP-33). Each mutant must FAIL the gate and the
# FAIL line must name the check it breaks.
#   M1  low-memory purge is a no-op                      -> purge: cache holds N bytes after the signal
#   M2  the LRU evicts the most recently used entry      -> cycle: reloads= (recent images were evicted)
#   M3  inserts never trim to the budget                 -> cycle: cache peak exceeds the 6 MB budget
#   M4  textures of evicted bitmaps are never released   -> purge: textures_live= (leaked next to the reloads)
#   M5  evicted visible images are never reloaded        -> purge: reloads= (did not repaint)
set -euo pipefail
cd "$(dirname "$0")/.."
FILES=(engine/fabric/ImageCache.cpp engine/scenegraph/ImagePaint.cpp)
BAK="$(mktemp -d)"
for i in "${!FILES[@]}"; do cp "${FILES[$i]}" "$BAK/$i"; done
restore() { for i in "${!FILES[@]}"; do cp "$BAK/$i" "${FILES[$i]}"; done; }
trap 'restore; trap - EXIT; bash tools/engine-build.sh linux x64 > /dev/null 2>&1 || true; rm -rf "$BAK"' EXIT
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
  set +e; bash tools/ci-memory-budget.sh > "$1" 2>&1; set -e; }
expect_killed() {  # name log ERE
  grep -q MEMORY_BUDGET_GATE_PASS "$2" && fail "$1 SURVIVED"
  grep -qE "MEMORY_BUDGET_GATE_FAIL: .*($3)" "$2" || { tail -5 "$2" >&2; fail "$1 killed by the wrong assertion (wanted '$3')"; }
  echo "   OK: $1 killed -> $(grep -m1 MEMORY_BUDGET_GATE_FAIL "$2")"
}

echo "== control =="
run_gate "$BAK/c.log"; grep -q MEMORY_BUDGET_GATE_PASS "$BAK/c.log" || { tail -5 "$BAK/c.log" >&2; fail "control fails"; }
echo "   OK: control passes"

echo "== M1: purge is a no-op =="
mutate engine/fabric/ImageCache.cpp "  TrimLocked(floor_, 0);
  return before - bytes_;" "  return before - bytes_;"
run_gate "$BAK/m1.log"; expect_killed M1 "$BAK/m1.log" "purge: cache holds"
restore

echo "== M2: LRU evicts the most recently used =="
mutate engine/fabric/ImageCache.cpp "EvictLocked(std::prev(lru_.end()))" "EvictLocked(lru_.begin())"
run_gate "$BAK/m2.log"; expect_killed M2 "$BAK/m2.log" "cycle: reloads="
restore

echo "== M3: inserts never trim =="
mutate engine/fabric/ImageCache.cpp "  TrimLocked(budget_, 1);
  if (bytes_ > peak_)" "  if (bytes_ > peak_)"
run_gate "$BAK/m3.log"; expect_killed M3 "$BAK/m3.log" "cycle: cache peak [0-9]+ bytes exceeds"
restore

echo "== M4: evicted bitmaps keep their textures =="
mutate engine/scenegraph/ImagePaint.cpp "  if (epoch == sweptEpoch_) return;" "  if (true) return;"
run_gate "$BAK/m4.log"; expect_killed M4 "$BAK/m4.log" "purge: textures_live="
restore

echo "== M5: evicted visible images are not reloaded =="
mutate engine/scenegraph/ImagePaint.cpp "    if (f.evicted) image::Reload(uri, boxW, boxH, reloadWake_);
    else f.image" "    if (f.evicted) {}
    else f.image"
run_gate "$BAK/m5.log"; expect_killed M5 "$BAK/m5.log" "purge: reloads="
restore
echo "MUTATION_VERIFY_PASS (5 mutants killed)"
