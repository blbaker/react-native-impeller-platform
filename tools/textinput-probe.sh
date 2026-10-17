#!/usr/bin/env bash
# ENG-01 scratch probe: does <TextInput> reach a host component on platform
# impeller at all? NOT a gate.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
RNI_ENGINE_PKG="${RNI_ENGINE_PKG:-$ROOT/packages-engine/engine-linux-x64}"
OUT="${1:-/tmp/tiprobe}"
rm -rf "$OUT"; mkdir -p "$OUT"

ENGINE_TGZ="$(cd "$RNI_ENGINE_PKG" && npm pack --silent --pack-destination "$OUT")"
MAIN_TGZ="$(cd package && npm pack --silent --pack-destination "$OUT")"
APP="$OUT/TiApp"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="tiapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="P9TextInput"; a.displayName="P9TextInput";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent "$OUT/$ENGINE_TGZ" "$OUT/$MAIN_TGZ"
cp "$ROOT/fixtures/p9-textinput/index.js" "$APP/index.js"
npx --no-install react-native init-impeller >/dev/null 2>&1
npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/ti.bundle >/dev/null 2>&1
ENGINE="$(node node_modules/react-native-impeller-platform/src/bin/engine-path.js)"
"$ENGINE" --bundle "$APP/impeller/build/ti.bundle" --app-name P9TextInput \
  --headless --probe-banner off --screenshot "$OUT/ti.ppm" 2>&1 | tail -40
