#!/usr/bin/env bash
# MUTATION TEST for tools/ci-trace.sh (FP-02). Each mutant edits engine source,
# rebuilds, and must turn the gate red for its own reason; the source is
# restored and the clean engine re-gated at the end.
#
#   M1  End() records two end events -> end with no open span
#   M2  one thread id shared by every thread -> span on the wrong thread
#   M3  tracing enabled by default -> arm A sees events with tracing off
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TR="engine/base/Trace.cpp"
BACKUP="$(mktemp -d)"
cp "$TR" "$BACKUP/Trace.cpp"
restore() { cp "$BACKUP/Trace.cpp" "$TR"; }
trap 'restore; echo "(engine source restored; rebuild with tools/engine-build.sh)" >&2' EXIT

build() { bash tools/engine-build.sh linux x64 > "$1" 2>&1 || { tail -20 "$1" >&2; echo "MUTATE_FAIL: build failed" >&2; exit 1; }; }
gate()  { bash tools/ci-trace.sh > "$1" 2>&1; }

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
  if ! grep -q 'TRACE_GATE_FAIL' "$2"; then
    echo "MUTATE_FAIL: $1 SURVIVED -- ci-trace stayed GREEN" >&2; exit 1
  fi
  grep -qE "$3" "$2" || { echo "MUTATE_FAIL: $1 killed for the WRONG reason:" >&2; grep -m3 'FAIL' "$2" >&2; exit 1; }
  echo "   $1 killed: $(grep -m1 -E "$3" "$2" | sed 's/^ *//' | cut -c1-160)"
}

echo "== M1: unbalanced end =="
mutate "$TR" "void End() { Push('E', \"\", \"\", nullptr, 0); }" \
  "void End() { Push('E', \"\", \"\", nullptr, 0); Push('E', \"\", \"\", nullptr, 0); }  // MUTANT M1"
build "$BACKUP/m1-build.log"; gate "$BACKUP/m1.log" || true
expect_killed M1 "$BACKUP/m1.log" 'TRACE_FAIL: end event with no open span'
restore

echo "== M2: every thread shares one tid =="
mutate "$TR" "  thread_local const int tid" "  static const int tid /* MUTANT M2 */"
build "$BACKUP/m2-build.log"; gate "$BACKUP/m2.log" || true
expect_killed M2 "$BACKUP/m2.log" 'TRACE_FAIL: span [A-Za-z]+ recorded on thread [a-z-]+, expected'
restore

echo "== M3: tracing left on when off =="
mutate "$TR" "std::atomic<bool> gEnabled{false};" "std::atomic<bool> gEnabled{true};  // MUTANT M3"
build "$BACKUP/m3-build.log"; gate "$BACKUP/m3.log" || true
expect_killed M3 "$BACKUP/m3.log" 'off-mode: rn-impeller: trace enabled=1 events=[1-9]'
restore

echo "== RESTORE: clean engine must be GREEN =="
build "$BACKUP/final-build.log"
gate "$BACKUP/final.log" || { tail -15 "$BACKUP/final.log" >&2; echo "MUTATE_FAIL: gate RED after restore" >&2; exit 1; }
echo "   $(grep -o 'TRACE_PASS.*' "$BACKUP/final.log")"
trap - EXIT
rm -rf "$BACKUP"
echo "MUTATE_TRACE_OK -- 3 mutants, 3 killed, engine restored and green"
