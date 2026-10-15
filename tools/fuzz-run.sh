#!/usr/bin/env bash
# FP-52: run one libFuzzer target under ASan + UBSan.
#   bash tools/fuzz-run.sh <target> <seconds> [extra libFuzzer flags]
# Targets: svg-path svg-dash image-decode props scene (rn-impeller --fuzz).
# Builds engine/build-fuzz (clang, RNI_SANITIZE=address,undefined, RNI_FUZZ=ON) unless
# FUZZ_NO_BUILD=1. Seeds: tools/fuzz/seeds/<target> (read-only; every crasher found is
# kept there as a regression seed). New inputs go to a scratch corpus, crash artifacts to
# FUZZ_OUT (default a temp dir). Exit 0 only for a clean run: no crash, leak, UB report,
# timeout or OOM, and libFuzzer printed its "Done N runs" line.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
T="${1:?target}"; SECS="${2:?seconds}"; shift 2
BUILD="$ROOT/engine/build-fuzz"
BIN="$BUILD/rn-impeller"
SEEDS="$ROOT/tools/fuzz/seeds/$T"
OUT="${FUZZ_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/fuzz-$T.XXXX")}"
mkdir -p "$OUT/corpus"
fail() { echo "FUZZ_RUN_FAIL $T: $*"; exit 1; }

if [ "${FUZZ_NO_BUILD:-0}" != 1 ]; then
  if [ ! -f "$BUILD/build.ninja" ]; then
    cmake -S engine -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DRNI_SANITIZE=address,undefined -DRNI_FUZZ=ON \
          -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ > "$OUT/configure.log" 2>&1 \
      || { tail -20 "$OUT/configure.log"; fail "configure failed"; }
  fi
  cmake --build "$BUILD" -j"$(nproc)" --target rn-impeller > "$OUT/build.log" 2>&1 \
    || { grep -m5 -A8 FAILED "$OUT/build.log"; fail "build failed (log $OUT/build.log)"; }
fi
[ -x "$BIN" ] || fail "no fuzz binary at $BIN"
[ -d "$SEEDS" ] || fail "no seed corpus at $SEEDS"

SYMBOLIZER="$(command -v llvm-symbolizer || ls /usr/bin/llvm-symbolizer-* 2>/dev/null | sort -V | tail -1)"
DICT=(); [ -f "$ROOT/tools/fuzz/$T.dict" ] && DICT=(-dict="$ROOT/tools/fuzz/$T.dict")
# halt_on_error: any UB report ends the run as a finding (FP-03 keeps recover mode
# for gates; a fuzzer must stop on the first one). Suppressions are FP-03's
# third-party-only lists.
ASAN_SYMBOLIZER_PATH="$SYMBOLIZER" \
ASAN_OPTIONS="detect_leaks=1:abort_on_error=1:allocator_may_return_null=1" \
LSAN_OPTIONS="suppressions=$ROOT/tools/sanitize/lsan_suppressions.txt:print_suppressions=0" \
UBSAN_OPTIONS="halt_on_error=1:abort_on_error=1:print_stacktrace=1:suppressions=$ROOT/tools/sanitize/ubsan_suppressions.txt" \
  "$BIN" --fuzz "$T" -max_total_time="$SECS" -timeout=10 -rss_limit_mb=3072 \
    -print_final_stats=1 -artifact_prefix="$OUT/" "${DICT[@]}" "$@" \
    "$OUT/corpus" "$SEEDS" > "$OUT/fuzz.log" 2>&1
rc=$?
grep -a -E '^(fuzz_target=|INFO: seed corpus|#[0-9]+\s+(INITED|DONE))|stat::number_of_executed_units' "$OUT/fuzz.log" | head -6
if [ "$rc" != 0 ] || ! grep -q '^Done [0-9]* runs' "$OUT/fuzz.log"; then
  grep -a -m1 -E 'ERROR: (AddressSanitizer|LeakSanitizer|libFuzzer)|runtime error:|deadly signal|out-of-memory|timeout' "$OUT/fuzz.log"
  grep -a -m12 -E '^\s+#[0-9]+ 0x' "$OUT/fuzz.log"
  ls "$OUT"/crash-* "$OUT"/leak-* "$OUT"/timeout-* "$OUT"/oom-* 2>/dev/null | head -3
  fail "rc=$rc (log $OUT/fuzz.log)"
fi
runs="$(grep -a -o '^Done [0-9]* runs' "$OUT/fuzz.log" | grep -o '[0-9]*')"
echo "FUZZ_RUN_PASS $T seconds=$SECS runs=$runs corpus=$(ls "$OUT/corpus" | wc -l) log=$OUT/fuzz.log"
