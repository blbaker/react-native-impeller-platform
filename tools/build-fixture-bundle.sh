#!/usr/bin/env bash
# Rebuild a fixture's committed prebuilt bundle.
#   usage: build-fixture-bundle.sh <fixture-dir-name> <AppName>
#   writes fixtures/<dir>/prebuilt/<dir>.bundle
# Needs node + npm. The Mac has neither, so prebuilt bundles are COMMITTED and
# the Mac renders them directly; this only regenerates one after the fixture's
# index.js changes. Same steps as build-font-family-bundle.sh, parameterised.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
FIXDIR="${1:?usage: build-fixture-bundle.sh <fixture-dir> <AppName>}"
APPNAME="${2:?usage: build-fixture-bundle.sh <fixture-dir> <AppName>}"
SRC="$ROOT/fixtures/$FIXDIR"
[ -s "$SRC/index.js" ] || { echo "build-fixture-bundle: FAIL — no $SRC/index.js" >&2; exit 1; }
grep -q "registerComponent('$APPNAME'" "$SRC/index.js" \
  || { echo "build-fixture-bundle: FAIL — $SRC/index.js does not register '$APPNAME'" >&2; exit 1; }
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
RNI_ENGINE_PKG="${RNI_ENGINE_PKG:-$ROOT/packages-engine/engine-linux-x64}"
OUT="$SRC/prebuilt/$FIXDIR.bundle"

command -v node >/dev/null || { echo "build-fixture-bundle: FAIL — no node on PATH" >&2; exit 1; }
[ -d "$BASE_APP/node_modules/react-native" ] || bash tools/base-app.sh

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ENGINE_TGZ="$(cd "$RNI_ENGINE_PKG" && npm pack --silent --pack-destination "$WORK")"
MAIN_TGZ="$(cd package && npm pack --silent --pack-destination "$WORK")"
APP="$WORK/App"; cp -R "$BASE_APP" "$APP"; cd "$APP"
APPNAME="$APPNAME" node -e 'const fs=require("fs");const a=JSON.parse(fs.readFileSync("app.json","utf8"));a.name=process.env.APPNAME;a.displayName=process.env.APPNAME;fs.writeFileSync("app.json",JSON.stringify(a,null,2));'
npm install --no-audit --no-fund --silent "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" >/dev/null
# EXTRA_NPM: extra packages the fixture imports (e.g. "react-native-svg@15.15.5").
if [ -n "${EXTRA_NPM:-}" ]; then
  # shellcheck disable=SC2086
  npm install --no-audit --no-fund --silent $EXTRA_NPM >/dev/null \
    || { echo "build-fixture-bundle: FAIL — could not install $EXTRA_NPM" >&2; exit 1; }
fi
cp "$SRC/index.js" "$APP/index.js"
# Sibling modules the entry imports (e.g. eng10-world-sprites/scene.js).
for m in "$SRC"/*.js; do [ "$(basename "$m")" = index.js ] || cp "$m" "$APP/"; done
npx --no-install react-native init-impeller >/dev/null 2>&1 || true
npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/fixture.bundle > "$WORK/bundle.log" 2>&1 \
  || { tail -20 "$WORK/bundle.log" >&2; echo "build-fixture-bundle: FAIL — metro bundle failed" >&2; exit 1; }
[ -s "$APP/impeller/build/fixture.bundle" ] || { echo "build-fixture-bundle: FAIL — bundle empty" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"
cp "$APP/impeller/build/fixture.bundle" "$OUT"
echo "build-fixture-bundle: wrote $OUT ($(wc -c < "$OUT") bytes)"
