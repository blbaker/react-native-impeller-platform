#!/usr/bin/env bash
# FP-57 mutants. Each arm must make its gate FAIL and name the defect.
#   A  source: ImageEventBinding::update dispatches onLoadStart without EventEmitter::DispatchMutex
#      (the pre-fix code)                         -> ci-image-event-lifetime: TSan race, both sides named
#   B  ci-perf on the ASan binary WITHOUT RNI_BUDGETS_FUNCTIONAL_ONLY -> PERF_FAIL over budget; the same
#      run WITH the switch passes, so the switch (not luck) is what makes the sanitizer suite pass
#   C  the switch on a non-sanitizer binary (ci-perf, ci-memory-budget, ci-prewarm,
#      ci-gpu-availability, ci-vsync) -> refused
#   D  source: the GL-count shim's dlsym compares with strcmp again -> ci-sanitize over ci-record-no-gl
#      fails with the engine's rc 139 under the ASan runtime
set -uo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.local/bin:$PATH"; unset RNI_BIN
LOG="$(mktemp -d "${TMPDIR:-/tmp}/mut-image-event.XXXX")"
killed=0
SRCS=(engine/scenegraph/ImageEvents.cpp tools/lib/gl-count-shim.sh)
SUM0="$(sha256sum "${SRCS[@]}")"
die() { echo "MUTATION_IMAGE_EVENT_FAIL: $*"; exit 1; }
BAK=()
restore() { local f; for f in "${BAK[@]}"; do cp "$LOG/$(basename "$f").bak" "$f"; done; BAK=(); }
trap restore EXIT
mutate() {  # file anchor replacement
  local f="$1" a="$2" r="$3"
  [ "$(grep -cF "$a" "$f")" = 1 ] || die "anchor not found exactly once in $f: $a"
  cp "$f" "$LOG/$(basename "$f").bak"; BAK+=("$f")
  python3 - "$f" "$a" "$r" <<'EOF'
import sys
p, a, r = sys.argv[1:]
s = open(p).read()
assert s.count(a) == 1
open(p, "w").write(s.replace(a, r))
EOF
}

echo "== A: onLoadStart without DispatchMutex"
mutate engine/scenegraph/ImageEvents.cpp \
  '  Dispatch([&] { emitter->onLoadStart(); });' \
  '  emitter->onLoadStart();  // MUTANT A: no DispatchMutex'
bash tools/ci-image-event-lifetime.sh > "$LOG/A.log" 2>&1; rc=$?
restore
[ "$rc" != 0 ] || { tail -5 "$LOG/A.log"; die "arm A SURVIVED: the unguarded dispatch passed"; }
grep -q 'dispatch in ImageEventBinding::update=yes vs EventEmitter::setEnabled in teardown=yes' "$LOG/A.log" \
  || { tail -12 "$LOG/A.log"; die "arm A failed for the wrong reason"; }
echo "killed A: $(grep -m1 '^IMAGE_EVENT_LIFETIME_FAIL' "$LOG/A.log" | cut -c1-200)"
killed=$((killed + 1))
bash tools/ci-tsan.sh --build-only > "$LOG/tsan-rebuild.log" 2>&1 || die "clean TSan rebuild failed"

echo "== B: ci-perf on the ASan binary, without and with the functional-only switch"
bash tools/ci-sanitize.sh --build-only > "$LOG/asan-build.log" 2>&1 || { tail -5 "$LOG/asan-build.log"; die "ASan build failed"; }
ASAN_BIN="$PWD/engine/build-asan/stage/bin/rn-impeller"
SYMBOLIZER="$(command -v llvm-symbolizer || ls /usr/bin/llvm-symbolizer-* 2>/dev/null | sort -V | tail -1)"
perf_asan() {  # functional(0|1) log
  env RNI_BIN="$ASAN_BIN" RNI_BUDGETS_FUNCTIONAL_ONLY="$1" RNI_TIME_SCALE=4 RNI_PERF_RETRIES=0 \
      ASAN_OPTIONS="detect_leaks=1:abort_on_error=1" ASAN_SYMBOLIZER_PATH="$SYMBOLIZER" \
      LSAN_OPTIONS="suppressions=$PWD/tools/sanitize/lsan_suppressions.txt:print_suppressions=0" \
      UBSAN_OPTIONS="print_stacktrace=1:suppressions=$PWD/tools/sanitize/ubsan_suppressions.txt" \
      bash tools/ci-perf.sh > "$2" 2>&1
}
perf_asan 0 "$LOG/B.log"; rc=$?
[ "$rc" != 0 ] || { tail -5 "$LOG/B.log"; die "arm B SURVIVED: ASan ci-perf met the budgets without the switch"; }
grep -q '^PERF_FAIL: over budget in every batch' "$LOG/B.log" || { tail -12 "$LOG/B.log"; die "arm B failed for the wrong reason"; }
echo "killed B: $(grep -m1 '^PERF_FAIL' "$LOG/B.log" | cut -c1-200)"
perf_asan 1 "$LOG/B-control.log" || { tail -12 "$LOG/B-control.log"; die "arm B control: ASan ci-perf failed WITH the switch"; }
echo "control B: $(tail -1 "$LOG/B-control.log" | cut -c1-160)"
killed=$((killed + 1))

echo "== C: the switch on the release binary"
bash tools/engine-build.sh linux x64 > "$LOG/build.log" 2>&1 || die "engine build failed"
RNI_BUDGETS_FUNCTIONAL_ONLY=1 bash tools/ci-perf.sh > "$LOG/C1.log" 2>&1 && die "arm C SURVIVED: ci-perf took the switch on a release binary"
grep -q 'needs a sanitizer build' "$LOG/C1.log" || { tail -5 "$LOG/C1.log"; die "arm C (perf) failed for the wrong reason"; }
RNI_BUDGETS_FUNCTIONAL_ONLY=1 bash tools/ci-memory-budget.sh > "$LOG/C2.log" 2>&1 && die "arm C SURVIVED: ci-memory-budget took the switch on a release binary"
grep -q 'needs a sanitizer build' "$LOG/C2.log" || { tail -5 "$LOG/C2.log"; die "arm C (memory) failed for the wrong reason"; }
RNI_BUDGETS_FUNCTIONAL_ONLY=1 bash tools/ci-prewarm.sh > "$LOG/C3.log" 2>&1 && die "arm C SURVIVED: ci-prewarm took the switch on a release binary"
grep -q 'needs a sanitizer build' "$LOG/C3.log" || { tail -5 "$LOG/C3.log"; die "arm C (prewarm) failed for the wrong reason"; }
RNI_BUDGETS_FUNCTIONAL_ONLY=1 bash tools/ci-gpu-availability.sh > "$LOG/C4.log" 2>&1 && die "arm C SURVIVED: ci-gpu-availability took the switch on a release binary"
grep -q 'needs a sanitizer build' "$LOG/C4.log" || { tail -5 "$LOG/C4.log"; die "arm C (gpu-availability) failed for the wrong reason"; }
RNI_BUDGETS_FUNCTIONAL_ONLY=1 bash tools/ci-vsync.sh > "$LOG/C5.log" 2>&1 && die "arm C SURVIVED: ci-vsync took the switch on a release binary"
grep -q 'needs a sanitizer build' "$LOG/C5.log" || { tail -5 "$LOG/C5.log"; die "arm C (vsync) failed for the wrong reason"; }
echo "killed C: $(grep -m1 'FAIL' "$LOG/C1.log" | cut -c1-120) | memory, prewarm, gpu-availability, vsync refused too"
killed=$((killed + 1))

echo "== D: GL-count shim calls strcmp on the dlsym path"
mutate tools/lib/gl-count-shim.sh \
  'if (r && name && streq(name, "eglGetProcAddress")) {' \
  'if (r && name && strcmp(name, "eglGetProcAddress") == 0) {  /* MUTANT D */'
SANITIZE_GATES=tools/ci-record-no-gl.sh bash tools/ci-sanitize.sh > "$LOG/D.log" 2>&1; rc=$?
restore; trap - EXIT
[ "$rc" != 0 ] || { tail -5 "$LOG/D.log"; die "arm D SURVIVED: the strcmp shim passed under ASan"; }
grep -q 'engine exited 139' "$LOG/D.log" || { tail -12 "$LOG/D.log"; die "arm D failed for the wrong reason"; }
echo "killed D: $(grep -m1 'RECORD_NO_GL FAIL' "$LOG/D.log" | cut -c1-120)"
killed=$((killed + 1))

[ "$(sha256sum "${SRCS[@]}")" = "$SUM0" ] || die "sources not restored"
rm -rf "$LOG"
echo "MUTATION_IMAGE_EVENT_PASS ($killed/4 mutants killed)"
