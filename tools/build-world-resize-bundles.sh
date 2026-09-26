#!/usr/bin/env bash
# Rebuild the two prebuilt bundles tools/ci-world-resize.sh renders:
#   fixtures/eng10-world-sprites/prebuilt/eng10-resize.bundle     (resize-index.js)
#   fixtures/eng10-world-sprites/prebuilt/eng10-reference.bundle  (reference-index.js)
# Needs node + npm. The Mac has neither, so both bundles are COMMITTED and the
# Mac renders them directly -- this script only regenerates them on a dev box
# after the fixture changes.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
RNI_ENGINE_PKG="${RNI_ENGINE_PKG:-$ROOT/packages-engine/engine-linux-x64}"
FIXDIR="$ROOT/fixtures/eng10-world-sprites"
OUTDIR="$FIXDIR/prebuilt"

command -v node >/dev/null || { echo "build-world-resize-bundles: FAIL -- no node on PATH" >&2; exit 1; }
[ -d "$BASE_APP/node_modules/react-native" ] || bash tools/base-app.sh

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ENGINE_TGZ="$(cd "$RNI_ENGINE_PKG" && npm pack --silent --pack-destination "$WORK")"
MAIN_TGZ="$(cd package && npm pack --silent --pack-destination "$WORK")"
APP="$WORK/App"; cp -R "$BASE_APP" "$APP"; cd "$APP"
npm install --no-audit --no-fund --silent "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" >/dev/null
npx --no-install react-native init-impeller >/dev/null 2>&1 || true
cp "$FIXDIR/scene.js" "$APP/scene.js"
mkdir -p "$OUTDIR"
for pair in "resize-index.js:eng10-resize" "reference-index.js:eng10-reference"; do
  entry="${pair%%:*}"; name="${pair##*:}"
  cp "$FIXDIR/$entry" "$APP/index.js"
  npx --no-install react-native bundle --platform impeller --dev false \
      --entry-file index.js --bundle-output "impeller/build/$name.bundle" >/dev/null 2>&1
  [ -s "impeller/build/$name.bundle" ] || { echo "build-world-resize-bundles: FAIL -- $name bundle empty" >&2; exit 1; }
  cp "impeller/build/$name.bundle" "$OUTDIR/$name.bundle"
  echo "build-world-resize-bundles: wrote $OUTDIR/$name.bundle ($(wc -c < "$OUTDIR/$name.bundle") bytes)"
done
