#!/usr/bin/env bash
# Rebuild the committed expo-host bundles (fixtures/expo-host/prebuilt/).
#
# The fixture IS the Mac's probe (package.json pins expo 57.0.27, RN 0.86.3,
# React 19.2.3; index.js/App.js/metro.config.js verbatim), installed fresh from
# npm with react-native-impeller-platform packed from THIS tree, so the bundles
# carry the shims this checkout ships. Two entries:
#   index.js     -> expo-probe.bundle     (registerRootComponent from 'expo')
#   contract.js  -> expo-contract.bundle  (globalThis.expo contract checks)
#
# Bundles are engine-independent, so committing them lets tools/ci-expo-host.sh
# run on a machine with no node (the Mac over ssh). Re-run after changing the
# fixture or anything under package/src/metro-shims.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
FIX="$ROOT/fixtures/expo-host"
OUT="${1:-$FIX/prebuilt}"
command -v node >/dev/null || { echo "build-expo-host-bundles: FAIL - no node on PATH" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CORE_TGZ="$(cd package && npm pack --silent --pack-destination "$WORK")"
APP="$WORK/app"
mkdir -p "$APP"
cp "$FIX/package.json" "$FIX/index.js" "$FIX/App.js" "$FIX/contract.js" "$FIX/fetchChecks.js" \
   "$FIX/metro.config.js" "$FIX/app.json" "$FIX/.watchmanconfig" "$APP/"
cd "$APP"
node -e '
const fs = require("fs");
const p = JSON.parse(fs.readFileSync("package.json", "utf8"));
p.dependencies["react-native-impeller-platform"] = "file:" + process.argv[1];
fs.writeFileSync("package.json", JSON.stringify(p, null, 2));
' "$WORK/$CORE_TGZ"
# --omit=optional: the engine packages are optional deps of core and are not
# published; the gate runs the engine binary directly.
npm install --no-audit --no-fund --omit=optional > "$WORK/npm.log" 2>&1 \
  || { tail -20 "$WORK/npm.log" >&2; echo "build-expo-host-bundles: FAIL - npm install" >&2; exit 1; }
echo "expo=$(node -p 'require("expo/package.json").version') rn=$(node -p 'require("react-native/package.json").version') react=$(node -p 'require("react/package.json").version')"

mkdir -p dist "$OUT"
for pair in "index.js:expo-probe" "contract.js:expo-contract"; do
  entry="${pair%%:*}"; name="${pair##*:}"
  npx --no-install react-native bundle --platform impeller --dev false \
      --entry-file "$entry" --bundle-output "dist/$name.bundle" > "$WORK/$name.log" 2>&1 \
    || { grep -iE 'error|unable|cannot' "$WORK/$name.log" | head -12 >&2
         echo "build-expo-host-bundles: FAIL - metro could not bundle $entry" >&2; exit 2; }
  cp "dist/$name.bundle" "$OUT/$name.bundle"
  echo "build-expo-host-bundles: wrote $OUT/$name.bundle ($(wc -c < "$OUT/$name.bundle") bytes)"
done
