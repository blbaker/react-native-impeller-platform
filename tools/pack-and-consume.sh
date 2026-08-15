#!/usr/bin/env bash
# P1 GATE: pack-and-consume.
#
# Proves the CONSUMER path, not the repo path. Nothing here runs from the repo
# working tree except the packing step itself:
#
#   1. npm pack the engine package and the main package -> real tarballs
#   2. copy a pristine stock RN app into a temp dir OUTSIDE the repo
#   3. npm install BOTH TARBALLS into it (no link, no workspace, no file: to src)
#   4. npx react-native init-impeller           -> scaffold
#   5. npx react-native bundle --platform impeller
#   6. assert the packaging shim marker IS IN THE BUNDLE   (layer 2)
#   7. run the engine on the bundle, headless                (layer 3)
#   8. assert pixels: status swatch GREEN, distinct colors >= floor
#
# Layer 1 (file-in-tarball) is asserted directly against the tarball listing, so a
# `files:` field that drops the shims reddens here instead of at a consumer's desk.
#
# A base app is required (it takes minutes to create, so it is cached):
#   BASE_APP=~/.cache/rni/base  (override with $BASE_APP)
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

fail() { echo "PACK_AND_CONSUME_FAIL: $*" >&2; exit 1; }

# Provision the cached stock RN app rather than requiring a human to have
# made one. This precondition used to be satisfied by HISTORY on a dev box,
# which is why CI could not run this gate at all.
[ -d "$BASE_APP/node_modules/react-native" ] || bash tools/base-app.sh
[ -d "$BASE_APP/node_modules/react-native" ] || fail "no base RN app at $BASE_APP (tools/base-app.sh failed)"
[ -x "${RNI_ENGINE_PKG}/bin/rn-impeller" ] || bash tools/engine-build.sh "$RNI_PLATFORM" "$RNI_ARCH"

WORK="$(mktemp -d)"
KEEP="${KEEP_WORKDIR:-0}"
cleanup() { [ "$KEEP" = "1" ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

echo "== 1. pack =="
ENGINE_TGZ="$(cd "${RNI_ENGINE_PKG}" && npm pack --silent --pack-destination "$WORK")"
MAIN_TGZ="$(cd package && npm pack --silent --pack-destination "$WORK")"
ENGINE_TGZ="$WORK/$ENGINE_TGZ"; MAIN_TGZ="$WORK/$MAIN_TGZ"
echo "   $(basename "$ENGINE_TGZ") $(du -h "$ENGINE_TGZ" | cut -f1)"
echo "   $(basename "$MAIN_TGZ") $(du -h "$MAIN_TGZ" | cut -f1)"

echo "== 2. layer 1: required files present in the MAIN tarball =="
LIST="$WORK/main-files.txt"
tar -tzf "$MAIN_TGZ" > "$LIST"
for required in \
    package/src/resolve.js \
    package/src/cli/init.js \
    package/src/cli/run.js \
    package/src/metro-shims/index.js \
    package/src/metro-shims/shims/Platform.impeller.js \
    package/react-native.config.js \
    package/templates/app/impeller.config.json.tmpl \
    package/templates/app/_gitignore ; do
  grep -qx "$required" "$LIST" || fail "tarball is missing $required (check package.json \"files\")"
done
echo "   all required files present"

echo "== 3. install into a pristine app OUTSIDE the repo =="
APP="$WORK/ConsumerApp"
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
p.name="consumerapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="ConsumerApp"; a.displayName="Consumer App";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent "$ENGINE_TGZ" "$MAIN_TGZ" \
  || fail "npm install of the tarballs failed"
[ -d node_modules/@react-native-impeller/core ] || fail "main package not installed"
[ -d "node_modules/@react-native-impeller/engine-${RNI_TRIPLE}" ] || fail "engine package not installed"

echo "== 4. resolver finds the engine from the CONSUMER's node_modules =="
RESOLVED="$(node node_modules/@react-native-impeller/core/src/bin/engine-path.js)" \
  || fail "engine resolver failed"
# ⛔ COMPARE REALPATHS, NOT THE STRINGS THE SHELL HAPPENS TO HOLD.
# On macOS $TMPDIR lives under /var, which is a symlink to /private/var. mktemp
# hands back the /var spelling while node's require.resolve returns the resolved
# /private/var one, so a prefix match on the raw strings fails even though both
# name the SAME directory — a false "resolver escaped the app" on darwin only.
# pwd -P gives the canonical form of the app dir; realpath does the same for the
# resolved binary (python3 as the fallback, since macOS has no coreutils
# realpath by default).
APP_REAL="$(cd "$APP" && pwd -P)"
RESOLVED_REAL="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$RESOLVED")"
case "$RESOLVED_REAL" in
  "$APP_REAL"/node_modules/@react-native-impeller/*) echo "   $RESOLVED" ;;
  *) fail "resolver returned an out-of-app path: $RESOLVED_REAL (app=$APP_REAL)" ;;
esac

echo "== 5. init-impeller (scaffold) =="
npx --no-install react-native init-impeller 2>&1 | sed 's/^/   /' || fail "init-impeller failed"
[ -f impeller/impeller.config.json ] || fail "scaffold did not write impeller/impeller.config.json"
grep -q '"appName": "ConsumerApp"' impeller/impeller.config.json \
  || fail "scaffold hardcoded an app name instead of reading app.json"
grep -q withImpeller metro.config.js || fail "metro.config.js was not wrapped"

echo "== 6. bundle for --platform impeller =="
npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/index.impeller.bundle \
    2>&1 | tail -5 | sed 's/^/   /'
BUNDLE="$APP/impeller/build/index.impeller.bundle"
[ -s "$BUNDLE" ] || fail "no bundle produced"

echo "== 7. layer 2: shim marker IS IN THE BUNDLE =="
grep -q '__RN_IMPELLER_SHIM_V1__' "$BUNDLE" \
  || fail "shim marker absent from the bundle — metro never resolved the impeller shim"
echo "   marker present ($(wc -c < "$BUNDLE") byte bundle)"

echo "== 8. layer 3: engine runs the bundle and paints the right pixels =="
LOG="$WORK/engine.log"
set +e
"$RESOLVED" --headless --bundle "$BUNDLE" --app-name ConsumerApp \
            --screenshot "$WORK/frame.ppm" > "$LOG" 2>&1
RC=$?
set -e
sed 's/^/   /' "$LOG"
[ "$RC" -eq 0 ] || fail "engine exited $RC"
grep -q "RN_IMPELLER_RENDER_OK app=ConsumerApp" "$LOG" || fail "engine did not report render OK for the scaffolded app name"
grep -q "shim_marker=PRESENT" "$LOG" || fail "engine did not see the shim marker"

SWATCH="$(grep -oE 'status_swatch_rgb=[0-9]+,[0-9]+,[0-9]+' "$LOG" | cut -d= -f2)"
[ "${SWATCH%%,*}" -le 8 ] || fail "status swatch is not green (rgb=$SWATCH) — packaging chain broken"
G="$(echo "$SWATCH" | cut -d, -f2)"
[ "$G" -ge 247 ] || fail "status swatch is not green (rgb=$SWATCH)"

COLORS="$(grep -oE 'distinct_colors=[0-9]+' "$LOG" | cut -d= -f2)"
[ "$COLORS" -ge 10 ] || fail "frame too uniform ($COLORS colors) — the gate must not pass on a blank frame"

# Shape fidelity: the rounded-rect corner must show background, not fill. This is the
# probe that fails on a subtle wrong-shape regression while everything else stays OK.
CORNER="$(grep -oE 'rrect_corner_rgb=[0-9]+,[0-9]+,[0-9]+' "$LOG" | cut -d= -f2)"
[ "$CORNER" = "255,255,255" ] || fail "rounded-rect corner is filled (rgb=$CORNER) — shape regression"

if [ -n "${SCREENSHOT_OUT:-}" ]; then cp "$WORK/frame.ppm" "$SCREENSHOT_OUT"; echo "   screenshot -> $SCREENSHOT_OUT"; fi

echo "PACK_AND_CONSUME_PASS (swatch=$SWATCH colors=$COLORS)"
