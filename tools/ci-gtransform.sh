#!/usr/bin/env bash
# P9-C gate — does <G transform> move its children?
#
# ⛔ THIS BUG SHIPPED ONCE ALREADY, ON THE SIBLING ENGINE.
#
# rn-skia-prototype carries RNSVGGroupProps::matrix and never reads
# it, so <G transform> is silently dropped there: no error, art just renders at
# the wrong size. It cost a long hunt (4.87x oversizing) and the macOS tester
# still carries a viewBox workaround because of it. This gate is what stops the
# same thing being true here.
#
# ⛔ THE ASSERTION IS POSITION, NOT PRESENCE.
#
# A renderer that ignores the transform still paints a perfectly good square --
# it just paints it in the wrong place. "Did it paint?" passes. So all three
# probes draw the SAME `d` string and are told apart ONLY by where they land.
#
# Reproduction of the failure, measured on this engine before the fix:
#   red -> None, blue -> None, green -> (0,0,39,39)
# i.e. every box stacked at the origin, last-drawn winning, and the 2x scale
# ignored (40x40 instead of 80x80).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
RNI_ENGINE_PKG="${RNI_ENGINE_PKG:-$ROOT/packages-engine/engine-linux-x64}"

fail() { echo "GTRANSFORM_GATE_FAIL: $*" >&2; exit 1; }

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
APP="$WORK/GtApp"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="gtapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="P9GTransform"; a.displayName="P9GTransform";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent \
  "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" || fail "npm install of the tarballs failed"
npm install --no-audit --no-fund --silent react-native-svg@15.15.5 \
  || fail "could not install react-native-svg"

cp "$ROOT/fixtures/p9-gtransform/index.js" "$APP/index.js"
npx --no-install react-native init-impeller >/dev/null 2>&1 || fail "init-impeller failed"
ENGINE="$(node node_modules/@react-native-impeller/core/src/bin/engine-path.js)" \
  || fail "engine resolver failed"

echo "== 2. bundle + render =="
npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/gt.bundle \
    >/dev/null 2>&1 || fail "bundle failed"

SHOT="$WORK/gt.ppm"
# --probe-banner off is mandatory: the banner overpaints the scene and would
# contribute its own coloured shapes to the bounding boxes below.
"$ENGINE" --bundle "$APP/impeller/build/gt.bundle" --app-name P9GTransform \
  --headless --probe-banner off --screenshot "$SHOT" \
  > "$WORK/run.log" 2>&1 || { tail -20 "$WORK/run.log" >&2; fail "engine run failed"; }
[ -s "$SHOT" ] || fail "no screenshot produced"

echo "== 3. probe each box's BOUNDING BOX =="
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
def bbox(target):
    xs=[]; ys=[]
    for y in range(h):
        row=y*w
        for x in range(w):
            o=(row+x)*3
            if (px[o],px[o+1],px[o+2])==target:
                xs.append(x); ys.append(y)
    return (min(xs),min(ys),max(xs),max(ys)) if xs else None

# Each <G> translates a 40x40 box drawn at the origin. Expected boxes are
# inclusive pixel bounds, so a 40-wide box spans x..x+39.
probes = [
    ("control  translate(10,10)",    (255,0,0),   (10,10,49,49)),
    ("translate(110,70)",            (0,0,255),   (110,70,149,109)),
    ("translate(200,150) scale(2)",  (0,128,0),   (200,150,279,229)),
]

fails=[]
for name, colour, want in probes:
    got = bbox(colour)
    print(f"   {name:30s} -> {got}  want {want}")
    if got is None:
        fails.append(f"{name}: painted NOTHING. Either the path did not render, "
                     "or the transform moved it off-surface.")
    elif got != want:
        fails.append(f"{name}: at {got}, expected {want}. "
                     "<G transform> is being dropped or misapplied.")

# ⛔ THE ROTATION PROBE, AND WHY IT IS SEPARATE.
#
# translate() and uniform scale() both have b == c == 0, so TRANSPOSING the
# two off-diagonal matrix terms is a perfect no-op for every probe above --
# verified: a b/c-transposed mutant passed all three. Only a rotation can see
# it, because a transpose there negates the angle and mirrors the result.
#
# Tolerance of 3px, not exact: the shape's edges land on fractional pixels, so
# antialiased coverage decides whether the outermost row/column is exactly the
# probe colour. The wrong-direction rotation this catches is off by ~50px in y,
# nowhere near the tolerance.
rot = bbox((255,0,255))
want_rot = (290, 40, 334, 76)
tol = 3
print(f"   {'translate(300,40) rotate(30)':30s} -> {rot}  want ~{want_rot} (+/-{tol})")
if rot is None:
    fails.append("rotate(30): painted NOTHING.")
elif any(abs(rot[i]-want_rot[i]) > tol for i in range(4)):
    fails.append(f"rotate(30): at {rot}, expected ~{want_rot}. The matrix's b/c "
                 "terms are transposed (rotation is going the wrong way) -- "
                 "translate and uniform scale would still look perfect.")

# An explicit stacking check: the classic dropped-matrix symptom is every box
# landing on the SAME origin, where later draws hide earlier ones. Saying so by
# name beats leaving the reader to infer it from three coordinate mismatches.
boxes = [bbox(c) for _, c, _ in probes]
present = [b for b in boxes if b]
if len(present) > 1 and len({(b[0],b[1]) for b in present}) == 1:
    fails.append("every box shares one origin -- <G transform> is being IGNORED "
                 "entirely (this is the skia-platform bug reproducing).")

if fails:
    for f in fails: print("GTRANSFORM_GATE_FAIL: " + f, file=sys.stderr)
    sys.exit(1)
print("GTRANSFORM_GATE_PASS (translate and scale both applied, subtree included)")
PY
