#!/usr/bin/env bash
# MUTATION TEST for tools/ci-mem-psi.sh. Each mutant edits engine/host/MemoryPressure.cpp, rebuilds
# linux-x64, and must turn its arm red for its OWN reason.
#
#   M1  the trigger fires but nothing is purged (fire arm: no low_memory source=linux-psi)
#   M2  RNI_MEM_PSI=off is ignored (off arm: not off)
#   M3  a refused trigger is not reported (bad arm: no armed=0 line)
#   M4  no stall check: every kernel event purges, including the unprivileged trigger's spurious
#       first events (control arm). Needs a 6.5+ kernel and an unprivileged run, where the kernel
#       sends those events; elsewhere it SURVIVES and the script says so
#   M5  the poll fallback samples but purges nothing (nocap arm: no low_memory after the hog)
#   M6  the poll starts on any trigger error, not only EPERM (bad arm: psi-poll without EPERM)
#   M7  the poll ignores the threshold and purges every sample (nocap arm: a purge below it)
#
# Restores with cp + touch (never cp -p: an old mtime makes ninja skip the rebuild and the mutant
# stays linked in), rebuilds, and re-runs the gate GREEN.
# Do not run while another build (e.g. linux arm64) reads this source tree.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
unset RNI_BIN
FILES=(engine/host/MemoryPressure.cpp)
BACKUP="$(mktemp -d "${TMPDIR:-/tmp}/mv-mem-psi.XXXXXX")"
for f in "${FILES[@]}"; do mkdir -p "$BACKUP/orig/$(dirname "$f")"; cp "$f" "$BACKUP/orig/$f"; done
restore() { for f in "${FILES[@]}"; do cp "$BACKUP/orig/$f" "$f"; touch "$f"; done; }
trap 'restore; echo "(engine source restored; rebuild with tools/engine-build-linux.sh --arch x64)" >&2' EXIT
build() { bash tools/engine-build-linux.sh --arch x64 > "$1" 2>&1 || { tail -20 "$1" >&2; echo "MUTATE_FAIL: build failed" >&2; exit 1; }; }
gate()  { ARMS="$1" bash tools/ci-mem-psi.sh > "$2" 2>&1; }
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
  if grep -q 'MEM_PSI_GATE_PASS' "$2" || ! grep -q 'MEM_PSI_FAIL' "$2"; then
    echo "MUTATE_FAIL: $1 SURVIVED -- the gate stayed GREEN" >&2; tail -5 "$2" >&2; exit 1
  fi
  grep -qE "$3" "$2" || { echo "MUTATE_FAIL: $1 killed for the WRONG reason:" >&2; grep -m3 FAIL "$2" >&2; exit 1; }
  echo "   $1 killed: $(grep -m1 -E "$3" "$2" | cut -c1-220)"
}
F=engine/host/MemoryPressure.cpp

echo "== M1: events purge nothing =="
mutate $F '      since = now;
      rni::image::HandleLowMemory("linux-psi");' '      since = now;  /* MUTANT M1 */'
build "$BACKUP/m1-build.log"; gate fire "$BACKUP/m1.log" || true
expect_killed M1 "$BACKUP/m1.log" 'MEM_PSI_FAIL: fire: no `low_memory source=linux-psi` after the hog'
restore

echo "== M2: RNI_MEM_PSI=off ignored =="
mutate $F '  if (env && (std::strcmp(env, "off") == 0' '  if (env && false /* MUTANT M2 */ && (std::strcmp(env, "off") == 0'
build "$BACKUP/m2-build.log"; gate off "$BACKUP/m2.log" || true
expect_killed M2 "$BACKUP/m2.log" 'MEM_PSI_FAIL: off: not off: '
restore

echo "== M3: a refused trigger is silent =="
mutate $F '    std::printf("rn-impeller: memory_pressure source=psi armed=0 trigger=\"%s\" step=%s errno=%d (%s)\n",
                trigger.c_str(), fd < 0 ? "open" : "write", err, std::strerror(err));' '    (void)err;  // MUTANT M3'
build "$BACKUP/m3-build.log"; gate bad "$BACKUP/m3.log" || true
expect_killed M3 "$BACKUP/m3.log" 'MEM_PSI_FAIL: bad: no `memory_pressure source=psi armed=` line at start'
restore

echo "== M4: no stall check, every kernel event purges =="
mutate $F '      const bool purge = stall < 0 || (unsigned long long)stall >= thresholdUs;' '      const bool purge = true;  // MUTANT M4'
build "$BACKUP/m4-build.log"
M4=survived
for try in 1 2 3; do
  gate control "$BACKUP/m4-$try.log" || true
  if grep -q 'MEM_PSI_FAIL' "$BACKUP/m4-$try.log"; then expect_killed M4 "$BACKUP/m4-$try.log" \
    'MEM_PSI_FAIL: control: (a linux-psi purge with no hog|an event was acted on with no hog)'; M4=killed; break; fi
  grep -q 'MEM_PSI_INCONCLUSIVE' "$BACKUP/m4-$try.log" && echo "   M4 try $try inconclusive (host pressure), again"
  grep -q 'MEM_PSI_GATE_PASS' "$BACKUP/m4-$try.log" && echo "   M4 try $try: the kernel sent no event in the window, again"
done
[ "$M4" = killed ] || echo "   M4 SURVIVED 3 tries: this kernel sent no spurious event (pre-6.5 or privileged run); not a gate defect"
restore

echo "== M5: the poll purges nothing =="
mutate $F '      std::fflush(stdout);
      rni::image::HandleLowMemory("linux-psi");' '      std::fflush(stdout);  /* MUTANT M5 */'
build "$BACKUP/m5-build.log"; gate nocap "$BACKUP/m5.log" || true
expect_killed M5 "$BACKUP/m5.log" 'MEM_PSI_FAIL: nocap: no `low_memory source=linux-psi` after the hog'
restore

echo "== M6: the poll starts on any trigger error =="
mutate $F '    if (fd < 0 && err == EPERM) StartPsiPoll(trigger);' '    StartPsiPoll(trigger);  // MUTANT M6'
build "$BACKUP/m6-build.log"; gate bad "$BACKUP/m6.log" || true
expect_killed M6 "$BACKUP/m6.log" 'MEM_PSI_FAIL: bad: the psi-poll fallback ran without an EPERM'
restore

echo "== M7: the poll purges every sample =="
mutate $F '      if (stall < (long long)thresholdUs) continue;' '      if (false) continue;  // MUTANT M7'
build "$BACKUP/m7-build.log"; gate nocap "$BACKUP/m7.log" || true
expect_killed M7 "$BACKUP/m7.log" 'MEM_PSI_FAIL: nocap: (a poll purge below the threshold|a linux-psi purge came BEFORE the hog started)'
restore

echo "== restored source: rebuild, the gate must be GREEN again =="
build "$BACKUP/final-build.log"
gate "fire control off bad nocap off-nocap" "$BACKUP/final.log" || { tail -8 "$BACKUP/final.log" >&2; echo "MUTATE_FAIL: gate red after restore" >&2; exit 1; }
grep -q 'MEM_PSI_GATE_PASS' "$BACKUP/final.log" || { echo "MUTATE_FAIL: no PASS after restore" >&2; exit 1; }
for f in "${FILES[@]}"; do cmp -s "$BACKUP/orig/$f" "$f" || { echo "MUTATE_FAIL: $f differs after restore" >&2; exit 1; }; done
trap - EXIT
rm -rf "$BACKUP"
echo "MEM_PSI_MUTATION_PASS (M1 M2 M3 M5 M6 M7 killed, M4 $M4; restored source green)"
