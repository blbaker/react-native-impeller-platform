#!/usr/bin/env bash
# ENG-19: bundle fixtures/eng19-nativewind as a scratch app with NO app-side
# Metro shims, against the CURRENT package/ tree.
#   usage: build-nativewind-bundle.sh [out.bundle]   (default: the prebuilt path)
# Needs node + npm. Writes metro_rc + the bundle; the bundle log is printed on
# failure so a missing shim shows the exact module Metro could not use.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
FIX="$ROOT/fixtures/eng19-nativewind"
OUT="${1:-$FIX/prebuilt/eng19-nativewind.bundle}"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
RNI_ENGINE_PKG="${RNI_ENGINE_PKG:-$ROOT/packages-engine/engine-linux-x64}"
command -v node >/dev/null || { echo "build-nativewind-bundle: FAIL — no node on PATH" >&2; exit 1; }
[ -d "$BASE_APP/node_modules/react-native" ] || bash tools/base-app.sh

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ENGINE_TGZ="$(cd "$RNI_ENGINE_PKG" && npm pack --silent --pack-destination "$WORK")"
MAIN_TGZ="$(cd package && npm pack --silent --pack-destination "$WORK")"
APP="$WORK/App"; cp -R "$BASE_APP" "$APP"; cd "$APP"
node -e 'const fs=require("fs");const a=JSON.parse(fs.readFileSync("app.json","utf8"));a.name="Eng19NativeWind";a.displayName="Eng19NativeWind";fs.writeFileSync("app.json",JSON.stringify(a,null,2));'
# The exact versions HostApp pins (apps/hostapp/package.json, pnpm-workspace.yaml).
npm install --no-audit --no-fund --silent "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" \
  nativewind@5.0.0-rc.0 react-native-css@3.1.0-rc.0 tailwindcss@4.1.12 \
  @tailwindcss/postcss@4.1.12 postcss@8 lightningcss@1.30.1 > "$WORK/npm.log" 2>&1 \
  || { tail -20 "$WORK/npm.log" >&2; echo "build-nativewind-bundle: FAIL — npm install" >&2; exit 1; }
# react-native-reanimated is deliberately NOT installed: HostApp has no Reanimated
# native module either, and the package must make the import resolve anyway.
[ ! -d node_modules/react-native-reanimated ] || { echo "build-nativewind-bundle: FAIL — reanimated got installed" >&2; exit 1; }
cp "$FIX/index.js" "$FIX/global.css" "$FIX/metro.config.js" "$FIX/css-transformer.js" "$FIX/babel.config.js" "$APP/"
rm -rf "$APP/metro-shims"
set +e
npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/nw.bundle \
    --config metro.config.js > "$WORK/bundle.log" 2>&1
rc=$?
set -e
echo "metro_rc=$rc"
if [ "$rc" -ne 0 ] || [ ! -s impeller/build/nw.bundle ]; then
  grep -E 'Error|error|Unable|unable|Cannot' "$WORK/bundle.log" | head -12 >&2
  echo "build-nativewind-bundle: FAIL — metro could not bundle the scratch app" >&2
  exit 2
fi
mkdir -p "$(dirname "$OUT")"
cp impeller/build/nw.bundle "$OUT"
echo "build-nativewind-bundle: wrote $OUT ($(wc -c < "$OUT") bytes)"
