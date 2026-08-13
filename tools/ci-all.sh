#!/usr/bin/env bash
# All gates through P4, in the order a CI job should run them.
#   1. P0 headless pixel gate (the substrate every later gate reuses)
#   2. engine package build + R3 size budget
#   3. P1 pack-and-consume: the consumer path, end to end
#   4. P2 mount: a React tree becomes pixels, through that same consumer path
#   5. P3 conformance: individual prop families render CORRECTLY, not just at all
#   6. P4 module seam: JS can actually CALL native, and the packaging ships a
#      callable seam (three-layer guard + per-module pixel probes)
#
# Mutation verification (tools/mutation-verify-p*.sh) is deliberately NOT here:
# each mutant costs a full consumer install, so it belongs on a nightly or
# pre-release run.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "### gate 1/6: headless pixels"
bash tools/ci-headless.sh | tail -3

echo "### gate 2/6: engine package"
bash tools/engine-build.sh linux x64 | tail -2

echo "### gate 3/6: pack and consume (P1)"
bash tools/pack-and-consume.sh | tail -4

echo "### gate 4/6: RN mount (P2)"
bash tools/ci-p2.sh | tail -10

echo "### gate 5/6: conformance (P3)"
bash tools/ci-p3.sh | tail -22

echo "### gate 6/6: module seam (P4)"
bash tools/ci-p4.sh | tail -16

# ⛔ THE WINDOWS GATE IS OPT-IN, AND SILENCE IS NOT A PASS.
# It needs a staged native build (tools/win-sync.sh + engine-build-win.bat), so
# it cannot be unconditional on a Linux CI box. But a gate that skips quietly is
# one nobody notices has stopped running — so a skip is ANNOUNCED with its
# reason, and RNI_REQUIRE_WIN=1 turns the skip itself into a failure for the
# machine that is supposed to have it.
echo "### gate 7: Windows (opt-in)"
if [ -x "/mnt/c/Devel/rni-win-build/stage/bin/rn-impeller.exe" ] && command -v cmd.exe >/dev/null 2>&1; then
  bash tools/ci-win.sh | tail -14
elif [ "${RNI_REQUIRE_WIN:-0}" = "1" ]; then
  echo "WINDOWS_GATE_MISSING: RNI_REQUIRE_WIN=1 but no staged Windows engine" >&2
  exit 1
else
  echo "   SKIPPED — no staged Windows engine (build: tools/win-sync.sh then"
  echo "   cmd.exe /c C:\\Devel\\rni-win-scripts\\engine-build-win.bat). Set"
  echo "   RNI_REQUIRE_WIN=1 to make this skip a failure."
fi

echo "ALL_GATES_PASS"
