#!/usr/bin/env bash
# Rebuild fixtures/blur-scroll/prebuilt/blur-scroll.bundle (blur over moving content, expo-blur).
# Same recipe as build-expo-host-bundles.sh: the fixture's package.json (expo 57.0.27 +
# expo-blur) installed fresh with react-native-impeller-platform packed from THIS tree, bundled
# with the expo metro config + impeller shims. Needs node + network.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
FIX="$ROOT/fixtures/blur-scroll"
OUT="$FIX/prebuilt/blur-scroll.bundle"
command -v node >/dev/null || { echo "build-blur-scroll-bundle: FAIL - no node on PATH" >&2; exit 1; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CORE_TGZ="$(cd package && npm pack --silent --pack-destination "$WORK")"
APP="$WORK/app"
mkdir -p "$APP"
cp "$FIX/package.json" "$FIX/index.js" "$FIX/metro.config.js" "$FIX/app.json" "$FIX/.watchmanconfig" "$APP/"
cd "$APP"
node -e '
const fs = require("fs");
const p = JSON.parse(fs.readFileSync("package.json", "utf8"));
p.dependencies["react-native-impeller-platform"] = "file:" + process.argv[1];
fs.writeFileSync("package.json", JSON.stringify(p, null, 2));
' "$WORK/$CORE_TGZ"
npm install --no-audit --no-fund --omit=optional > "$WORK/npm.log" 2>&1 \
  || { tail -20 "$WORK/npm.log" >&2; echo "build-blur-scroll-bundle: FAIL - npm install" >&2; exit 1; }
echo "expo=$(node -p 'require("expo/package.json").version') expo-blur=$(node -p 'require("expo-blur/package.json").version')"
npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output "$WORK/out.bundle" > "$WORK/bundle.log" 2>&1 \
  || { grep -iE 'error|unable|cannot' "$WORK/bundle.log" | head -12 >&2
       echo "build-blur-scroll-bundle: FAIL - metro could not bundle index.js" >&2; exit 2; }
mkdir -p "$(dirname "$OUT")"
cp "$WORK/out.bundle" "$OUT"
echo "build-blur-scroll-bundle: wrote $OUT ($(wc -c < "$OUT") bytes)"
