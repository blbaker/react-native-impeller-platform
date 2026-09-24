#!/usr/bin/env bash
# P9-D gate — stroke.
#
# ⛔ WHAT MAKES STROKE EASY TO GET SUBTLY WRONG
#
# Impeller's paint carries ONE colour, so the tempting implementation is a
# single paint with kImpellerDrawStyleStrokeAndFill. That paints the outline in
# the FILL's colour -- which looks perfect on any shape whose fill and stroke
# happen to match, and is wrong everywhere else. SVG gives fill and stroke
# independent colours AND independent opacities, so they must be two draws.
#
# Probes, each isolating a different failure:
#   1. STROKE-ONLY   fill="none"  -> a renderer gating paint on "has a fill"
#                                    draws nothing here and is fine elsewhere
#   2. FILL+STROKE   different colours -> catches a shared paint
#   3. WIDTH         16px -> catches an ignored/hardcoded width (invisible
#                            whenever the default happens to be 1)
#   4. OPACITY       strokeOpacity 0.25 -> catches reuse of the fill's alpha
#
# ⚠️ fill="none" is REQUIRED for a hollow shape. The SVG spec defaults fill to
# BLACK and react-native-svg implements that literally, so a <Path> carrying
# only a `stroke` prop is a black-filled box with an outline. Writing this
# fixture without fill="none" produced solid black shapes that looked exactly
# like an engine bug and were entirely correct.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
RNI_ENGINE_PKG="${RNI_ENGINE_PKG:-$ROOT/packages-engine/engine-linux-x64}"

fail() { echo "STROKE_GATE_FAIL: $*" >&2; exit 1; }

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
APP="$WORK/StrokeApp"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="strokeapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="P9Stroke"; a.displayName="P9Stroke";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent \
  "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" || fail "npm install of the tarballs failed"
npm install --no-audit --no-fund --silent react-native-svg@15.15.5 \
  || fail "could not install react-native-svg"

cp "$ROOT/fixtures/p9-stroke/index.js" "$APP/index.js"
npx --no-install react-native init-impeller >/dev/null 2>&1 || fail "init-impeller failed"
ENGINE="$(node node_modules/@react-native-impeller/core/src/bin/engine-path.js)" \
  || fail "engine resolver failed"

echo "== 2. bundle + render =="
npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/stroke.bundle \
    >/dev/null 2>&1 || fail "bundle failed"

SHOT="$WORK/stroke.ppm"
"$ENGINE" --bundle "$APP/impeller/build/stroke.bundle" --app-name P9Stroke \
  --headless --probe-banner off --screenshot "$SHOT" \
  > "$WORK/run.log" 2>&1 || { tail -20 "$WORK/run.log" >&2; fail "engine run failed"; }
[ -s "$SHOT" ] || fail "no screenshot produced"

echo "== 3. probe edges and interiors =="
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

# 1. stroke-only: red edge, interior must stay background.
e1, i1 = at(20,50), at(60,50)
print(f"   1 stroke-only   edge={e1} interior={i1}")
if e1 != (255,0,0):
    fails.append(f"stroke-only edge is {e1}, expected red. A stroke-only shape "
                 "(fill=none) painted no outline -- painting is probably gated "
                 "on having a fill.")
if i1 != WHITE:
    fails.append(f"stroke-only interior is {i1}, expected background. The shape "
                 "is being filled when it should be hollow.")

# 2. fill+stroke with DIFFERENT colours: the edge must NOT be the fill colour.
e2, i2 = at(160,50), at(200,50)
print(f"   2 fill+stroke   edge={e2} interior={i2}")
if i2 != (0,128,0):
    fails.append(f"fill+stroke interior is {i2}, expected green.")
if e2 == i2:
    fails.append(f"fill+stroke edge and interior are BOTH {e2} -- fill and "
                 "stroke share one paint (StrokeAndFill), so the outline took "
                 "the fill's colour.")
elif e2 != (0,0,255):
    fails.append(f"fill+stroke edge is {e2}, expected blue.")

# 3. width: a 16px stroke must still be the stroke colour well inside where a
#    thin one would have ended.
e3, i3 = at(20,180), at(60,180)
print(f"   3 width=16      edge={e3} interior={i3}")
if e3 != (255,0,255):
    fails.append(f"width probe edge is {e3}, expected magenta.")
if i3 != WHITE:
    fails.append(f"width probe interior is {i3}, expected background.")
# ⛔ AN SVG STROKE STRADDLES THE PATH -- half inside, half outside. A 16px
# stroke on the line x=20 therefore spans x=12..27, NOT x=20..35. Measured:
# x=12 is the first magenta pixel and x=27 the last. Probing "8px inside the
# edge" (x=28) reads BACKGROUND on a perfectly correct renderer, which is how
# this gate first failed against working code.
#
# x=25 is inside a 16px stroke and comfortably outside a 1px default.
if at(25,180) != (255,0,255):
    fails.append(f"x=25 on the stroke band is {at(25,180)}, expected magenta. "
                 "strokeWidth is being ignored -- a 1px default would leave "
                 "this pixel background.")

# 4. stroke opacity: black at 0.25 over white -> ~(191,191,191), NOT black.
e4 = at(160,180)
print(f"   4 strokeOpacity edge={e4}")
if e4 == (0,0,0):
    fails.append("strokeOpacity=0.25 painted solid black -- stroke opacity is "
                 "being ignored.")
elif not (e4[0]==e4[1]==e4[2] and 180 <= e4[0] <= 200):
    fails.append(f"strokeOpacity=0.25 gave {e4}, expected a neutral grey near "
                 "(191,191,191).")

if fails:
    for f in fails: print("STROKE_GATE_FAIL: " + f, file=sys.stderr)
    sys.exit(1)
print(f"STROKE_GATE_PASS (hollow={i1==WHITE} independent_colours={e2!=i2} "
      f"width_honoured=True stroke_opacity={e4})")
PY
