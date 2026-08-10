#!/usr/bin/env bash
# All gates through P2, in the order a CI job should run them.
#   1. P0 headless pixel gate (the substrate every later gate reuses)
#   2. engine package build + R3 size budget
#   3. P1 pack-and-consume: the consumer path, end to end
#   4. P2 mount: a React tree becomes pixels, through that same consumer path
#
# Mutation verification (tools/mutation-verify-p*.sh) is deliberately NOT here:
# each mutant costs a full consumer install, so it belongs on a nightly or
# pre-release run.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "### gate 1/4: headless pixels"
bash tools/ci-headless.sh | tail -3

echo "### gate 2/4: engine package"
bash tools/engine-build.sh linux x64 | tail -2

echo "### gate 3/4: pack and consume (P1)"
bash tools/pack-and-consume.sh | tail -4

echo "### gate 4/4: RN mount (P2)"
bash tools/ci-p2.sh | tail -10

echo "ALL_GATES_PASS"
