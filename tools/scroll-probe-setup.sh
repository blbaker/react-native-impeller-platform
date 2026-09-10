#!/usr/bin/env bash
# ENG-02 scratch harness: build the p9-scroll fixture into a pristine app and
# render it headless, so the ScrollView component name can be read out of the
# frame report. NOT a gate — a probe, used while building ENG-02.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
RNI_ENGINE_PKG="${RNI_ENGINE_PKG:-$ROOT/packages-engine/engine-linux-x64}"
OUT="${1:-/tmp/scrollprobe}"
rm -rf "$OUT"; mkdir -p "$OUT"

ENGINE_TGZ="$(cd "$RNI_ENGINE_PKG" && npm pack --silent --pack-destination "$OUT")"
MAIN_TGZ="$(cd package && npm pack --silent --pack-destination "$OUT")"
APP="$OUT/ScrollApp"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="scrollapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="P9Scroll"; a.displayName="P9Scroll";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent "$OUT/$ENGINE_TGZ" "$OUT/$MAIN_TGZ"
cp "$ROOT/fixtures/p9-scroll/index.js" "$APP/index.js"
npx --no-install react-native init-impeller >/dev/null 2>&1
npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/scroll.bundle >/dev/null 2>&1
ENGINE="$(node node_modules/@react-native-impeller/core/src/bin/engine-path.js)"
echo "ENGINE=$ENGINE"
echo "BUNDLE=$APP/impeller/build/scroll.bundle"
echo "APP=$APP"
