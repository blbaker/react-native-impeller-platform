#!/usr/bin/env bash
# P9-A gate 2/2 — does the repaint loop draw a SECOND, DIFFERENT frame?
#
# ⛔ WHY ci-window.sh IS NOT ENOUGH, AND WHY THIS IS THE GATE THAT MATTERS
#
# ci-window.sh proves the window opens, survives N frames, and exits 0. Every
# one of those assertions passes on an engine that paints frame 0 and then
# redraws THE SAME PIXELS twenty times. That is indistinguishable from the
# exit-3 stub in every way a user cares about: a loading animation would sit
# perfectly still.
#
# It is worse than a normal gap, because requestAnimationFrame ALREADY worked
# on this engine before any repaint loop existed (bridgeless TimerManager
# installs it as a host function). JS ticks, state updates, Fabric commits --
# and one frame gets painted. So the natural assertions (callback fired? state
# changed? commit happened?) ALL pass on a static renderer.
#
# The only thing that can tell the two apart is pixels from two different
# moments in time. That is this file.
#
# Matched pair, so the gate cannot pass vacuously:
#   POSITIVE  animating fixture  -> frame 0 and a later frame MUST differ
#   NEGATIVE  static fixture     -> frame 0 and a later frame MUST be identical
# The negative is what proves "differs" means real content change and not
# rasteriser noise, timing jitter, or an uninitialised buffer.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
CI_TOOLS="$ROOT/tools"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
RNI_ENGINE_PKG="${RNI_ENGINE_PKG:-$ROOT/packages-engine/engine-linux-x64}"

fail() { echo "ANIMATE_GATE_FAIL: $*" >&2; exit 1; }

[ -d "$BASE_APP/node_modules/react-native" ] || bash tools/base-app.sh
[ -d "$BASE_APP/node_modules/react-native" ] || fail "no base RN app at $BASE_APP"

WORK="$(mktemp -d)"
KEEP="${KEEP_WORKDIR:-0}"
cleanup() {
  pgrep -x rn-impeller > /dev/null 2>&1 && pkill -x rn-impeller || true
  [ "$KEEP" = "1" ] && echo "workdir kept: $WORK" || rm -rf "$WORK"
}
trap cleanup EXIT

build_app() {
  local appname="$1" fixture="$2" appdir="$3"
  cp -R "$BASE_APP" "$appdir"
  ( cd "$appdir"
    node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="animapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name=process.argv[1]; a.displayName=process.argv[1];
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
' "$appname"
    npm install --no-audit --no-fund --silent \
      "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" || exit 1
    cp "$fixture/index.js" ./index.js
    [ -f "$fixture/fixture.json" ] && cp "$fixture/fixture.json" ./fixture.json
    npx --no-install react-native init-impeller >/dev/null 2>&1 || exit 1
    npx --no-install react-native bundle --platform impeller --dev false \
      --entry-file index.js --bundle-output impeller/build/index.impeller.bundle \
      >/dev/null 2>&1 || exit 1
  ) || fail "could not build app $appname"
}

echo "== 1. pack the engine + main package =="
ENGINE_TGZ="$(cd "$RNI_ENGINE_PKG" && npm pack --silent --pack-destination "$WORK")"
MAIN_TGZ="$(cd package && npm pack --silent --pack-destination "$WORK")"

echo "== 2. build BOTH apps: animating (positive) and static (negative) =="
build_app "P9Repaint" "$ROOT/fixtures/p9-repaint"    "$WORK/anim"
build_app "P3Fixture" "$ROOT/fixtures/p3-conformance" "$WORK/static"

ENGINE="$(node "$WORK/anim/node_modules/@react-native-impeller/core/src/bin/engine-path.js")" \
  || fail "engine resolver failed"

# Capture two frames from ONE run: frame 0, and a frame >= 300ms later. Two
# separate runs would compare two different process lifetimes and could differ
# for reasons having nothing to do with repainting.
#
# ⚠️ --frames MUST outlast --screenshot-after, and the margin is bigger than it
# looks. This loop renders ~1000 fps on llvmpipe, so --frames 40 finished in
# under 50ms and the process EXITED BEFORE the 400ms capture point -- producing
# no file at all, which reads exactly like a broken capture rather than a run
# that ended early. 600 frames comfortably covers 300ms; the timed capture
# lands around frame 328.
capture_pair() {
  local appdir="$1" tag="$2" appname="$3"
  ( cd "$appdir"
    DISPLAY="${DISPLAY:-:0}" timeout 60 "$ENGINE" \
      --bundle "$appdir/impeller/build/index.impeller.bundle" \
      --app-name "$appname" \
      --window --frames 600 \
      --screenshot "$WORK/$tag-late.ppm" --screenshot-after 300 \
      --screenshot-first "$WORK/$tag-first.ppm" \
      > "$WORK/$tag.log" 2>&1
  ) || true
  [ -s "$WORK/$tag-first.ppm" ] || fail "$tag: no frame-0 capture (see $WORK/$tag.log)"
  [ -s "$WORK/$tag-late.ppm" ]  || fail "$tag: no later capture (see $WORK/$tag.log)"
}

echo "== 3. capture frame 0 + a later frame, animating fixture =="
capture_pair "$WORK/anim" "anim" "P9Repaint"

echo "== 4. capture frame 0 + a later frame, STATIC fixture (the control) =="
capture_pair "$WORK/static" "static" "P3Fixture"

diff_px() {
  python3 - "$1" "$2" <<'PY'
import sys
def read(p):
    d = open(p,'rb').read()
    # P6 header: magic, width, height, maxval -- then binary RGB.
    parts, idx = [], 0
    while len(parts) < 4:
        while d[idx:idx+1].isspace(): idx += 1
        if d[idx:idx+1] == b'#':
            while d[idx:idx+1] != b'\n': idx += 1
            continue
        s = idx
        while not d[idx:idx+1].isspace(): idx += 1
        parts.append(d[s:idx])
    return d[idx+1:]
a, b = read(sys.argv[1]), read(sys.argv[2])
if len(a) != len(b):
    print(-1); sys.exit(0)
print(sum(1 for i in range(0, len(a), 3) if a[i:i+3] != b[i:i+3]))
PY
}

ANIM_DIFF="$(diff_px "$WORK/anim-first.ppm" "$WORK/anim-late.ppm")"
STATIC_DIFF="$(diff_px "$WORK/static-first.ppm" "$WORK/static-late.ppm")"

echo "   animating fixture: $ANIM_DIFF px changed between frame 0 and later"
echo "   static fixture:    $STATIC_DIFF px changed between frame 0 and later"

[ "$ANIM_DIFF" -gt 100 ] \
  || fail "the repaint loop is not drawing new content: only $ANIM_DIFF px changed on an ANIMATING fixture. This is exactly the static-engine failure mode -- rAF fires, JS commits, and one frame is painted."

[ "$STATIC_DIFF" -eq 0 ] \
  || fail "the STATIC control changed by $STATIC_DIFF px, so 'differs' does not mean 'new content' -- the positive result above is not trustworthy."

echo "ANIMATE_GATE_PASS (animating=${ANIM_DIFF}px static=${STATIC_DIFF}px)"
