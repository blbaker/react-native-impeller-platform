#!/usr/bin/env bash
# MUTATION VERIFICATION for tools/ci-prewarm.sh (FP-34). Each mutant must FAIL the gate and the FAIL
# line must name the arm it breaks.
#   M1  the tour is never run                          -> coverage: the tour did not run
#   M2  the tour draws one blend mode, not all of them -> coverage: blend_modes=1
#   M3  the tour is built and reported but never drawn -> first-use: first use still costs / not <= 65%
set -euo pipefail
cd "$(dirname "$0")/.."
FILES=(engine/host/main.cpp engine/scenegraph/PrewarmTour.cpp engine/scenegraph/SupersampleBackendGl.cpp)
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
  set +e; bash tools/ci-prewarm.sh > "$1" 2>&1; set -e; }
expect_killed() {  # name log ERE
  grep -q PREWARM_GATE_PASS "$2" && fail "$1 SURVIVED"
  grep -qE "PREWARM_GATE_FAIL: .*($3)" "$2" || { tail -5 "$2" >&2; fail "$1 killed by the wrong assertion (wanted '$3')"; }
  echo "   OK: $1 killed -> $(grep -m1 PREWARM_GATE_FAIL "$2")"
}

echo "== control =="
run_gate "$BAK/c.log"; grep -q PREWARM_GATE_PASS "$BAK/c.log" || { tail -5 "$BAK/c.log" >&2; fail "control fails"; }
echo "   OK: control passes"

echo "== M1: tour skipped =="
mutate engine/host/main.cpp "  if (gPrewarm) {
    rni::RunPrewarmTour" "  if (false) {
    rni::RunPrewarmTour"
run_gate "$BAK/m1.log"; expect_killed M1 "$BAK/m1.log" "coverage: the tour did not run"
restore

echo "== M2: tour misses blend modes =="
mutate engine/scenegraph/PrewarmTour.cpp "for (ImpellerBlendMode mode : kBlendModes) {" "for (ImpellerBlendMode mode : {kImpellerBlendModeSourceOver}) {"
run_gate "$BAK/m2.log"; expect_killed M2 "$BAK/m2.log" "coverage: blend_modes=1,"
restore

echo "== M3: tour never drawn =="
mutate engine/scenegraph/SupersampleBackendGl.cpp '  TRACE_EVENT0("raster", "PrewarmTour");' '  TRACE_EVENT0("raster", "PrewarmTour");
  if (dl != nullptr) return true;'
run_gate "$BAK/m3.log"; expect_killed M3 "$BAK/m3.log" "first-use: (tour median|with the tour, first use still costs)"
restore
echo "MUTATION_VERIFY_PASS (3 mutants killed)"
