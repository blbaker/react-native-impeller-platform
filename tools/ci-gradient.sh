#!/usr/bin/env bash
# P9-F gate — gradient fills via url(#id).
#
# ⛔ A GRADIENT FILL IS A REFERENCE, NOT A COLOUR.
#
# extractBrush() emits {type: 0, payload} for a literal colour but
# {type: 1, brushRef: "id"} for fill="url(#id)". The <LinearGradient> is a
# separate node inside <Defs>, which never paints, so the engine must build a
# registry of defs and resolve the reference at paint time. Nothing on the
# shape's own props can produce the colour.
#
# THE ASSERTIONS ARE RAMP SHAPE, NOT PRESENCE:
#   1. LINEAR    the two ends must differ AND the midpoint must sit BETWEEN
#                them. A renderer that found the def but ignored the stops
#                (painting stop 0 as a flat fill) passes "did it paint".
#   2. RADIAL    centre must be much lighter than edge.
#   3. DANGLING  url(#nope) with no such def must paint NOTHING. Guessing a
#                colour would be a bug that looks like a design choice.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
RNI_ENGINE_PKG="${RNI_ENGINE_PKG:-$ROOT/packages-engine/engine-linux-x64}"

fail() { echo "GRADIENT_GATE_FAIL: $*" >&2; exit 1; }

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
APP="$WORK/GradApp"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="gradapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="P9Gradient"; a.displayName="P9Gradient";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent \
  "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" || fail "npm install of the tarballs failed"
npm install --no-audit --no-fund --silent react-native-svg@15.15.5 \
  || fail "could not install react-native-svg"

cp "$ROOT/fixtures/p9-gradient/index.js" "$APP/index.js"
npx --no-install react-native init-impeller >/dev/null 2>&1 || fail "init-impeller failed"
ENGINE="$(node node_modules/@react-native-impeller/core/src/bin/engine-path.js)" \
  || fail "engine resolver failed"

echo "== 2. bundle + render =="
npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/grad.bundle \
    >/dev/null 2>&1 || fail "bundle failed"

SHOT="$WORK/grad.ppm"
"$ENGINE" --bundle "$APP/impeller/build/grad.bundle" --app-name P9Gradient \
  --headless --probe-banner off --screenshot "$SHOT" \
  > "$WORK/run.log" 2>&1 || { tail -20 "$WORK/run.log" >&2; fail "engine run failed"; }
[ -s "$SHOT" ] || fail "no screenshot produced"

echo "== 3. probe the ramps =="
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

# 1. LINEAR red -> blue across a 200px-wide rect at x=20..220.
left, mid, right = at(25,60), at(120,60), at(215,60)
print(f"   linear  left={left} mid={mid} right={right}")
if left == WHITE and mid == WHITE and right == WHITE:
    fails.append("the linear-gradient rect painted NOTHING. A url(#id) brush "
                 "resolves to neither a fill colour nor a stroke colour, so a "
                 "paint guard testing only those flags skips the shape "
                 "entirely -- parsed fine, registry fine, no pixels.")
else:
    if left[0] < 200 or left[2] > 60:
        fails.append(f"linear left end is {left}, expected near-red.")
    if right[2] < 200 or right[0] > 60:
        fails.append(f"linear right end is {right}, expected near-blue.")
    if left == right:
        fails.append(f"linear ends are IDENTICAL ({left}) -- the stops are "
                     "being ignored and stop 0 painted as a flat fill.")
    # The midpoint must lie strictly between the ends on both channels.
    if not (right[0] < mid[0] < left[0] and left[2] < mid[2] < right[2]):
        fails.append(f"linear midpoint {mid} is not between {left} and {right} "
                     "-- the ramp is not interpolating across the shape.")

# 2. RADIAL white centre -> black edge, 120x120 square at (20,140).
centre, edge = at(80,200), at(25,200)
print(f"   radial  centre={centre} edge={edge}")
if centre == WHITE and edge == WHITE:
    fails.append("the radial-gradient rect painted NOTHING.")
elif centre[0] - edge[0] < 100:
    fails.append(f"radial centre {centre} is not much lighter than edge {edge} "
                 "-- the gradient is flat, or its geometry is resolved against "
                 "the wrong box (every RNSVG node's layout frame is the whole "
                 "surface, so using it stretches the ramp across the canvas).")

# 3. DANGLING url(#nope): must stay background.
dangling = at(310,190)
print(f"   dangling ref = {dangling}")
if dangling != WHITE:
    fails.append(f"url(#nope) painted {dangling}; an unresolved reference must "
                 "paint NOTHING rather than a guessed colour.")

if fails:
    for f in fails: print("GRADIENT_GATE_FAIL: " + f, file=sys.stderr)
    sys.exit(1)
print(f"GRADIENT_GATE_PASS (linear {left}->{mid}->{right} radial {centre}/{edge} "
      "dangling=empty)")
PY
