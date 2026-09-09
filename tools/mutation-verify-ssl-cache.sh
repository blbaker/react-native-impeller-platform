#!/usr/bin/env bash
# MUTATION-VERIFY the OpenSSL cache re-resolve guard in cmake/ReactCommonDeps.cmake.
#
# WHAT IT GUARDS. On darwin we ask FindOpenSSL for STATIC archives, because
# brew's shared dylibs are absolute paths that fail the relocatability gate.
# But OPENSSL_SSL_LIBRARY is a CACHE entry: FindOpenSSL only searches when its
# result variables are unset, so a re-configure reuses the shared dylibs it
# found last time and OPENSSL_USE_STATIC_LIBS is never read. Measured
# 2026-09-08 on the macOS tester: the static fix was delivered, ninja said "no
# work to do", and the gate failed with the IDENTICAL two brew paths.
#
# ⛔ THAT IS WHY THIS FILE EXISTS. The bug being fixed is "a correct fix that
# does nothing", so a guard against it which is ITSELF never exercised would be
# the same defect one level up -- passing by construction and proving nothing.
# The mutant below is the pre-fix state (guard deleted); it MUST resurrect the
# stale dylib, or this harness is not measuring the guard.
#
# Runs anywhere cmake does -- no OpenSSL, no compiler, no darwin. The cache
# entries are injected with -D, so the logic is exercised without needing the
# libraries it reasons about.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO/engine/cmake/ReactCommonDeps.cmake"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/hermes-verify-ssl-cache-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "VERIFY_FAIL: $*"; exit 1; }

command -v cmake >/dev/null || fail "cmake is not on PATH -- this harness cannot run (a skipped guard reads exactly like a passed one)"

# ------------------------------------------------- 1. extract the block LIVE
# By marker from the shipped file, never copy-pasted: a copy drifts from what
# ships and then this script verifies fiction.
START=$(grep -n '^if(DEFINED OPENSSL_SSL_LIBRARY' "$SRC" | cut -d: -f1)
[ -n "$START" ] || fail "cache-guard block not found in $SRC (was it renamed?)"
END=$(awk -v s="$START" 'NR>=s && $0=="endif()" {print NR; exit}' "$SRC")
[ -n "$END" ] || fail "unterminated cache-guard block from line $START"
sed -n "${START},${END}p" "$SRC" > "$WORK/block.cmake"
grep -q 'unset(OPENSSL_SSL_LIBRARY CACHE)' "$WORK/block.cmake" \
  || fail "extracted block does not clear the cache -- extraction is wrong"
echo "[1] extracted $((END-START+1)) lines from ReactCommonDeps.cmake ... OK"

cat > "$WORK/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.24)
project(sslcache LANGUAGES NONE)
include(${CMAKE_SOURCE_DIR}/block.cmake)
if(DEFINED OPENSSL_SSL_LIBRARY)
  message(STATUS "RESULT=KEPT")
else()
  message(STATUS "RESULT=CLEARED")
endif()
EOF

# $1=lib $2=static?(TRUE/"") -> KEPT|CLEARED
probe() {
  local args=(-DOPENSSL_SSL_LIBRARY:FILEPATH="$1" -DCMAKE_STATIC_LIBRARY_SUFFIX=.a)
  [ -n "${2:-}" ] && args+=(-DOPENSSL_USE_STATIC_LIBS="$2")
  rm -rf "$WORK/b"
  # Capture THEN match: `cmake | grep -q` under pipefail dies of SIGPIPE and
  # reports failure for output that plainly contains the pattern.
  local out; out="$(cd "$WORK" && cmake -S . -B b "${args[@]}" 2>&1)"
  sed -n 's/.*RESULT=\([A-Z]*\).*/\1/p' <<<"$out" | tail -1
}

expect() { # $1=label $2=want $3=got
  [ "$3" = "$2" ] || fail "$1: expected $2, got ${3:-<no RESULT line>}"
  printf '    %-46s %s\n' "$1" "$3"
}

# --------------------------------------------------------- 2. baseline green
echo "[2] baseline (guard present)"
expect "darwin: cached shared .dylib -> re-resolve" CLEARED "$(probe /opt/homebrew/lib/libssl.dylib TRUE)"
expect "darwin: cached static .a     -> keep"       KEPT    "$(probe /opt/homebrew/lib/libssl.a     TRUE)"
expect "linux:  shared .so, no flag  -> keep"       KEPT    "$(probe /usr/lib/libssl.so             '')"

# ------------------------------------------------------------- 3. the mutant
# Delete the guard = the pre-aa319b9 state. The stale dylib must survive.
echo "[3] mutant (guard deleted -- must resurrect the stale dylib)"
cp "$WORK/block.cmake" "$WORK/block.orig"
echo '# mutant: guard removed' > "$WORK/block.cmake"
MUT="$(probe /opt/homebrew/lib/libssl.dylib TRUE)"
cp "$WORK/block.orig" "$WORK/block.cmake"
[ "$MUT" = "KEPT" ] || fail "mutant still reported $MUT -- this harness does NOT exercise the guard"
printf '    %-46s %s\n' "stale .dylib survives without the guard" "$MUT (caught)"

# ------------------------------------------------- 4. restored, still green
expect "restored: re-resolve works again" CLEARED "$(probe /opt/homebrew/lib/libssl.dylib TRUE)"

echo "ssl-cache-mutation: PASS (1/1 mutant caught, baseline green)"
