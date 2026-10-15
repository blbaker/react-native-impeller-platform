#!/usr/bin/env bash
# FP-52: libFuzzer + ASan + UBSan over our parsers and the painter.
# Model: Skia fuzz/ (FuzzParsePath, FuzzImage, FuzzCanvas; one binary with a type switch,
# fuzz/FuzzMain.cpp); Flutter's pin ships no fuzzers (fuzzer_test.gni is a no-op stub).
#   1. builds engine/build-fuzz (clang, RNI_SANITIZE=address,undefined, RNI_FUZZ=ON)
#   2. proves the binary carries ASan, UBSan, coverage and the libFuzzer driver
#   3. runs every target FUZZ_SECONDS (default 120) through tools/fuzz-run.sh: each must
#      replay every committed seed (crashers included, as regressions) and then fuzz with
#      no crash, sanitizer report, leak, timeout or OOM.
# Env: FUZZ_TARGETS="svg-path ..." runs a subset.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BIN="$ROOT/engine/build-fuzz/rn-impeller"
SECS="${FUZZ_SECONDS:-120}"
TARGETS="${FUZZ_TARGETS:-svg-path svg-dash image-decode props scene}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ci-fuzz.XXXX")"
fail() { echo "FUZZ_FAIL: $*"; exit 1; }

echo "== 1. build engine/build-fuzz"
FUZZ_OUT="$WORK/build" bash tools/fuzz-run.sh svg-path 0 -runs=0 > "$WORK/build.out" 2>&1 \
  || { tail -15 "$WORK/build.out"; fail "fuzz build (or the seed replay) failed"; }

echo "== 2. instrumentation"
SYMS="$(nm "$BIN" 2>/dev/null)"
for s in __asan_init __ubsan_handle_add_overflow LLVMFuzzerRunDriver \
         _ZN3rni4fuzz7SvgPathEPKhm _ZN3rni4fuzz5SceneEPKhm; do
  grep -q " $s$" <<<"$SYMS" || fail "no $s in $BIN"
done
# The runtime defines the sancov hooks either way; the counters section proves our TUs call them.
readelf -S "$BIN" | grep -q __sancov_cntrs || fail "no __sancov_cntrs section: not coverage-instrumented"
"$BIN" --fuzz no-such-target > "$WORK/list.log" 2>&1
for t in $TARGETS; do grep -q " $t" "$WORK/list.log" || fail "binary does not know target $t"; done
echo "instrumented: ASan + UBSan + sancov + libFuzzer driver; targets: $TARGETS"

echo "== 3. fuzz ${SECS}s per target"
for t in $TARGETS; do
  seeds="$(find "tools/fuzz/seeds/$t" -type f | wc -l)"
  [ "$seeds" -gt 0 ] || fail "$t: no committed seeds"
  out="$WORK/$t"; mkdir -p "$out"
  FUZZ_NO_BUILD=1 FUZZ_OUT="$out" bash tools/fuzz-run.sh "$t" "$SECS" > "$out/run.out" 2>&1
  rc=$?
  cat "$out/run.out" | grep -a -v '^\s*#[0-9]* 0x' | tail -3
  [ "$rc" = 0 ] || { grep -a -m14 -E '^\s+#[0-9]+ 0x' "$out/run.out"; fail "$t: fuzz run failed (log $out/fuzz.log)"; }
  got="$(grep -a -o 'seed corpus: files: [0-9]*' "$out/fuzz.log" | grep -o '[0-9]*$')"
  [ "$got" = "$seeds" ] || fail "$t: libFuzzer replayed $got seeds, $seeds are committed"
  runs="$(grep -a -o 'FUZZ_RUN_PASS .* runs=[0-9]*' "$out/run.out" | grep -o '[0-9]*$')"
  [ "${runs:-0}" -ge 1000 ] || fail "$t: only ${runs:-0} executions in ${SECS}s (target too slow to fuzz)"
  echo "fuzz $t: seeds=$seeds runs=$runs clean"
done
echo "FUZZ_PASS targets=$(wc -w <<<"$TARGETS") seconds=$SECS"
