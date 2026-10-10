#!/usr/bin/env bash
# Regenerate the committed style-coverage probe bundles after a fixture or
# package/ change. Needs node + npm (WSL only; the Mac renders the committed
# bundles). Both bundles are engine-independent.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
FIXTURE="$ROOT/fixtures/style-coverage/index.js" \
  OUT="$ROOT/fixtures/style-coverage/prebuilt/style-coverage.bundle" bash tools/build-probe-bundle.sh
NW_FIX="$ROOT/fixtures/nw-coverage" bash tools/build-nativewind-bundle.sh \
  "$ROOT/fixtures/nw-coverage/prebuilt/nw-coverage.bundle"
