#!/usr/bin/env bash
# ENG-05b INSTRUMENT VALIDATION for the AA probe.
#
# Answers ONE question: can tools/eng05-aa-analyse.py's pipeline (engine ->
# glReadPixels -> PPM -> ink test) represent an intermediate luminance value at
# all? Until that is yes, "0.0% partial" is not evidence about anti-aliasing.
#
# Runs the same engine, the same headless surface, the same readback and the
# same histogram code as probe-eng05-aa.sh, over a fixture whose intermediate
# pixels come from ALPHA BLENDING and a GRADIENT, neither of which needs AA.
#
# PASS  = both regions show a wide luminance spread -> instrument is sound,
#         and the 0.0% on hard edges is a real property of the renderer.
# FAIL  = pure-only -> the AA number is an instrument artifact.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"

# ⛔ engine-linux-x64 is not installable on darwin (npm refuses on os
# mismatch) and the failure surfaces as a confusing "npm install of the
# tarballs failed". Default per host instead of making every darwin run
# discover this by hand.
case "$(uname -s)/$(uname -m)" in
  Darwin/arm64)  DEFAULT_PKG="engine-darwin-arm64" ;;
  Darwin/x86_64) DEFAULT_PKG="engine-darwin-x64"   ;;
  *)             DEFAULT_PKG="engine-linux-x64"    ;;
esac
RNI_ENGINE_PKG="${RNI_ENGINE_PKG:-$ROOT/packages-engine/$DEFAULT_PKG}"
[ -d "$RNI_ENGINE_PKG" ] || { echo "ENG05_INSTR_FAIL: no engine package at $RNI_ENGINE_PKG" >&2; exit 1; }

fail() { echo "ENG05_INSTR_FAIL: $*" >&2; exit 1; }

[ -d "$BASE_APP/node_modules/react-native" ] || fail "no base RN app at $BASE_APP"

WORK="$(mktemp -d)"
# Keep the PPMs when asked, so the gate itself can be mutation-checked against
# a deliberately-blind (pure-only) image without re-rendering.
OUT_DIR="${ENG05_KEEP_PPM:-}"
cleanup() {
  rni_kill_own
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "== 1. pack + install (engine: $(basename "$RNI_ENGINE_PKG")) =="
ENGINE_TGZ="$(cd "$RNI_ENGINE_PKG" && npm pack --silent --pack-destination "$WORK")"
MAIN_TGZ="$(cd package && npm pack --silent --pack-destination "$WORK")"
APP="$WORK/Eng05InstrApp"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="eng05instrapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="Eng05AA"; a.displayName="Eng05AA";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" \
  || fail "npm install failed"
npm install --no-audit --no-fund --silent react-native-svg@15.15.5 \
  || fail "react-native-svg install failed"

cp "$ROOT/fixtures/eng05-aa/instrument-check.js" "$APP/index.js"
npx --no-install react-native init-impeller >/dev/null 2>&1 || fail "init-impeller failed"
ENGINE="$(node node_modules/@react-native-impeller/core/src/bin/engine-path.js)"

echo "== 2. bundle =="
npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/index.impeller.bundle \
    >/dev/null 2>&1 || fail "bundle failed"
BUNDLE="$APP/impeller/build/index.impeller.bundle"

echo "== 3. render 1x and 2x =="
for S in 1 2; do
  "$ENGINE" --bundle "$BUNDLE" --app-name Eng05AA --headless --probe-banner off \
    --width $((400*S)) --height $((300*S)) --scale "$S" \
    --screenshot "$WORK/instr-${S}x.ppm" > "$WORK/run-${S}x.log" 2>&1 \
    || { tail -20 "$WORK/run-${S}x.log" >&2; fail "run failed at ${S}x"; }
done

echo "== 4. luminance spread =="
if [ -n "$OUT_DIR" ]; then
  mkdir -p "$OUT_DIR"
  cp "$WORK/instr-1x.ppm" "$WORK/instr-2x.ppm" "$OUT_DIR/"
  echo "   (PPMs kept in $OUT_DIR)"
fi
python3 "$ROOT/tools/eng05-instrument-check.py" "$WORK/instr-1x.ppm" "$WORK/instr-2x.ppm"
