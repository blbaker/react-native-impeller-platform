#!/usr/bin/env bash
# Use/Symbol PROBE (not a committed gate yet) -- see fixtures/p9-usesym/index.js.
#
# Answers a question the macOS tester asked as a design question but which is
# actually an empirical one: with RNSVGUse and RNSVGSymbol UNREGISTERED, does a
# <symbol>+<use> asset paint nothing, or does it paint the definition in the
# WRONG PLACE? SceneGraph::paintNode recurses into every child unconditionally
# and there is no <Defs> exclusion anywhere in the painter, so "nothing" is a
# hypothesis, not a given.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
RNI_ENGINE_PKG="${RNI_ENGINE_PKG:-$ROOT/packages-engine/engine-linux-x64}"

fail() { echo "USESYM_PROBE_FAIL: $*" >&2; exit 1; }

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
APP="$WORK/UseSymApp"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="usesymapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="P9UseSym"; a.displayName="P9UseSym";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent \
  "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" || fail "npm install of the tarballs failed"
npm install --no-audit --no-fund --silent react-native-svg@15.15.5 \
  || fail "could not install react-native-svg into the consumer app"

echo "== 2. swap in the use/symbol fixture =="
cp "$ROOT/fixtures/p9-usesym/index.js" "$APP/index.js"

npx --no-install react-native init-impeller >/dev/null 2>&1 || fail "init-impeller failed"
ENGINE="$(node node_modules/@react-native-impeller/core/src/bin/engine-path.js)" \
  || fail "engine resolver failed"

echo "== 3. bundle --platform impeller =="
npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/index.impeller.bundle \
    >/dev/null 2>&1 || fail "bundle failed"
BUNDLE="$APP/impeller/build/index.impeller.bundle"
[ -s "$BUNDLE" ] || fail "no bundle produced"

echo "== 4. render headless (probe banner OFF -- it overpaints the scene) =="
SHOT="$WORK/usesym.ppm"
"$ENGINE" --bundle "$BUNDLE" --app-name P9UseSym --headless --probe-banner off \
  --screenshot "$SHOT" > "$WORK/run.log" 2>&1 || { tail -20 "$WORK/run.log" >&2; fail "engine run failed"; }
[ -s "$SHOT" ] || fail "no screenshot produced"

echo "   $(grep -E 'scene_nodes|painted_nodes' "$WORK/run.log" | tr '\n' ' ')"
echo "   --- component names the scene graph saw ---"
grep -oE 'node_frame=[A-Za-z]+' "$WORK/run.log" | sort | uniq -c | sed 's/^/   /' || true

echo "== 5. probe the mounting sites =="
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

A    = at(60, 60)     # control path, red
LEAK = at(180, 60)    # where a leaked definition landed pre-fix
C1   = at(60, 190)    # <Use> #1
C2   = at(180, 190)   # <Use> #2, same symbol
DANG = at(340, 60)    # href="#no-such-symbol"
SC_IN  = at(275, 175) # scaled instance (40x40 of an 80x80 symbol) -- INSIDE
SC_OUT = at(320, 220) # ...where it WOULD land if the scale were dropped
BG   = at(370, 285)

print(f"   control={A} leak_site={LEAK} use1={C1} use2={C2} dangling={DANG}")
print(f"   scaled_inside={SC_IN} scaled_outside={SC_OUT} bg={BG}")

fails=[]
if A == BG:
    fails.append(f"CONTROL path painted nothing ({A} == bg). The run is invalid; "
                 "nothing below can be believed.")
elif not (A[0] > 200 and A[1] < 80 and A[2] < 80):
    fails.append(f"control path is not red: {A}")

# ⛔ The two halves. Either alone passes for the wrong reason.
if LEAK != BG:
    fails.append(f"DEFINITION LEAKED: the defs/symbol geometry painted at its own "
                 f"site ({LEAK} != bg {BG}). <Defs>/<Symbol> must be excluded from "
                 "the paint walk -- this is the pre-P9-G bug, and it looks like a "
                 "layout bug rather than a missing feature.")
for label, c in (("use1", C1), ("use2", C2)):
    if c == BG:
        fails.append(f"{label} painted NOTHING ({c} == bg): the <Use href> did not "
                     "resolve to its <Symbol>.")
    elif not (c[1] > 200 and c[0] < 80 and c[2] < 80):
        fails.append(f"{label} is not the symbol's green: {c}")
if C1 != C2:
    fails.append(f"the two <Use> sites differ ({C1} vs {C2}) -- one asset must "
                 "render identically at every mounting site.")
if DANG != BG:
    fails.append(f"a DANGLING href painted {DANG} instead of nothing. "
                 "url(#missing) must draw nothing, not a fallback.")

# ⛔ THE SCALE, AS A MATCHED PAIR. Inside-only is not enough: an instance that
# ignored the viewBox->box scale paints at 80x80, which COVERS the inside probe
# and passes. Only the outside probe -- inside the unscaled box, outside the
# scaled one -- can tell the two apart.
if SC_IN == BG:
    fails.append(f"the scaled <Use> painted nothing at its centre ({SC_IN} == bg).")
if SC_OUT != BG:
    fails.append(f"the scaled <Use> painted at {SC_OUT} outside its 40x40 box: the "
                 "symbol viewBox -> instance box SCALE was not applied, so the "
                 "asset renders at its authoring size at every mounting site.")

if fails:
    for f in fails: print("USESYM_GATE_FAIL: " + f, file=sys.stderr)
    sys.exit(1)
print(f"USESYM_GATE_PASS (control={A} leak_site=bare use1=use2={C1} dangling=bare)")
PY
