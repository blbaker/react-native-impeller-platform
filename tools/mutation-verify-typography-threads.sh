#!/usr/bin/env bash
# FP-12 mutants for tools/ci-typography-threads.sh. Each arm edits anchored source (restored by a
# trap), rebuilds the release binary (arm A of the gate) and the TSan binary (the gate's arm C
# builds it), and the gate must FAIL with the line written for that defect.
#   A  the per-thread slot becomes process-wide: measure (js) shares paint's context again
#      -> TSan names a typography-context race
#   B  --font-dir fonts register into the paint context only (not the shared list)
#      -> the custom-font row measures in the fallback face, paints in Geist Mono
#   C  a fallback face registers only into the context of the thread that found it
#      -> a fallback run (seen: the bold row's U+2588 face, 8 px narrower in paint) measures in
#         one face and paints in another; faces fontconfig also serves by family name can still
#         match, so the arm accepts any row
# Rebuild the clean binaries after this script (tools/engine-build.sh).
set -uo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.local/bin:$PATH"; unset RNI_BIN
LOG="$(mktemp -d "${TMPDIR:-/tmp}/mut-typo.XXXX")"
killed=0
FILES=(engine/text/TypographyContexts.cpp engine/text/FontRegistry.cpp engine/text/FontFallback.cpp)
for f in "${FILES[@]}"; do cp "$f" "$LOG/$(basename "$f").bak"; done
restore() { for f in "${FILES[@]}"; do cp "$LOG/$(basename "$f").bak" "$f"; done; }
trap restore EXIT
die() { echo "MUTATION_TYPO_FAIL: $*"; exit 1; }

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

arm() {  # name expected-regex [gate env...]
  local name="$1" want="$2" rc; shift 2
  bash tools/engine-build.sh linux x64 > "$LOG/$name.build.log" 2>&1 \
    || { restore; tail -20 "$LOG/$name.build.log"; die "arm $name: release build failed"; }
  env "$@" bash tools/ci-typography-threads.sh > "$LOG/$name.log" 2>&1; rc=$?
  restore
  if [ "$rc" = 0 ] || ! grep -q '^TYPO_THREADS_FAIL' "$LOG/$name.log"; then
    tail -8 "$LOG/$name.log"; die "arm $name SURVIVED: ci-typography-threads passed"
  fi
  grep -qE "$want" "$LOG/$name.log" || { tail -20 "$LOG/$name.log"; die "arm $name failed for the wrong reason (want /$want/)"; }
  echo "killed $name: $(grep -E -m1 "$want" "$LOG/$name.log" | cut -c1-240)"
  killed=$((killed + 1))
}

mutate engine/text/TypographyContexts.cpp \
'thread_local Slot tSlot;' \
'Slot tSlot;  // MUTANT A: one context for every thread'
arm A '^TYPO_THREADS_FAIL: C: .*typography-context race'

mutate engine/text/FontRegistry.cpp \
'        const size_t index = typography::AddFont(
            path, std::make_shared<const std::vector<uint8_t>>(std::move(bytes)));
        ok = typography::RegisteredHere(index);' \
'        // MUTANT B: the paint context only
        auto* keep = new std::vector<uint8_t>(std::move(bytes));
        ImpellerMapping m{keep->data(), keep->size(), nullptr};
        ok = ImpellerTypographyContextRegisterFont(typography, &m, nullptr, nullptr);'
arm B '^TYPO_THREADS_FAIL: A: row custom measured' SKIP_TSAN=1

mutate engine/text/FontFallback.cpp \
'          typography::AddFont(path, std::make_shared<const std::vector<uint8_t>>(std::move(bytes)));' \
'          // MUTANT C: only the finding thread'"'"'s context
          auto* keep = new std::vector<uint8_t>(std::move(bytes));
          ImpellerMapping m{keep->data(), keep->size(), nullptr};
          ImpellerTypographyContextRegisterFont(typography::ForThisThread(), &m, nullptr, nullptr);'
arm C '^TYPO_THREADS_FAIL: A: row [a-z]+ measured' SKIP_TSAN=1

trap - EXIT
for f in "${FILES[@]}"; do cmp -s "$f" "$LOG/$(basename "$f").bak" || die "$f not restored"; done
rm -rf "$LOG"
echo "MUTATION_TYPO_PASS ($killed/3 mutants killed)"
