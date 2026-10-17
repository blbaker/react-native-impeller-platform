#!/usr/bin/env bash
# P9-E gate — the basic SVG shapes (Rect, Circle, Ellipse, Line).
#
# Each is converted to path data in SceneGraph and painted by the SAME fill and
# stroke code as <Path>, so this gate is really asking two things: did the
# component REGISTER (an unregistered one mounts, paints nothing and logs
# clean), and is the geometry conversion right?
#
# ⛔ GEOMETRY IS THE ASSERTION, NOT PRESENCE.
#
# A circle at the wrong centre, an ellipse that came out circular, a rect that
# ignored its corner radii -- all of them still "paint something", so every
# probe below pairs an INK point with an EMPTY point that only the correct
# geometry leaves background.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
RNI_ENGINE_PKG="${RNI_ENGINE_PKG:-$ROOT/packages-engine/engine-linux-x64}"

fail() { echo "SHAPES_GATE_FAIL: $*" >&2; exit 1; }

[ -d "$BASE_APP/node_modules/react-native" ] || bash tools/base-app.sh
[ -d "$BASE_APP/node_modules/react-native" ] || fail "no base RN app at $BASE_APP"

WORK="$(mktemp -d)"
KEEP="${KEEP_WORKDIR:-0}"
cleanup() {
  rni_kill_own
  [ "$KEEP" = "1" ] && echo "workdir kept: $WORK" || rm -rf "$WORK"
}
trap cleanup EXIT

echo "== 1. pack + install into a pristine app OUTSIDE the repo =="
ENGINE_TGZ="$(cd "$RNI_ENGINE_PKG" && npm pack --silent --pack-destination "$WORK")"
MAIN_TGZ="$(cd package && npm pack --silent --pack-destination "$WORK")"
APP="$WORK/ShapesApp"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="shapesapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="P9Shapes"; a.displayName="P9Shapes";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent \
  "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" || fail "npm install of the tarballs failed"
npm install --no-audit --no-fund --silent react-native-svg@15.15.5 \
  || fail "could not install react-native-svg"

cp "$ROOT/fixtures/p9-shapes/index.js" "$APP/index.js"
npx --no-install react-native init-impeller >/dev/null 2>&1 || fail "init-impeller failed"
ENGINE="$(node node_modules/react-native-impeller-platform/src/bin/engine-path.js)" \
  || fail "engine resolver failed"

echo "== 2. bundle + render =="
npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/shapes.bundle \
    >/dev/null 2>&1 || fail "bundle failed"

SHOT="$WORK/shapes.ppm"
"$ENGINE" --bundle "$APP/impeller/build/shapes.bundle" --app-name P9Shapes \
  --headless --probe-banner off --screenshot "$SHOT" \
  > "$WORK/run.log" 2>&1 || { tail -20 "$WORK/run.log" >&2; fail "engine run failed"; }
[ -s "$SHOT" ] || fail "no screenshot produced"

echo "== 3. probe ink AND emptiness for each shape =="
python3 - "$SHOT" <<'PY'
import sys
def read(p):
    d=open(p,'rb').read(); parts=[]; i=0
    while len(parts)<4:
        while d[i:i+1].isspace(): i+=1
        if d[i:i+1]==b'#':
            while d[i:i+1]!=b'\n': i+=1
            continue
        s=i
        while not d[i:i+1].isspace(): i+=1
        parts.append(d[s:i])
    return int(parts[1]),int(parts[2]),d[i+1:]

w,h,px = read(sys.argv[1])
def at(x,y):
    o=(y*w+x)*3
    return (px[o],px[o+1],px[o+2])

WHITE=(255,255,255)
fails=[]

# (name, colour, ink point, empty point, what the empty point proves)
probes = [
  ("Rect",    (255,0,0),   (70,55),   (22,22),
   "the corner is filled -- rx/ry were ignored and it drew a square rect"),
  ("Circle",  (0,0,255),   (215,55),  (183,23),
   "the bounding-box corner is filled -- a rect was drawn instead of a circle"),
  ("Ellipse", (0,128,0),   (80,200),  (80,172),
   "a point outside the y-radius is filled -- rx/ry swapped, or a circle of "
   "radius rx was drawn"),
  ("Line",    (255,0,255), (230,200), (230,220),
   "ink 20px off the line -- the stroke is far too wide, or a filled shape "
   "was drawn instead of an open path"),
]

for name, colour, ink, empty, why in probes:
    gi, ge = at(*ink), at(*empty)
    print(f"   {name:8s} ink{ink}={gi}  empty{empty}={ge}")
    if gi == WHITE:
        fails.append(f"{name} painted NOTHING at {ink}. The component is "
                     "probably not registered -- it would mount, count as "
                     "painted, and log cleanly.")
    elif gi != colour:
        fails.append(f"{name} at {ink} is {gi}, expected {colour}.")
    if ge != WHITE:
        fails.append(f"{name}: {empty} should be background but is {ge} -- {why}.")

if fails:
    for f in fails: print("SHAPES_GATE_FAIL: " + f, file=sys.stderr)
    sys.exit(1)
print("SHAPES_GATE_PASS (rect+circle+ellipse+line all painted with correct geometry)")
PY
