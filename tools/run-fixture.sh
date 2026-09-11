#!/usr/bin/env bash
# Run an arbitrary fixture file through the already-provisioned ConcaveApp and
# dump per-shape painted areas. Usage: run-fixture.sh <fixture.js> [W] [H]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${CONCAVE_WORK:-/tmp/concave-imp}/ConcaveApp"
FIX="$1"; W="${2:-700}"; H="${3:-400}"
cd "$APP"
cp "$FIX" "$APP/index.js"
ENGINE="$(node node_modules/@react-native-impeller/core/src/bin/engine-path.js)"
npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/fx.bundle >/dev/null 2>&1
SHOT="/tmp/fx.ppm"
"$ENGINE" --bundle "$APP/impeller/build/fx.bundle" --app-name ConcaveProbe \
  --headless --probe-banner off --width "$W" --height "$H" --screenshot "$SHOT" \
  > /tmp/fx.log 2>&1 || { tail -20 /tmp/fx.log; exit 1; }
python3 "$ROOT/tools/areas.py" "$SHOT"
