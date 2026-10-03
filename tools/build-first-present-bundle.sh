#!/usr/bin/env bash
# Rebuild fixtures/first-present/prebuilt/first-present.bundle from
# the fixture source. Needs node + npm (a JS toolchain). The Mac has neither, so
# the bundle is COMMITTED and the Mac renders it directly — this script exists
# only to regenerate it on a dev box after the fixture changes.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
RNI_ENGINE_PKG="${RNI_ENGINE_PKG:-$ROOT/packages-engine/engine-linux-x64}"
OUT="$ROOT/fixtures/first-present/prebuilt/first-present.bundle"

command -v node >/dev/null || { echo "build-first-present-bundle: FAIL — no node on PATH" >&2; exit 1; }
[ -d "$BASE_APP/node_modules/react-native" ] || bash tools/base-app.sh

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ENGINE_TGZ="$(cd "$RNI_ENGINE_PKG" && npm pack --silent --pack-destination "$WORK")"
MAIN_TGZ="$(cd package && npm pack --silent --pack-destination "$WORK")"
APP="$WORK/App"; cp -R "$BASE_APP" "$APP"; cd "$APP"
node -e 'const fs=require("fs");const a=JSON.parse(fs.readFileSync("app.json","utf8"));a.name="FirstPresent";a.displayName="FirstPresent";fs.writeFileSync("app.json",JSON.stringify(a,null,2));'
npm install --no-audit --no-fund --silent "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" >/dev/null
cp "$ROOT/fixtures/first-present/index.js" "$APP/index.js"
npx --no-install react-native init-impeller >/dev/null 2>&1 || true
npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/fp.bundle >/dev/null 2>&1
[ -s "$APP/impeller/build/fp.bundle" ] || { echo "build-first-present-bundle: FAIL — bundle empty" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"
cp "$APP/impeller/build/fp.bundle" "$OUT"
echo "build-first-present-bundle: wrote $OUT ($(wc -c < "$OUT") bytes)"
