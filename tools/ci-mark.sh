#!/usr/bin/env bash
# P9 acceptance — can this engine draw the HostApp mark's STRUCTURE?
#
# ci-svg.sh proves the mechanism (a path fills, opacity is per-path). This
# proves the PRODUCT SHAPE: 17 filled paths in one <Svg>, nested in a <G>, one
# colour, differing only by fill-opacity -- because on the real mark the grey
# ramp IS the antialiasing.
#
# ⛔ THE ASSERTION IS A COUNT OF DISTINCT ALPHA LEVELS, AND THAT IS THE POINT.
#
# "Did something paint?" passes on a flat blob. "Is it grey?" passes on a flat
# blob. A renderer that applied opacity globally, or once to the <G> instead of
# per path, produces ONE grey and a mark that reads as a solid disc -- visually
# obvious to a human, invisible to every cheaper check. Counting the levels is
# the assertion that cannot be satisfied by accident.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
RNI_ENGINE_PKG="${RNI_ENGINE_PKG:-$ROOT/packages-engine/engine-linux-x64}"
WEDGES=17

fail() { echo "MARK_GATE_FAIL: $*" >&2; exit 1; }

[ -d "$BASE_APP/node_modules/react-native" ] || bash tools/base-app.sh
[ -d "$BASE_APP/node_modules/react-native" ] || fail "no base RN app at $BASE_APP"

WORK="$(mktemp -d)"
KEEP="${KEEP_WORKDIR:-0}"
cleanup() {
  pgrep -x rn-impeller > /dev/null 2>&1 && pkill -x rn-impeller || true
  [ "$KEEP" = "1" ] && echo "workdir kept: $WORK" || rm -rf "$WORK"
}
trap cleanup EXIT

echo "== 1. pack + install into a pristine app OUTSIDE the repo =="
ENGINE_TGZ="$(cd "$RNI_ENGINE_PKG" && npm pack --silent --pack-destination "$WORK")"
MAIN_TGZ="$(cd package && npm pack --silent --pack-destination "$WORK")"
APP="$WORK/MarkApp"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="markapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="P9Mark"; a.displayName="P9Mark";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent \
  "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" || fail "npm install of the tarballs failed"
npm install --no-audit --no-fund --silent react-native-svg@15.15.5 \
  || fail "could not install react-native-svg"

cp "$ROOT/fixtures/p9-mark/index.js" "$APP/index.js"
npx --no-install react-native init-impeller >/dev/null 2>&1 || fail "init-impeller failed"
ENGINE="$(node node_modules/@react-native-impeller/core/src/bin/engine-path.js)" \
  || fail "engine resolver failed"

echo "== 2. bundle + render =="
npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/mark.bundle \
    >/dev/null 2>&1 || fail "bundle failed"

SHOT="$WORK/mark.ppm"
# --probe-banner off is mandatory: the banner overpaints the scene and would
# contribute its own colours to the level count.
"$ENGINE" --bundle "$APP/impeller/build/mark.bundle" --app-name P9Mark \
  --headless --probe-banner off --screenshot "$SHOT" \
  > "$WORK/run.log" 2>&1 || { tail -20 "$WORK/run.log" >&2; fail "engine run failed"; }
[ -s "$SHOT" ] || fail "no screenshot produced"

echo "== 3. count DISTINCT grey levels =="
python3 - "$SHOT" "$WEDGES" <<'PY'
import sys
from collections import Counter
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
want = int(sys.argv[2])
counts = Counter()
for o in range(0, len(px), 3):
    counts[(px[o],px[o+1],px[o+2])] += 1

# Neutral greys only, background excluded. Each wedge is black at a different
# alpha over white, so every level must be r==g==b.
greys = sorted({c[0] for c in counts if c[0]==c[1]==c[2] and c[0] != 255})
print(f"   distinct grey levels: {len(greys)} (want {want})")
print(f"   levels: {greys}")

if len(greys) == 0:
    print("MARK_GATE_FAIL: the mark painted NOTHING -- no non-white pixels at all.",
          file=sys.stderr); sys.exit(1)
if len(greys) == 1:
    print(f"MARK_GATE_FAIL: only ONE grey level ({greys[0]}). Every wedge rendered "
          "identically, so fill-opacity is global or applied to the <G> rather than "
          "per path -- the mark would read as a flat disc.", file=sys.stderr); sys.exit(1)
if len(greys) != want:
    print(f"MARK_GATE_FAIL: {len(greys)} distinct levels, expected {want}. "
          "Wedges are collapsing into each other.", file=sys.stderr); sys.exit(1)

# The ramp must be MONOTONIC and evenly spaced: alpha (i+1)/17 over white gives
# 255*(1 - (i+1)/17), i.e. a constant step of 15. A renderer that quantised or
# reordered alpha could still produce 17 levels.
steps = {greys[i+1]-greys[i] for i in range(len(greys)-1)}
print(f"   step sizes: {sorted(steps)}")
if len(steps) != 1:
    print(f"MARK_GATE_FAIL: ramp is not evenly spaced (steps {sorted(steps)}). "
          "Alpha is being quantised or misapplied.", file=sys.stderr); sys.exit(1)

print(f"MARK_GATE_PASS ({len(greys)} even grey levels, step {steps.pop()})")
PY
