#!/usr/bin/env bash
# FP-51 gate: per-backend golden images with a tolerance policy.
# Flutter's goldens are Metal-only (testing/impeller_golden_tests); we keep one golden set per backend:
#   tools/golden/<backend>/<case>.png   backend = linux-gles (llvmpipe) | darwin-metal | darwin-gles-angle
#                                                 | win32-gles-angle
# Cases and per-case tolerances: tools/golden/cases.txt (+ <backend>/tolerance.txt overrides). A pixel is
# off when any channel differs by more than max_channel_delta; a case fails when off pixels exceed
# max_diff_pixels_percent. Missing golden, size change, or a failed render is a FAIL, never a skip.
#   bash tools/ci-golden.sh               backends this host can run (linux: linux-gles)
#   bash tools/ci-golden.sh --backend B   one backend (must match the host's engine)
#   bash tools/ci-golden.sh --mac         sync + run the darwin backends on the Mac parity tree
#   bash tools/ci-golden.sh --win         linux-driven run of the staged win32 exe (win-run-engine.sh)
# Env: GOLDEN_DIR (golden root, default tools/golden), RNI_BIN, KEEP_WORKDIR=1, GOLDEN_CASES="a b".
# Failure diff images (golden | actual | diff) land in $GOLDEN_DIFF_DIR (default build/golden-diff/<backend>).
# Update goldens: tools/golden-update.sh <backend>. Mutants: tools/mutation-verify-golden.sh.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BACKEND=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mac) echo "--mac: run this gate on the Mac itself, with RNI_BIN set to the staged darwin binary" >&2; exit 2 ;;
    --win) BACKEND=win32-gles-angle; export RNI_BIN="$ROOT/tools/win-run-engine.sh" ;;
    --backend) BACKEND="${2:?backend}"; shift ;;
    *) echo "usage: ci-golden.sh [--backend B | --mac | --win]" >&2; exit 64 ;;
  esac; shift
done
. tools/lib/golden-render.sh
GOLDEN_ROOT="${GOLDEN_DIR:-$ROOT/tools/golden}"
if [ -n "${RNI_BIN:-}" ]; then BIN="$RNI_BIN"
elif [ "$(uname -s)" = Darwin ]; then BIN="$ROOT/packages-engine/engine-darwin-arm64/bin/rn-impeller"
else BIN="$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller"; fi
[ -x "$BIN" ] || { echo "GOLDEN_FAIL: no engine binary at $BIN" >&2; exit 1; }
BACKENDS="${BACKEND:-$(golden_backends_for_host)}"
[ -n "$BACKENDS" ] || { echo "GOLDEN_FAIL: no golden backend for this host" >&2; exit 1; }
WORK="$(mktemp -d)"
trap '[ "${KEEP_WORKDIR:-0}" = 1 ] && echo "workdir kept: $WORK" || rm -rf "$WORK"' EXIT
echo "engine: $BIN"

FAILS=0 PASSES=0 SKIPS=0
for golden_backend in $BACKENDS; do
  echo "== backend $golden_backend =="
  out="$WORK/$golden_backend"; mkdir -p "$out"
  diffdir="${GOLDEN_DIFF_DIR:-$ROOT/build/golden-diff}/$golden_backend"
  # the golden root is $GOLDEN_ROOT/<backend>; tolerance overrides come from the repo copy
  # shellcheck disable=SC2086
  render_log="$(golden_render_all "$out" ${GOLDEN_CASES:-} )" || true
  echo "$render_log" | grep '^GOLDEN_SKIP' || true
  SKIPS=$((SKIPS + $(echo "$render_log" | grep -c '^GOLDEN_SKIP')))
  declare -A failed_render=()
  while read -r l; do
    [ -z "$l" ] || { echo "$l"; n="${l#GOLDEN_FAIL }"; failed_render["${n%%:*}"]=1; FAILS=$((FAILS + 1)); }
  done < <(echo "$render_log" | grep '^GOLDEN_FAIL')
  while IFS='|' read -r name bundle app w h url ss pct delta; do
    [ -z "${GOLDEN_CASES:-}" ] || [[ " $GOLDEN_CASES " == *" $name "* ]] || continue
    [ -z "${failed_render[$name]:-}" ] || continue
    [ -s "$out/$name.ppm" ] || continue
    read -r pct delta < <(golden_tolerance "$name" "$pct" "$delta")
    mkdir -p "$diffdir"
    if python3 tools/golden_compare.py compare "$out/$name.ppm" "$GOLDEN_ROOT/$golden_backend/$name.png" \
         --pct "$pct" --delta "$delta" --name "$golden_backend/$name" --diff "$diffdir/$name.png"; then
      PASSES=$((PASSES + 1)); rm -f "$diffdir/$name.png"
    else
      FAILS=$((FAILS + 1)); echo "  diff image: $diffdir/$name.png"
    fi
  done < <(golden_cases)
  unset failed_render
done
echo "golden summary: pass=$PASSES fail=$FAILS skip=$SKIPS"
[ "$FAILS" -eq 0 ] && [ "$PASSES" -gt 0 ] || { echo "GOLDEN_FAILED"; exit 1; }
echo "GOLDEN_PASS"
