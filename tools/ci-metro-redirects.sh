#!/usr/bin/env bash
# parity item 20 GATE: the Metro redirects HostApp needed now ship in
# react-native-impeller-platform, so a stock app (no metro.config edits beyond
# withImpeller) works.
#
#   a  a --dev true bundle BUILDS (ReactDevToolsSettingsManager exists only as
#      .ios.js/.android.js; resolving it for 'impeller' threw, so no dev
#      bundle could be built at all)
#   b  BackHandler is a working module (self re-export -> .ios.js sibling)
#   c  legacySendAccessibilityEvent is a function (same shape)
#   d  shouldPressibilityUseW3CPointerEventsForHover honours override()
#   e  the release bundle still mounts (scene_nodes > 0)
# Item 12 (dev bundles BOOT) builds on (a): today a dev bundle builds and
# then stops on the missing WebSocketModule, which is item 12's job.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
CI_TOOLS="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$0")/.."
ROOT="$PWD"
. "$CI_TOOLS/ci-triple.sh"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
FIXTURE="$ROOT/fixtures/item20-metro-redirects"
APP_NAME="Item20Redirects"

fail() { echo "REDIRECTS_GATE_FAIL: $*" >&2; exit 1; }

unset SDL_VIDEODRIVER || true
export DISPLAY="${DISPLAY:-:0}"

[ -d "$BASE_APP/node_modules/react-native" ] || bash tools/base-app.sh
[ -d "$BASE_APP/node_modules/react-native" ] || fail "no base RN app at $BASE_APP"
bash tools/engine-build.sh "$RNI_PLATFORM" "$RNI_ARCH" > /dev/null || fail "engine build failed"

WORK="$(mktemp -d)"
KEEP="${KEEP_WORKDIR:-0}"
cleanup() {
  rni_kill_own
  [ "$KEEP" = "1" ] && echo "workdir kept: $WORK" || rm -rf "$WORK"
}
trap cleanup EXIT

echo "== 1. pack + install into a pristine app OUTSIDE the repo =="
ENGINE_TGZ="$(cd "${RNI_ENGINE_PKG}" && npm pack --silent --pack-destination "$WORK")"
MAIN_TGZ="$(cd package && npm pack --silent --pack-destination "$WORK")"
APP="$WORK/RedirectsApp"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="redirectsapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="Item20Redirects"; a.displayName="Redirects Fixture";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" \
  || fail "npm install of the tarballs failed"

echo "== 2. swap in the item 20 redirects fixture as the app entry =="
cp "$FIXTURE/index.js" "$APP/index.js"
npx --no-install react-native init-impeller > /dev/null 2>&1 || fail "init-impeller failed"
RESOLVED="$(node node_modules/react-native-impeller-platform/src/bin/engine-path.js)" || fail "engine resolver failed"

npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/redirects.bundle \
    > /dev/null 2>&1
BUNDLE="$APP/impeller/build/redirects.bundle"
[ -s "$BUNDLE" ] || fail "no bundle produced"
cd "$ROOT"










L="$WORK/run.log"
"$RESOLVED" --bundle "$BUNDLE" --app-name "$APP_NAME" --headless --probe-banner off \
    --width 400 --height 300 > "$L" 2>&1 || { tail -20 "$L" >&2; fail "headless run failed"; }
dump() { grep -E '^\[js' "$1" | sed 's/^/   /' >&2; }

echo "== a. a --dev true bundle builds =="
cd "$APP"
set +e
npx --no-install react-native bundle --platform impeller --dev true \
    --entry-file index.js --bundle-output impeller/build/dev.bundle > "$WORK/devbundle.log" 2>&1
DRC=$?
set -e
cd "$ROOT"
[ "$DRC" -eq 0 ] && [ -s "$APP/impeller/build/dev.bundle" ] \
  || { grep -m3 -E "Unable to resolve|error" "$WORK/devbundle.log" | sed 's/^/   /' >&2; fail "a: a --dev true bundle must build -- an ios/android-only module (ReactDevToolsSettingsManager) does not resolve for impeller"; }
echo "   OK: dev bundle $(wc -c < "$APP/impeller/build/dev.bundle") bytes"

echo "== b/c/d. redirects inside the bundle =="
grep -qE '^rn-impeller: scene_nodes=[1-9]' "$L" || { dump "$L"; fail "e: the release bundle mounted nothing"; }
grep -qF '[js] REDIRECT_BACKHANDLER function' "$L" \
  || { dump "$L"; fail "b: BackHandler.addEventListener should be a function -- the BackHandler self re-export is not redirected"; }
grep -qF '[js] REDIRECT_A11Y_EVENT function' "$L" \
  || { dump "$L"; fail "c: legacySendAccessibilityEvent should be a function -- the self re-export is not redirected"; }
grep -qF '[js] REDIRECT_HOVER_FLAG true' "$L" \
  || { dump "$L"; fail "d: the hover feature flag should honour override() -- the ReactNativeFeatureFlags redirect is missing"; }
echo "   OK: BackHandler, legacySendAccessibilityEvent, hover flag"

echo "REDIRECTS_GATE_PASS (dev bundle builds; BackHandler + a11y self re-exports + hover flag redirected in core)"
