#!/usr/bin/env bash
# P0 gate: prove Impeller renders correct pixels HEADLESS (no display server).
# This is the mechanism every later pixel gate in this program reuses.
#
# Mutation-verified 2026-08-09: passes on the real spike, and fails correctly when
#   (a) the draw call is removed  -> all probes black, 1 distinct color
#   (b) rounded rect -> plain rect -> ONLY the corner probe fails (no false positives)
set -euo pipefail
cd "$(dirname "$0")/.."
SDK="${IMPELLER_SDK:-engine/third_party/impeller-sdk}"

[ -f "${SDK}/include/impeller.h" ] || bash tools/sdk-fetch.sh "${SDK}"

OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
g++ -std=c++17 -O1 engine/spike/headless_gles.cpp \
    -I"${SDK}/include" -L"${SDK}/lib" -limpeller -lEGL -lGLESv2 \
    -Wl,-rpath,"$(cd "${SDK}/lib" && pwd)" -o "${OUT}/spike"

log="${OUT}/run.log"
if ! "${OUT}/spike" > "$log" 2>&1; then
  echo "--- spike output ---"; cat "$log"
  echo "IMPELLER_HEADLESS_FAIL"; exit 1
fi
cat "$log"

grep -q "IMPELLER_SPIKE_PASS" "$log" || { echo "IMPELLER_HEADLESS_FAIL (no pass marker)"; exit 1; }
grep -qE "^GL_RENDERER=" "$log"      || { echo "IMPELLER_HEADLESS_FAIL (no renderer line)"; exit 1; }
# Guard the guard: a frame that is nearly uniform must never be accepted.
colors=$(grep -oE "distinct colors: [0-9]+" "$log" | grep -oE "[0-9]+")
[ "$colors" -ge 10 ] || { echo "IMPELLER_HEADLESS_FAIL (only ${colors} colors)"; exit 1; }

echo "IMPELLER_HEADLESS_PASS (colors=${colors})"
