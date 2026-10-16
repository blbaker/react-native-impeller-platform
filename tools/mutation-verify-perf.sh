#!/usr/bin/env bash
# MUTATION TEST for tools/ci-perf.sh (FP-53). Engine mutant rebuilds; the others are offline.
#
#   M1  5 ms sleep in the record phase (SceneGraph::paint)        -> record/total p95 over budget
#   M2  one wildly noisy run in five (offline, real budgets)      -> must NOT fail (median)
#   M3  three noisy runs in five                                  -> must FAIL (median moves)
#   M4  budgets halved (offline copy via RNI_PERF_BUDGETS)        -> must FAIL (gate reads the file)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
SRC="engine/scenegraph/Modal.cpp"
BACKUP="$(mktemp -d)"; cp "$SRC" "$BACKUP/Modal.cpp"
restore() { cp "$BACKUP/Modal.cpp" "$SRC"; }
trap 'restore; echo "(engine source restored; rebuild with tools/engine-build.sh)" >&2' EXIT
die() { echo "MUTATE_FAIL: $*" >&2; exit 1; }

echo "== M2/M3/M4: offline, synthetic runs built from the committed baselines =="
python3 - "$BACKUP" <<'PY'
import json, sys
b = json.load(open("tools/perf/budgets.json"))
for tag, noisy in (("clean", 0), ("one", 1), ("three", 3)):
    import os
    d = "%s/runs-%s" % (sys.argv[1], tag); os.makedirs(d)
    for fx, ent in b["fixtures"].items():
        for i in range(5):
            r = dict(ent["baseline"], frames=121, control_ms=ent["control_ms"])
            if i < noisy:  # a loaded-box run: everything 20x slower
                r = {k: (v if k in ("frames", "control_ms") else v * 20) for k, v in r.items()}
            json.dump(r, open("%s/%s.%d.run.json" % (d, fx, i + 1), "w"))
d = json.load(open("tools/perf/budgets.json"))
for ent in d["fixtures"].values():
    ent["baseline"] = {k: v // 2 for k, v in ent["baseline"].items()}
    ent["spread"] = {k: 0 for k in ent["spread"]}
json.dump(d, open(sys.argv[1] + "/budgets-half.json", "w"))
PY
cmp() { python3 tools/perf/perf_compare.py compare "$@"; }
cmp tools/perf/budgets.json "$BACKUP/runs-clean" > "$BACKUP/clean.txt" || die "baseline runs fail their own budgets"
cmp tools/perf/budgets.json "$BACKUP/runs-one" > "$BACKUP/m2.txt" || { grep -m3 FAIL "$BACKUP/m2.txt" >&2; die "M2 one noisy run in five failed the median"; }
echo "   M2 ok: one noisy run in five passes (median unmoved)"
cmp tools/perf/budgets.json "$BACKUP/runs-three" > "$BACKUP/m3.txt" && die "M3 SURVIVED: three noisy runs in five still pass"
echo "   M3 killed: $(grep -m1 PERF_FAIL "$BACKUP/m3.txt" | cut -c1-120)"
cmp "$BACKUP/budgets-half.json" "$BACKUP/runs-clean" > "$BACKUP/m4.txt" && die "M4 SURVIVED: halved budgets still pass"
echo "   M4 killed: $(grep -m1 PERF_FAIL "$BACKUP/m4.txt" | cut -c1-120)"

echo "== M1: 5 ms sleep in record =="
python3 - "$SRC" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "  std::vector<react::EventEmitter::Shared> shows;\n  int painted;\n  {\n    std::lock_guard<std::mutex> lock(mutex_);\n    painted = paintLocked("
assert s.count(old) == 1, s.count(old)
s = s.replace(old, "  std::this_thread::sleep_for(std::chrono::milliseconds(5));  // MUTANT M1\n" + old, 1)
s = s.replace("#include <cstdio>\n", "#include <chrono>\n#include <cstdio>\n#include <thread>\n", 1)
open(p, "w").write(s)
PY
bash tools/engine-build.sh linux x64 > "$BACKUP/m1-build.log" 2>&1 || { tail -20 "$BACKUP/m1-build.log" >&2; die "M1 build failed"; }
bash tools/ci-perf.sh > "$BACKUP/m1.log" 2>&1 && die "M1 SURVIVED: ci-perf stayed GREEN with a 5 ms record sleep"
grep -qE 'PERF_FAIL: [a-z0-9-]+ record_p95_us median' "$BACKUP/m1.log" || { grep -m3 FAIL "$BACKUP/m1.log" >&2; die "M1 killed for the WRONG reason"; }
echo "   M1 killed: $(grep -m1 -E 'PERF_FAIL: [a-z0-9-]+ record_p95_us' "$BACKUP/m1.log" | cut -c1-130)"

echo "== RESTORE: clean engine must be GREEN =="
restore
bash tools/engine-build.sh linux x64 > "$BACKUP/final-build.log" 2>&1 || die "final build failed"
bash tools/ci-perf.sh > "$BACKUP/final.log" 2>&1 || { tail -15 "$BACKUP/final.log" >&2; die "clean engine not green"; }
trap - EXIT
echo "MUTATION_PERF_PASS (M1 killed, M2 tolerated, M3 killed, M4 killed, clean green)"
