#!/usr/bin/env bash
# FP-03 mutants for tools/ci-sanitize.sh. Each arm must make the gate FAIL and name the defect.
#   A  RNI_TEST_ASAN_OOB=1        heap read one past a std::vector   -> ASan heap-buffer-overflow
#   B  RNI_TEST_UBSAN_OVERFLOW=1  INT_MAX + 1                        -> UBSan signed integer overflow
#                                 (UBSan does not abort: proves the log_path scan, not the exit code)
#   C  RNI_TEST_LSAN_LEAK=1       drops the only pointer to a block  -> LeakSanitizer at exit
#   D  source: Sanitize.cmake stops passing -fsanitize                -> "not ASan-instrumented"
# Arms A-C run the gate over ci-p2 (the consumer path) so the hook fires inside a real gate run.
set -uo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.local/bin:$PATH"; unset RNI_BIN
LOG="$(mktemp -d "${TMPDIR:-/tmp}/mut-sanitize.XXXX")"
killed=0
die() { echo "MUTATION_SANITIZE_FAIL: $*"; exit 1; }

arm() {  # name env-assignment expected-regex
  local name="$1" envset="$2" want="$3" rc
  env "$envset" SANITIZE_GATES=tools/ci-p2.sh bash tools/ci-sanitize.sh > "$LOG/$name.log" 2>&1; rc=$?
  if [ "$rc" = 0 ] || ! grep -q '^SANITIZE_FAIL' "$LOG/$name.log"; then
    tail -5 "$LOG/$name.log"; die "arm $name SURVIVED ($envset): ci-sanitize passed"
  fi
  grep -qE "$want" "$LOG/$name.log" || { tail -15 "$LOG/$name.log"; die "arm $name failed for the wrong reason (want /$want/)"; }
  echo "killed $name: $(grep -m1 '^SANITIZE_FAIL' "$LOG/$name.log" | cut -c1-160)"
  killed=$((killed + 1))
}

arm A RNI_TEST_ASAN_OOB=1 'heap-buffer-overflow.*'
grep -q 'ReadPastEnd' "$LOG/A.log" || die "arm A report does not point at ReadPastEnd"
arm B RNI_TEST_UBSAN_OVERFLOW=1 'runtime error: signed integer overflow'
grep -q 'SanitizerHooks.cpp:[0-9]*:[0-9]*: runtime error' "$LOG/B.log" || die "arm B report has no source location"
arm C RNI_TEST_LSAN_LEAK=1 'LeakSanitizer: detected memory leaks'

# D: anchored source mutant, restored by trap.
F=engine/cmake/Sanitize.cmake
A1='  add_compile_options(-fsanitize=${RNI_SANITIZE} -fno-omit-frame-pointer -g1)'
A2='  add_link_options(-fsanitize=${RNI_SANITIZE})'
[ "$(grep -cxF "$A1" "$F")" = 1 ] || die "anchor 1 not found exactly once in $F"
[ "$(grep -cxF "$A2" "$F")" = 1 ] || die "anchor 2 not found exactly once in $F"
cp "$F" "$LOG/Sanitize.cmake.bak"
trap 'cp "$LOG/Sanitize.cmake.bak" "$F"' EXIT
python3 - "$F" "$A1" "$A2" <<'EOF'
import sys
p, a1, a2 = sys.argv[1:]
s = open(p).read()
s = s.replace(a1 + "\n", "  # MUTANT D: no -fsanitize compile flags\n").replace(a2 + "\n", "  # MUTANT D: no -fsanitize link flags\n")
open(p, "w").write(s)
EOF
SANITIZE_GATES=tools/ci-p2.sh bash tools/ci-sanitize.sh > "$LOG/D.log" 2>&1; rc=$?
cp "$LOG/Sanitize.cmake.bak" "$F"; trap - EXIT
[ "$rc" != 0 ] || { tail -5 "$LOG/D.log"; die "arm D SURVIVED: uninstrumented build passed ci-sanitize"; }
grep -q 'not ASan-instrumented' "$LOG/D.log" || { tail -10 "$LOG/D.log"; die "arm D failed for the wrong reason"; }
echo "killed D: $(grep -m1 '^SANITIZE_FAIL' "$LOG/D.log" | cut -c1-160)"
killed=$((killed + 1))
git diff --quiet -- "$F" || die "$F not restored"

rm -rf "$LOG"
echo "MUTATION_SANITIZE_PASS ($killed/4 mutants killed)"
