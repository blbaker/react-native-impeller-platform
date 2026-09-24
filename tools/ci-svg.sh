#!/usr/bin/env bash
# P9-B2 gate — do SVG paths actually PAINT, and is fill-opacity per-path?
#
# ⛔ THE FAILURE THIS EXISTS TO CATCH IS SILENT.
#
# An unregistered Fabric component mounts, paints nothing, and logs CLEANLY.
# So "no errors in the log" is worthless here, and so is "the app ran". The
# only evidence that <Path> works is pixels at known coordinates.
#
# Three probes, each failing differently (see fixtures/p9-svg/index.js):
#   1. SOLID      full-opacity path      -> must paint
#   2. INVISIBLE  same path, opacity 0   -> must NOT paint
#   3. RAMP       two paths, 0.25 / 0.75 -> must differ from EACH OTHER
#
# Probe 3 is the one that matters: a renderer ignoring fillOpacity passes 1,
# and one treating it as all-or-nothing passes 1 and 2. Only comparing two
# paths that differ ONLY in opacity proves the alpha is applied per path --
# the actual requirement, since the HostApp mark's grey ramp IS its antialiasing.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
RNI_ENGINE_PKG="${RNI_ENGINE_PKG:-$ROOT/packages-engine/engine-linux-x64}"

fail() { echo "SVG_GATE_FAIL: $*" >&2; exit 1; }

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
APP="$WORK/SvgApp"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="svgapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="P9Svg"; a.displayName="P9Svg";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent \
  "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" || fail "npm install of the tarballs failed"

# react-native-svg is a CONSUMER dependency, not something the engine vends.
# Installing it here is part of what the gate proves: a real app can add the
# library and have it render.
npm install --no-audit --no-fund --silent react-native-svg@15.15.5 \
  || fail "could not install react-native-svg into the consumer app"

echo "== 2. swap in the SVG fixture =="
cp "$ROOT/fixtures/p9-svg/index.js" "$APP/index.js"

npx --no-install react-native init-impeller >/dev/null 2>&1 || fail "init-impeller failed"
ENGINE="$(node node_modules/@react-native-impeller/core/src/bin/engine-path.js)" \
  || fail "engine resolver failed"

echo "== 3. bundle --platform impeller =="
npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/index.impeller.bundle \
    >/dev/null 2>&1 || fail "bundle failed"
BUNDLE="$APP/impeller/build/index.impeller.bundle"
[ -s "$BUNDLE" ] || fail "no bundle produced"

echo "== 4. render headless =="
SHOT="$WORK/svg.ppm"
# ⛔ --probe-banner off IS MANDATORY FOR ANY PIXEL GATE.
#
# The banner defaults ON and paints its own fixed shapes (a green square, a
# blue rounded rect, a purple circle, a grey bar) OVER the scene. It cost a
# long hunt here: every fixture -- 3-node, 5-node, different background colours
# -- produced BYTE-IDENTICAL screenshots, which reads like a stale-file or
# broken-readback bug rather than an overlay. The giveaway was two scenes with
# different node counts having identical md5s.
"$ENGINE" --bundle "$BUNDLE" --app-name P9Svg --headless --probe-banner off \
  --screenshot "$SHOT" > "$WORK/run.log" 2>&1 || { tail -20 "$WORK/run.log" >&2; fail "engine run failed"; }
[ -s "$SHOT" ] || fail "no screenshot produced"

# ⚠️ painted_nodes IS NOT EVIDENCE OF PIXELS. Measured here: an SVG scene
# reported scene_nodes=5 painted_nodes=5 and produced a frame that was 100%
# background. The counter records nodes VISITED by the painter, not ink laid
# down, so it stays green when a node's draw call is a no-op. Logged for
# context only -- every assertion below is on pixels.
grep -q "scene_nodes=" "$WORK/run.log" || fail "engine printed no node count"
echo "   $(grep -E 'scene_nodes|painted_nodes' "$WORK/run.log" | tr '\n' ' ')"

echo "== 5. probe pixels at the fixture's own coordinates =="
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
    w,h=int(parts[1]),int(parts[2])
    return w,h,d[i+1:]

w,h,px = read(sys.argv[1])
def at(x,y):
    o=(y*w+x)*3
    return tuple(px[o:o+3])

solid     = at(60, 60)     # probe 1: full-opacity red square
invisible = at(180, 60)    # probe 2: same square, fillOpacity 0
ramp_lo   = at(60, 190)    # probe 3a: blue @ 0.25
ramp_hi   = at(180, 190)   # probe 3b: blue @ 0.75
bg        = at(350, 280)   # untouched background

print(f"   solid={solid} invisible={invisible} ramp_lo={ramp_lo} ramp_hi={ramp_hi} bg={bg}")

fails=[]
if solid == bg:
    fails.append(f"SOLID path painted NOTHING (got {solid}, same as background {bg}). "
                 "This is the silent-registration failure: the component mounted and drew nothing.")
if not (solid[0] > 200 and solid[1] < 80 and solid[2] < 80):
    fails.append(f"SOLID path is not red: {solid}")
if invisible != bg:
    fails.append(f"fillOpacity=0 STILL PAINTED: {invisible} != background {bg}. fill-opacity is being ignored.")
if ramp_lo == ramp_hi:
    fails.append(f"the 0.25 and 0.75 paths are IDENTICAL ({ramp_lo}). "
                 "fill-opacity is not applied PER PATH -- the HostApp mark's grey ramp would collapse.")
if ramp_lo == bg or ramp_hi == bg:
    fails.append(f"a ramp path painted nothing: lo={ramp_lo} hi={ramp_hi} bg={bg}")
# The higher opacity must be the more saturated blue (further from white).
if ramp_lo != ramp_hi and not (ramp_hi[2] >= ramp_lo[2] and ramp_hi[0] < ramp_lo[0]):
    fails.append(f"ramp is inverted or wrong: 0.25->{ramp_lo} 0.75->{ramp_hi}")

if fails:
    for f in fails: print("SVG_GATE_FAIL: " + f, file=sys.stderr)
    sys.exit(1)
print(f"SVG_GATE_PASS (solid={solid} invisible=bg ramp {ramp_lo}->{ramp_hi})")
PY
