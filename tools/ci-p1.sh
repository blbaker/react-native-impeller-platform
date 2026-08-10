#!/usr/bin/env bash
# All P1 gates, in the order a CI job should run them.
#   1. P0 headless pixel gate (the substrate every later gate reuses)
#   2. engine package build + R3 size budget
#   3. pack-and-consume: the consumer path, end to end
#
# Mutation verification (tools/mutation-verify-p1.sh) is deliberately NOT here: it is
# slow (one full consumer install per mutant) and belongs on a nightly/pre-release run.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "### gate 1/3: headless pixels"
bash tools/ci-headless.sh | tail -3

echo "### gate 2/3: engine package"
bash tools/engine-build.sh linux x64

echo "### gate 3/3: pack and consume"
bash tools/pack-and-consume.sh | tail -8

echo "P1_GATES_PASS"
