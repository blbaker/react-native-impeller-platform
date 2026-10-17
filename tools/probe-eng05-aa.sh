#!/usr/bin/env bash
# ENG-05 follow-up probe: is the missing AA stroke-specific or global?
#
# Measures partial-coverage pixel counts on a FILLED circle and a STROKED
# circle separately. A circle is used because its edge samples every angle, so
# AA (if on) MUST produce intermediate luminance values — unlike an
# axis-aligned rect, whose edges legitimately land on pixel boundaries.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
RNI_ENGINE_PKG="${RNI_ENGINE_PKG:-$ROOT/packages-engine/engine-linux-x64}"

fail() { echo "ENG05_AA_FAIL: $*" >&2; exit 1; }

[ -d "$BASE_APP/node_modules/react-native" ] || fail "no base RN app at $BASE_APP"

WORK="$(mktemp -d)"
cleanup() {
  rni_kill_own
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "== 1. pack + install =="
ENGINE_TGZ="$(cd "$RNI_ENGINE_PKG" && npm pack --silent --pack-destination "$WORK")"
MAIN_TGZ="$(cd package && npm pack --silent --pack-destination "$WORK")"
APP="$WORK/Eng05AAApp"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="eng05aaapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="Eng05AA"; a.displayName="Eng05AA";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" \
  || fail "npm install failed"
npm install --no-audit --no-fund --silent react-native-svg@15.15.5 \
  || fail "react-native-svg install failed"

cp "$ROOT/fixtures/eng05-aa/index.js" "$APP/index.js"
npx --no-install react-native init-impeller >/dev/null 2>&1 || fail "init-impeller failed"
ENGINE="$(node node_modules/react-native-impeller-platform/src/bin/engine-path.js)"

echo "== 2. bundle =="
npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/index.impeller.bundle \
    >/dev/null 2>&1 || fail "bundle failed"
BUNDLE="$APP/impeller/build/index.impeller.bundle"

echo "== 3. render 1x and 2x =="
for S in 1 2; do
  "$ENGINE" --bundle "$BUNDLE" --app-name Eng05AA --headless --probe-banner off \
    --width $((400*S)) --height $((300*S)) --scale "$S" \
    --screenshot "$WORK/aa-${S}x.ppm" > "$WORK/run-${S}x.log" 2>&1 \
    || { tail -20 "$WORK/run-${S}x.log" >&2; fail "run failed at ${S}x"; }
done

echo "== 4. coverage histogram =="
python3 "$ROOT/tools/eng05-aa-analyse.py" "$WORK/aa-1x.ppm" "$WORK/aa-2x.ppm"
