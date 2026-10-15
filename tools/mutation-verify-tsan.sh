#!/usr/bin/env bash
# FP-04 mutants for tools/ci-tsan.sh. Each arm edits anchored source (restored by a trap),
# rebuilds the TSan binary through the gate, and must make it FAIL naming the defect.
#   A  SceneGraph::applyMutations drops its mutex_ lock     -> new data race in SceneGraph
#   B  the scene version counter becomes a plain uint64_t   -> new data race on version()/bumpVersion
#   C  measure shares paint's typography context again (FP-12 per-thread slot made process-wide)
#                                                            -> new typography-context race
#      (until FP-12 this arm made NoteExclusiveUse a no-op and expected the then-known race to go
#      unseen; FP-12 fixed that race, so the arm now re-introduces it instead)
# Arms run only the stress fixture (TSAN_RUNS): JS commits overlap main paints, and its <Image>
# re-fetches so the fetch thread bumps the scene version while main reads it (--idle-skip).
set -uo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.local/bin:$PATH"; unset RNI_BIN
LOG="$(mktemp -d "${TMPDIR:-/tmp}/mut-tsan.XXXX")"
killed=0
FILES=(engine/scenegraph/SceneGraph.cpp engine/scenegraph/SceneGraph.h engine/text/TypographyContexts.cpp)
for f in "${FILES[@]}"; do cp "$f" "$LOG/$(basename "$f").bak"; done
restore() { for f in "${FILES[@]}"; do cp "$LOG/$(basename "$f").bak" "$f"; done; }
trap restore EXIT
die() { echo "MUTATION_TSAN_FAIL: $*"; exit 1; }

mutate() {  # file old new  (old must occur exactly once)
  python3 - "$@" <<'EOF' || die "anchor not found exactly once in $1"
import sys
p, old, new = sys.argv[1:]
s = open(p).read()
if s.count(old) != 1:
    sys.exit(1)
open(p, "w").write(s.replace(old, new))
EOF
}

arm() {  # name expected-regex
  local name="$1" want="$2" rc
  TSAN_RUNS="churn-window churn-headless" bash tools/ci-tsan.sh > "$LOG/$name.log" 2>&1; rc=$?
  restore
  if [ "$rc" = 0 ] || ! grep -q '^TSAN_FAIL' "$LOG/$name.log"; then
    tail -6 "$LOG/$name.log"; die "arm $name SURVIVED: ci-tsan passed"
  fi
  grep -qE "$want" "$LOG/$name.log" || { tail -15 "$LOG/$name.log"; die "arm $name failed for the wrong reason (want /$want/)"; }
  echo "killed $name: $(grep -m1 '^TSAN_FAIL' "$LOG/$name.log" | cut -c1-200)"
  killed=$((killed + 1))
}

mutate engine/scenegraph/SceneGraph.cpp \
'    const react::ShadowViewMutation::List& mutations, bool log) {
  std::lock_guard<std::mutex> lock(mutex_);
' \
'    const react::ShadowViewMutation::List& mutations, bool log) {
  // MUTANT A: no mutex_ lock
'
arm A '^  NEW \[churn-[a-z]+\] data race in rni::SceneGraph::'

mutate engine/scenegraph/SceneGraph.h \
'  uint64_t version() const { return version_.load(std::memory_order_acquire); }' \
'  uint64_t version() const { return *reinterpret_cast<const uint64_t*>(&version_); }  // MUTANT B'
mutate engine/scenegraph/SceneGraph.cpp \
'  version_.fetch_add(1, std::memory_order_release);' \
'  ++*reinterpret_cast<uint64_t*>(&version_);  // MUTANT B'
arm B '^  NEW \[churn-[a-z]+\] data race in rni::SceneGraph::(version|bumpVersion)'

mutate engine/text/TypographyContexts.cpp \
'thread_local Slot tSlot;' \
'Slot tSlot;  // MUTANT C: one typography context for every thread'
arm C '^  NEW \[churn-[a-z]+\] typography-context race'


trap - EXIT
for f in "${FILES[@]}"; do cmp -s "$f" "$LOG/$(basename "$f").bak" || die "$f not restored"; done
rm -rf "$LOG"
echo "MUTATION_TSAN_PASS ($killed/3 mutants killed)"
