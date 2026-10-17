#!/usr/bin/env bash
# P3 GATE: conformance — do individual PROP FAMILIES render correctly?
#
# P2 asked one question: does a React tree become pixels. It could not tell a
# correct renderer from one that paints every View as a flat, axis-aligned,
# uniformly-bordered rectangle, because a fixture of plain boxes looks identical
# either way. This gate asks the follow-up question for each prop family P2
# either got wrong or skipped:
#
#   per-edge borders   — P2 used the LEFT edge's colour for all four
#   per-corner radii   — P2 collapsed the radii cascade to one `all` value
#   linear gradients   — not implemented, AND blocked by a Metro shim gap
#   transforms         — not implemented
#   text metrics       — numberOfLines was measured but not painted
#
# Every case carries at least one NEGATIVE probe: a pixel that must be
# BACKGROUND. That is what separates "the shape is right" from "something of
# roughly the right colour is in roughly the right place", and it is the class of
# assertion that a screenshot review cannot replace.
#
# Runs through the CONSUMER path (tarballs into a pristine app outside the repo)
# exactly like P1/P2, because a renderer that only works from the repo is not
# shipped.
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
FIXTURE="$ROOT/fixtures/p3-conformance"

fail() { echo "P3_CONFORMANCE_FAIL: $*" >&2; exit 1; }

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
APP="$WORK/ConformanceApp"
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
p.name="conformanceapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="P3Fixture"; a.displayName="P3 Fixture";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" \
  || fail "npm install of the tarballs failed"

echo "== 2. swap in the P3 fixture as the app entry =="
cp "$FIXTURE/index.js" "$APP/index.js"
cp "$FIXTURE/fixture.json" "$APP/fixture.json"

npx --no-install react-native init-impeller 2>&1 | sed 's/^/   /' || fail "init-impeller failed"
RESOLVED="$(node node_modules/react-native-impeller-platform/src/bin/engine-path.js)" || fail "engine resolver failed"

echo "== 3. bundle --platform impeller =="
npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/index.impeller.bundle \
    2>&1 | tail -3 | sed 's/^/   /'
BUNDLE="$APP/impeller/build/index.impeller.bundle"
[ -s "$BUNDLE" ] || fail "no bundle produced"

echo "== 4. build the probe arguments FROM the fixture =="
mapfile -t ARGS < <(node "$ROOT/tools/fixture-probe-args.js" "$FIXTURE/fixture.json" p3)

echo "== 5. run the engine on the fixture bundle (NO packaging banner) =="
LOG="$WORK/engine.log"
set +e
"$RESOLVED" --headless --probe-banner off \
            --bundle "$BUNDLE" --app-name P3Fixture \
            --screenshot "$WORK/frame.ppm" \
            "${ARGS[@]}" > "$LOG" 2>&1
RC=$?
set -e
grep -vE '^W[0-9]{8} ' "$LOG" | grep -vE '^rn-impeller: (probe|node_frame)=' | sed 's/^/   /'
[ "$RC" -eq 0 ] || fail "engine exited $RC"

echo "== 6. assert: React actually mounted =="
if grep -q '\[js-exception\] (fatal' "$LOG"; then
  fail "the bundle threw a fatal JS exception (see log above)"
fi
NODES="$(grep -oE 'scene_nodes=[0-9]+' "$LOG" | cut -d= -f2)"
[ -n "$NODES" ] && [ "$NODES" -gt 0 ] || fail "scene graph is empty — Fabric never mounted"
PAINTED="$(grep -oE 'painted_nodes=[0-9]+' "$LOG" | cut -d= -f2)"
[ "${PAINTED:-0}" -gt 0 ] || fail "scene graph has $NODES nodes but painted 0"
echo "   scene_nodes=$NODES painted_nodes=$PAINTED"

echo "== 7. assert conformance =="
node "$ROOT/tools/assert-fixture.js" p3 "$FIXTURE/fixture.json" "$LOG" P3_CONFORMANCE_FAIL

if [ -n "${SCREENSHOT_OUT:-}" ]; then cp "$WORK/frame.ppm" "$SCREENSHOT_OUT"; echo "   screenshot -> $SCREENSHOT_OUT"; fi
echo "P3_CONFORMANCE_PASS (nodes=$NODES painted=$PAINTED)"
