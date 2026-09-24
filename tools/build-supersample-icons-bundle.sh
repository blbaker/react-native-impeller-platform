#!/usr/bin/env bash
# Rebuild fixtures/eng-supersample-icons/prebuilt/eng-supersample-icons.bundle
# from the fixture source. Needs node + npm (a JS toolchain). The Mac has
# neither, so the bundle is COMMITTED and the Mac renders it directly — this
# script exists only to regenerate it on a dev box after the fixture changes.
#
# ⛔ Like eng-supersample, this fixture imports react-native-svg, so the base app
#   must have that dep installed before bundling.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
RNI_ENGINE_PKG="${RNI_ENGINE_PKG:-$ROOT/packages-engine/engine-linux-x64}"
OUT="$ROOT/fixtures/eng-supersample-icons/prebuilt/eng-supersample-icons.bundle"

command -v node >/dev/null || { echo "build-supersample-icons-bundle: FAIL — no node on PATH" >&2; exit 1; }
[ -d "$BASE_APP/node_modules/react-native" ] || bash tools/base-app.sh

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ENGINE_TGZ="$(cd "$RNI_ENGINE_PKG" && npm pack --silent --pack-destination "$WORK")"
MAIN_TGZ="$(cd package && npm pack --silent --pack-destination "$WORK")"
APP="$WORK/App"; cp -R "$BASE_APP" "$APP"; cd "$APP"
node -e 'const fs=require("fs");const a=JSON.parse(fs.readFileSync("app.json","utf8"));a.name="EngSupersampleIcons";a.displayName="EngSupersampleIcons";fs.writeFileSync("app.json",JSON.stringify(a,null,2));'
npm install --no-audit --no-fund --silent "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" >/dev/null
npm install --no-audit --no-fund --silent react-native-svg@15.15.5 >/dev/null \
  || { echo "build-supersample-icons-bundle: FAIL — could not install react-native-svg" >&2; exit 1; }
cp "$ROOT/fixtures/eng-supersample-icons/index.js" "$APP/index.js"
npx --no-install react-native init-impeller >/dev/null 2>&1 || true
npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/supersample-icons.bundle >/dev/null 2>&1
[ -s "$APP/impeller/build/supersample-icons.bundle" ] || { echo "build-supersample-icons-bundle: FAIL — bundle empty" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"
cp "$APP/impeller/build/supersample-icons.bundle" "$OUT"
echo "build-supersample-icons-bundle: wrote $OUT ($(wc -c < "$OUT") bytes)"
