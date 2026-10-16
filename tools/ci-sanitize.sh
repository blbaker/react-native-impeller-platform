#!/usr/bin/env bash
# FP-03: ASan + UBSan (+ LSan at exit) over the core gates.
# Model: Flutter's sanitizer lane, engine/src/flutter/testing/sanitizer_suppressions.sh
# (ASAN_OPTIONS detect_leaks=1, LSAN/UBSAN suppression files) applied to the real binary.
#   1. builds engine/build-asan with clang + RNI_SANITIZE=address,undefined and stages it into
#      engine/build-asan/stage (rpath $ORIGIN, libimpeller/libhermesvm prebuilt, untouched)
#   2. proves the binary is instrumented (ASan/UBSan runtime symbols, prints sanitize_build=1)
#   3. runs every gate in tools/parity-core-gates.txt that executes rn-impeller with
#      RNI_BIN=<sanitized binary>; each must pass, must have run the sanitized binary
#      (RNI_SANITIZE_STAMP_DIR stamps), and must leave no ASan/UBSan/LSan report.
# Reports go to log_path files, so a gate that swallows engine stderr still fails here.
# Env: SANITIZE_GATES="tools/ci-x.sh ..." overrides the gate list (mutation script uses it).
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BUILD="$ROOT/engine/build-asan"
SAN_BIN="$BUILD/stage/bin/rn-impeller"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ci-sanitize.XXXX")"
fail() { echo "SANITIZE_FAIL: $*"; exit 1; }
# FP-06: the instrumented binary is 2-5x slower; every gate scales its wait ceilings (never its
# measured intervals) by this, and so does the engine (base/TestSync.h).
export RNI_TIME_SCALE="${RNI_TIME_SCALE:-4}"
# FP-57: ci-perf / ci-memory-budget assert their behaviour but skip the time/RSS budgets the
# sanitizer runtime inflates (each refuses the switch for a non-sanitizer binary).
export RNI_BUDGETS_FUNCTIONAL_ONLY=1

echo "== 1. build engine/build-asan (RNI_SANITIZE=address,undefined)"
cmake -S engine -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DRNI_SANITIZE=address,undefined \
      -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
      -DCMAKE_INSTALL_PREFIX="$BUILD/stage" > "$WORK/configure.log" 2>&1 \
  || { tail -20 "$WORK/configure.log"; fail "configure failed"; }
cmake --build "$BUILD" -j"$(nproc)" --target rn-impeller > "$WORK/build.log" 2>&1 \
  || { grep -m5 -A5 FAILED "$WORK/build.log"; fail "build failed (log $WORK/build.log)"; }
rm -rf "$BUILD/stage"
cmake --install "$BUILD" --component engine > /dev/null || fail "install failed"
[ -x "$SAN_BIN" ] || fail "no staged binary at $SAN_BIN"

echo "== 2. instrumentation"
# clang links its sanitizer runtimes statically: look for the symbols, not libasan.so.
SYMS="$(nm "$SAN_BIN" 2>/dev/null)"
grep -q ' __asan_init$' <<<"$SYMS" || fail "no __asan_init in $SAN_BIN: not ASan-instrumented"
grep -q ' __ubsan_handle_add_overflow$' <<<"$SYMS" || fail "no __ubsan_handle_add_overflow in $SAN_BIN: not UBSan-instrumented"
# ldd output captured first: grep -q on the pipe SIGPIPEs ldd under pipefail (flaked under load, FP-06).
LDD="$(ldd "$SAN_BIN")"
grep -q "$BUILD/stage/bin/libimpeller.so" <<<"$LDD" || fail "libimpeller.so not resolved from the stage dir"
SYMBOLIZER="$(command -v llvm-symbolizer || ls /usr/bin/llvm-symbolizer-* 2>/dev/null | sort -V | tail -1)"
[ -n "$SYMBOLIZER" ] || fail "no llvm-symbolizer: reports would have no function names"
export ASAN_SYMBOLIZER_PATH="$SYMBOLIZER"
# Hooks unset here: the mutation script exports them for the gate runs below.
env -u RNI_TEST_ASAN_OOB -u RNI_TEST_UBSAN_OVERFLOW -u RNI_TEST_LSAN_LEAK "$SAN_BIN" --help > "$WORK/help.log" 2>&1 \
  || fail "sanitized --help exited non-zero"
grep -q '^rn-impeller: sanitize_build=1 sanitizers=address,undefined$' "$WORK/help.log" \
  || fail "binary did not print sanitize_build=1 (not built with RNI_SANITIZE)"
echo "instrumented: __asan_init + __ubsan_handle_*, sanitize_build=1, symbolizer $SYMBOLIZER"

# One report dir per gate. abort_on_error turns an ASan/LSan report into a crash the gate
# sees; UBSan keeps running (recover mode) so ALL of a run's UB lands in the log files.
LSAN_SUPP="$ROOT/tools/sanitize/lsan_suppressions.txt"
UBSAN_SUPP="$ROOT/tools/sanitize/ubsan_suppressions.txt"
# First report header of the files: ASan/LSan "ERROR: AddressSanitizer: SEGV on unknown address",
# TSan "WARNING: ThreadSanitizer: data race" (a nested TSan gate whose report a log_path here
# captured: FP-57), UBSan "runtime error: ...". Uppercase kinds (SEGV) used to match nothing.
report_kind() {
  local k
  k="$(grep -h -m1 -oE '((ERROR|WARNING): [A-Za-z]+Sanitizer: [A-Za-z][A-Za-z -]*[A-Za-z]|runtime error: [^:]*)' "$@" | head -1)"
  echo "${k:-unrecognised report header: $(grep -h -m1 -v '^=*$' "$@" | head -1 | cut -c1-120)}"
}
run_gate() {  # gate
  local g="$1" name dir rc stamps reports
  name="$(basename "$g" .sh)"; dir="$WORK/$name"; mkdir -p "$dir/stamps"
  env RNI_BIN="$SAN_BIN" RNI_SANITIZE_STAMP_DIR="$dir/stamps" \
      ASAN_OPTIONS="detect_leaks=1:abort_on_error=1:log_path=$dir/san" \
      LSAN_OPTIONS="suppressions=$LSAN_SUPP:print_suppressions=0" \
      UBSAN_OPTIONS="print_stacktrace=1:suppressions=$UBSAN_SUPP:log_path=$dir/san" \
      timeout -k 1m 2h bash "$g" > "$dir/gate.log" 2>&1
  rc=$?
  stamps="$(find "$dir/stamps" -type f | wc -l)"
  reports="$(find "$dir" -maxdepth 1 -name 'san.*' -type f | wc -l)"
  if [ "$reports" -gt 0 ]; then
    for f in "$dir"/san.*; do echo "--- $f"; grep -m12 -E 'ERROR|WARNING: [A-Za-z]+Sanitizer|runtime error|SUMMARY|^    #[0-9]+ ' "$f"; done
    fail "$g: $reports sanitizer report file(s) (first: $(report_kind "$dir"/san.*))"
  fi
  [ "$rc" = 0 ] || { tail -15 "$dir/gate.log"; fail "$g exited rc=$rc under the sanitized binary (log $dir/gate.log)"; }
  [ "$stamps" -gt 0 ] || fail "$g never ran the sanitized binary (0 stamps; does it honour RNI_BIN?)"
  echo "ok $g runs=$stamps reports=0 ($(tail -1 "$dir/gate.log" | cut -c1-110))"
}

# --build-only: stop after the instrumented build (tools/ci-load-proof.sh builds before its hog).
if [ "${1:-}" = --build-only ]; then echo "SANITIZE_BUILT"; exit 0; fi
echo "== 3. gates on the sanitized binary"
if [ -n "${SANITIZE_GATES:-}" ]; then
  read -r -a GATES <<<"$SANITIZE_GATES"
else
  GATES=()
  while read -r g _; do
    [ -z "$g" ] || [[ "$g" == \#* ]] && continue
    # ci-headless.sh compiles and runs its own spike against libimpeller; it never runs rn-impeller.
    [ "$g" = tools/ci-headless.sh ] && continue
    GATES+=("$g")
  done < tools/parity-core-gates.txt
fi
total=0
for g in "${GATES[@]}"; do
  run_gate "$g"
  total=$((total + $(find "$WORK/$(basename "$g" .sh)/stamps" -type f | wc -l)))
done
rm -rf "$WORK"
echo "SANITIZE_PASS (${#GATES[@]} gates, $total sanitized engine runs, 0 ASan/UBSan/LSan reports)"
