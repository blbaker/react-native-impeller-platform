#!/usr/bin/env bash
# Bundle a single-file probe fixture (FIXTURE=<index.js>) into OUT=<bundle>
# with the base RN app + the CURRENT package/. Needs node + npm (WSL only).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
RNI_ENGINE_PKG="${RNI_ENGINE_PKG:-$ROOT/packages-engine/engine-linux-x64}"
OUT="${OUT:?set OUT}"; FIXTURE="${FIXTURE:?set FIXTURE}"

command -v node >/dev/null || { echo "build-style-audit-bundle: FAIL — no node on PATH" >&2; exit 1; }
[ -d "$BASE_APP/node_modules/react-native" ] || bash tools/base-app.sh

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ENGINE_TGZ="$(cd "$RNI_ENGINE_PKG" && npm pack --silent --pack-destination "$WORK")"
MAIN_TGZ="$(cd package && npm pack --silent --pack-destination "$WORK")"
APP="$WORK/App"; cp -R "$BASE_APP" "$APP"; cd "$APP"
node -e 'const fs=require("fs");const a=JSON.parse(fs.readFileSync("app.json","utf8"));a.name="probe";a.displayName="probe";fs.writeFileSync("app.json",JSON.stringify(a,null,2));'
npm install --no-audit --no-fund --silent "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" >/dev/null
cp "$FIXTURE" "$APP/index.js"
npx --no-install react-native init-impeller >/dev/null 2>&1 || true
npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/sa.bundle >/dev/null 2>&1
[ -s "$APP/impeller/build/sa.bundle" ] || { echo "build-style-audit-bundle: FAIL — bundle empty" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"
cp "$APP/impeller/build/sa.bundle" "$OUT"
echo "build-style-audit-bundle: wrote $OUT ($(wc -c < "$OUT") bytes)"
