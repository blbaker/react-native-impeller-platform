#!/usr/bin/env bash
# parity item 8 GATE: a parent's `opacity` applies to its children.
#
# The Mac audit measured pixel (255,0,0) under an opacity:0 parent: opacity was
# applied per draw call to the node's OWN paint only, so children painted at
# full strength. Fixture: white background, 60x60 parents with a 40x40 red
# child. Expected (sRGB, tolerance 16 per channel):
#   P0 opacity 0     (50,50)  -> white (255,255,255)
#   P5 opacity 0.5   (130,50) -> (255,128,128)
#   P1 opacity 1     (210,50) -> red (255,0,0)
#   N  0.5 x 0.5     (290,50) -> (255,191,191)
#   O  0.5 group, blue child over red child: overlap (60,130) -> half BLUE
#      over WHITE (128,128,255). Per-child alpha would give blue-over-red
#      (~(64,64,191)+red) instead: only a group layer passes.
#   B  0.5 parent with its own blue background: (185,105) -> (128,128,255),
#      its red child (210,130) -> (255,128,128). Opacity applied twice would
#      give a quarter-blue parent.
# Run headless AND windowed (the windowed path is what HostApp uses).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
CI_TOOLS="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$0")/.."
ROOT="$PWD"
. "$CI_TOOLS/ci-triple.sh"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
FIXTURE="$ROOT/fixtures/item8-opacity"
APP_NAME="Item8Opacity"

fail() { echo "OPACITY_GATE_FAIL: $*" >&2; exit 1; }

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
APP="$WORK/OpacityApp"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="opacityapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="Item8Opacity"; a.displayName="Opacity Fixture";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" \
  || fail "npm install of the tarballs failed"

echo "== 2. swap in the item 8 opacity fixture as the app entry =="
cp "$FIXTURE/index.js" "$APP/index.js"
npx --no-install react-native init-impeller > /dev/null 2>&1 || fail "init-impeller failed"
RESOLVED="$(node node_modules/react-native-impeller-platform/src/bin/engine-path.js)" || fail "engine resolver failed"

npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/opacity.bundle \
    > /dev/null 2>&1
BUNDLE="$APP/impeller/build/opacity.bundle"
[ -s "$BUNDLE" ] || fail "no bundle produced"
cd "$ROOT"







WIN_W=400
WIN_H=300

probe() {  # $1 = ppm; prints "x,y=r,g,b" for every probe point
  python3 - "$1" <<'PY'
import sys
d = open(sys.argv[1], "rb").read(); parts = d.split(b"\n", 3)
w = int(parts[1].split()[0]); b = parts[3]
for (x, y) in [(50, 50), (130, 50), (210, 50), (290, 50), (60, 130), (35, 115), (185, 105), (210, 130)]:
    i = (y * w + x) * 3
    print("%d,%d=%d,%d,%d" % (x, y, b[i], b[i + 1], b[i + 2]))
PY
}
expect() {  # $1 = probe output, $2 = "x,y", $3 = "r,g,b", $4 = message
  local got
  got="$(echo "$1" | sed -n "s/^$2=//p")"
  python3 -c '
import sys
g = [int(v) for v in sys.argv[1].split(",")]; w = [int(v) for v in sys.argv[2].split(",")]
sys.exit(0 if all(abs(a - b) <= 16 for a, b in zip(g, w)) else 1)
' "$got" "$3" || fail "$4 at ($2): got ($got), want ($3)"
}

check() {  # $1 = mode label, $2 = ppm
  local P
  P="$(probe "$2")"
  echo "$P" | sed "s/^/   [$1] /"
  expect "$P" "50,50"  "255,255,255" "$1: a red child under an opacity:0 parent must be invisible -- parent opacity does not apply to children"
  expect "$P" "130,50" "255,128,128" "$1: a red child under an opacity:0.5 parent must be half red -- parent opacity does not apply to children"
  expect "$P" "210,50" "255,0,0"     "$1: opacity:1 must leave the child solid red"
  expect "$P" "290,50" "255,191,191" "$1: nested 0.5 x 0.5 must give 25% red -- nested opacity does not multiply"
  expect "$P" "60,130" "128,128,255" "$1: where a blue child overlaps a red child inside one opacity:0.5 parent, the result must be half blue over white -- opacity is applied per child, not as one group"
  expect "$P" "35,115" "255,128,128" "$1: the red-only part of the group must be half red"
  expect "$P" "185,105" "128,128,255" "$1: an opacity:0.5 parent's OWN background must be half blue -- opacity is applied twice"
  expect "$P" "210,130" "255,128,128" "$1: the red child of the blue opacity:0.5 parent must be half red -- parent opacity does not apply to children"
}

echo "== a. headless =="
"$RESOLVED" --bundle "$BUNDLE" --app-name "$APP_NAME" --headless --probe-banner off \
  --width "$WIN_W" --height "$WIN_H" --supersample-rnsvg 0 --screenshot "$WORK/headless.ppm" \
  > "$WORK/headless.log" 2>&1 || { tail -20 "$WORK/headless.log" >&2; fail "headless run failed"; }
grep -qE '^rn-impeller: scene_nodes=[1-9]' "$WORK/headless.log" || fail "headless: the fixture mounted nothing"
check headless "$WORK/headless.ppm"
echo "   OK: headless"

echo "== b. windowed =="
set +e
"$RESOLVED" --window --probe-banner off --bundle "$BUNDLE" --app-name "$APP_NAME" \
  --width "$WIN_W" --height "$WIN_H" --supersample-rnsvg 0 --frames 600 \
  --screenshot "$WORK/window.ppm" --screenshot-after 300 > "$WORK/window.log" 2>&1
rc=$?
set -e
[ "$rc" -eq 0 ] || { tail -20 "$WORK/window.log" >&2; fail "windowed run exited $rc"; }
grep -qE '^rn-impeller: scene_nodes=[1-9]' "$WORK/window.log" || fail "windowed: the fixture mounted nothing"
check window "$WORK/window.ppm"
echo "   OK: windowed"

echo "OPACITY_GATE_PASS (parent opacity applies to children as one group; 0, 0.5, 1, nested, overlap; headless + windowed)"
