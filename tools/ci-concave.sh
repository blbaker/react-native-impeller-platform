#!/usr/bin/env bash
# CONCAVE-FILL PROBE (internal request), impeller engine.
#
# Does a filled concave <Path> paint its true area, or its convex hull?
# Built by cloning ci-mark.sh's app setup and swapping the fixture.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
RNI_ENGINE_PKG="${RNI_ENGINE_PKG:-$ROOT/packages-engine/engine-linux-x64}"

fail() { echo "CONCAVE_FAIL: $*" >&2; exit 1; }

[ -d "$BASE_APP/node_modules/react-native" ] || bash tools/base-app.sh
[ -d "$BASE_APP/node_modules/react-native" ] || fail "no base RN app at $BASE_APP"

WORK="${CONCAVE_WORK:-$(mktemp -d)}"
echo "workdir: $WORK"
cleanup() { pgrep -x rn-impeller > /dev/null 2>&1 && pkill -x rn-impeller || true; }
trap cleanup EXIT

APP="$WORK/ConcaveApp"
if [ ! -d "$APP/node_modules/react-native-svg" ]; then
  echo "== 1. pack + install into a pristine app =="
  ENGINE_TGZ="$(cd "$RNI_ENGINE_PKG" && npm pack --silent --pack-destination "$WORK")"
  MAIN_TGZ="$(cd package && npm pack --silent --pack-destination "$WORK")"
  rm -rf "$APP"
  cp -R "$BASE_APP" "$APP"
  cd "$APP"
  node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="concaveapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="ConcaveProbe"; a.displayName="ConcaveProbe";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
  npm install --no-audit --no-fund --silent \
    "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" || fail "npm install of the tarballs failed"
  npm install --no-audit --no-fund --silent react-native-svg@15.15.5 \
    || fail "could not install react-native-svg"
  npx --no-install react-native init-impeller >/dev/null 2>&1 || fail "init-impeller failed"
fi

cd "$APP"
cp "$ROOT/fixtures/concave-probe/index.js" "$APP/index.js"
ENGINE="$(node node_modules/@react-native-impeller/core/src/bin/engine-path.js)" \
  || fail "engine resolver failed"
echo "engine: $ENGINE"

echo "== 2. bundle + render =="
mkdir -p impeller/build
npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/concave.bundle \
    >/dev/null 2>&1 || fail "bundle failed"

SHOT="$WORK/concave.ppm"
"$ENGINE" --bundle "$APP/impeller/build/concave.bundle" --app-name ConcaveProbe \
  --headless --probe-banner off --width 700 --height 300 --screenshot "$SHOT" \
  > "$WORK/run.log" 2>&1 || { tail -20 "$WORK/run.log" >&2; fail "engine run failed"; }
[ -s "$SHOT" ] || fail "no screenshot produced"

echo "== 3. measure painted area per case =="
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
print("   surface %dx%d" % (w,h))
def at(x,y):
    o=(y*w+x)*3
    return (px[o],px[o+1],px[o+2])
lit=[(x,y) for y in range(h) for x in range(w)
     if at(x,y)[1]>120 and at(x,y)[0]<120]
if not lit:
    print("CONCAVE_FAIL: nothing green painted at all"); sys.exit(1)
xs=sorted(set(x for x,y in lit)); groups=[]; cur=[xs[0]]
for x in xs[1:]:
    if x-cur[-1]<=1: cur.append(x)
    else: groups.append(cur); cur=[x]
groups.append(cur)
print("   shapes found: %d" % len(groups))
# true areas by shoelace; hull by convex hull of the same vertices.
# E's old notched pentagon had true 3100 vs hull 3200 -- a 3.2% gap that NO
# workable tolerance could separate, so that arm passed either way. E is now a
# deep V: true 4600, hull 6400, bbox 6400. Both wrong answers are +39%.
want=[6400,3200,4800,4800,4600]
hull=[6400,3200,5600,6400,6400]
bbox=[6400,3200,6400,6400,6400]
name=["A square ","B diamond","C the L  ","D arrow  ","E deep-V "]
bad=0
for i,g in enumerate(groups):
    if i>=len(want): break
    sel=[(x,y) for x,y in lit if g[0]<=x<=g[-1]]
    ys=[y for x,y in sel]; a=len(sel)
    err=100.0*(a-want[i])/want[i]
    # every concave arm now has >=16% clearance to both wrong answers, so 8%
    # cannot reach either one. Assert that, rather than trusting it.
    if want[i] != hull[i] and abs(hull[i]-want[i]) <= 0.16*want[i]:
        print("CONCAVE_FAIL: arm %d cannot distinguish true from hull" % i); sys.exit(1)
    if want[i] != bbox[i] and abs(bbox[i]-want[i]) <= 0.16*want[i]:
        print("CONCAVE_FAIL: arm %d cannot distinguish true from bbox" % i); sys.exit(1)
    if abs(err)<=8:
        verdict="TRUE-AREA"
    elif abs(a-hull[i])<=0.08*hull[i]:
        verdict="CONVEX-HULL"
    elif abs(a-bbox[i])<=0.08*bbox[i]:
        verdict="BOUNDING-BOX"
    else:
        verdict="NEITHER"
    if verdict!="TRUE-AREA": bad+=1
    print("   %s w=%3d h=%3d area=%5d true=%5d hull=%5d bbox=%5d err=%+6.1f%%  %s"
          % (name[i], g[-1]-g[0]+1, max(ys)-min(ys)+1, a, want[i], hull[i], bbox[i], err, verdict))
if len(groups)!=5:
    print("CONCAVE_FAIL: found %d shapes, want 5" % len(groups)); sys.exit(1)
if bad:
    print("CONCAVE_FAIL: %d case(s) did not paint their true area" % bad); sys.exit(1)
print("CONCAVE_PASS (C, D and E paint true area; hull and bbox both excluded)")
PY
