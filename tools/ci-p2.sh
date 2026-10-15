#!/usr/bin/env bash
# P2 GATE: does a React tree become pixels, through the CONSUMER path?
#
# Same shape as the P1 gate (tarballs into a pristine app outside the repo), but
# it swaps the app's entry point for fixtures/p2-mount and asserts the geometry
# that fixture declares. Reusing the consumer path is deliberate: a renderer that
# only works when run from the repo is not shipped.
#
# The probes come from fixtures/p2-mount/fixture.json, which the fixture ALSO
# renders from — so the gate and the app cannot drift apart. Adding a box to the
# fixture automatically adds its probe here.
#
# --probe-banner off: the P1 packaging banner is NOT drawn, so every pixel in the
# frame came from React. With the banner on, a passing frame would prove nothing
# about the renderer.
set -euo pipefail
# ⛔ RESOLVE tools/ BEFORE the cd. Sourcing via "$(dirname "$0")/..." AFTER it
# re-resolves a relative $0 against the repo root and silently looks for
# <repo>/ci-triple.sh — a miss that only shows when the gate is invoked from
# inside tools/.
CI_TOOLS="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$0")/.."
ROOT="$PWD"
# Host triple (RNI_PLATFORM / RNI_ARCH / RNI_TRIPLE / RNI_ENGINE_PKG). Replaces
# the hardcoded "linux x64" that made this gate unrunnable on any other host.
. "$CI_TOOLS/ci-triple.sh"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
FIXTURE="$ROOT/fixtures/p2-mount"

fail() { echo "P2_MOUNT_FAIL: $*" >&2; exit 1; }

# Provision the cached stock RN app rather than requiring a human to have
# made one. This precondition used to be satisfied by HISTORY on a dev box,
# which is why CI could not run this gate at all.
[ -d "$BASE_APP/node_modules/react-native" ] || bash tools/base-app.sh
[ -d "$BASE_APP/node_modules/react-native" ] || fail "no base RN app at $BASE_APP (tools/base-app.sh failed)"
bash tools/engine-build.sh "$RNI_PLATFORM" "$RNI_ARCH" > /dev/null || fail "engine build failed"

WORK="$(mktemp -d)"
KEEP="${KEEP_WORKDIR:-0}"
cleanup() { [ "$KEEP" = "1" ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

echo "== 1. pack + install into a pristine app OUTSIDE the repo =="
ENGINE_TGZ="$(cd "${RNI_ENGINE_PKG}" && npm pack --silent --pack-destination "$WORK")"
MAIN_TGZ="$(cd package && npm pack --silent --pack-destination "$WORK")"
APP="$WORK/FixtureApp"
# ⛔ `cp -r` IS NOT PORTABLE FOR A node_modules TREE.
# node_modules/.bin/* are SYMLINKS (react-native -> ../react-native/cli.js).
# GNU cp -r preserves them; BSD/macOS cp -r DEREFERENCES them, so the copy gets
# a real file whose own relative require('./package.json') then resolves against
# .bin/ and dies with MODULE_NOT_FOUND — a failure that reads as a broken RN
# install rather than a broken copy. `cp -R` (capital) preserves links on both.
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="fixtureapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="P2Fixture"; a.displayName="P2 Fixture";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" \
  || fail "npm install of the tarballs failed"

echo "== 2. swap in the P2 fixture as the app entry =="
cp "$FIXTURE/index.js" "$APP/index.js"
cp "$FIXTURE/fixture.json" "$APP/fixture.json"

npx --no-install react-native init-impeller 2>&1 | sed 's/^/   /' || fail "init-impeller failed"
RESOLVED="$(node node_modules/@react-native-impeller/core/src/bin/engine-path.js)" || fail "engine resolver failed"
# RNI_BIN overrides the installed engine (tools/ci-sanitize.sh runs this gate on the ASan build).
[ -z "${RNI_BIN:-}" ] || RESOLVED="$RNI_BIN"

echo "== 3. bundle --platform impeller =="
npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/index.impeller.bundle \
    2>&1 | tail -3 | sed 's/^/   /'
BUNDLE="$APP/impeller/build/index.impeller.bundle"
[ -s "$BUNDLE" ] || fail "no bundle produced"

echo "== 4. build the probe arguments FROM the fixture =="
mapfile -t ARGS < <(node "$ROOT/tools/fixture-probe-args.js" "$FIXTURE/fixture.json" p2)

echo "== 5. run the engine on the fixture bundle (NO packaging banner) =="
LOG="$WORK/engine.log"
set +e
"$RESOLVED" --headless --probe-banner off \
            --bundle "$BUNDLE" --app-name P2Fixture \
            --screenshot "$WORK/frame.ppm" \
            "${ARGS[@]}" > "$LOG" 2>&1
RC=$?
set -e
grep -vE '^W[0-9]{8} ' "$LOG" | sed 's/^/   /'
[ "$RC" -eq 0 ] || fail "engine exited $RC"

echo "== 6. assert: React actually mounted =="
# A JS error means the bundle died before rendering. Fabric would then commit an
# empty tree and every colour probe would read background -- so check this FIRST
# and report the real cause instead of "wrong pixels".
if grep -q '\[js-exception\] (fatal' "$LOG"; then
  fail "the bundle threw a fatal JS exception (see log above)"
fi
NODES="$(grep -oE 'scene_nodes=[0-9]+' "$LOG" | cut -d= -f2)"
[ -n "$NODES" ] && [ "$NODES" -gt 0 ] || fail "scene graph is empty (scene_nodes=${NODES:-none}) — Fabric never mounted"
PAINTED="$(grep -oE 'painted_nodes=[0-9]+' "$LOG" | cut -d= -f2)"
[ "${PAINTED:-0}" -gt 0 ] || fail "scene graph has $NODES nodes but painted 0 — the tree never reached the display list"
echo "   scene_nodes=$NODES painted_nodes=$PAINTED"

echo "== 7. assert: the pixels are the ones the fixture declares =="
node "$ROOT/tools/assert-fixture.js" p2 "$FIXTURE/fixture.json" "$LOG" P2_MOUNT_FAIL

if [ -n "${SCREENSHOT_OUT:-}" ]; then cp "$WORK/frame.ppm" "$SCREENSHOT_OUT"; echo "   screenshot -> $SCREENSHOT_OUT"; fi
echo "P2_MOUNT_PASS (nodes=$NODES painted=$PAINTED)"
