#!/usr/bin/env bash
# ENG item 2 gate — SUPERSAMPLE-RNSVG.
#
# WHAT THIS PROVES
#   A stroked, tessellated chevron rendered through Impeller has a BINARY edge:
#   pixels are either fully the stroke colour or fully background, with almost
#   nothing partial (Impeller emits no edge-coverage AA for tessellated paths).
#   The supersample path renders the icon N x into an offscreen and composites
#   it back with a LINEAR downsample, whose box filter synthesises the partial-
#   coverage edge pixels. So:
#     * N=0 (in-place)  -> few partial-luminance edge pixels, ~2 luma levels
#     * N=4 (offscreen) -> MANY partial pixels, many luma levels
#   The gate renders the SAME bundle both ways and asserts the jump.
#
# ⛔ THE SAME BUNDLE, TWO N VALUES. Rendering two different fixtures would prove
#   nothing — the two frames must differ ONLY by the supersample flag, so the
#   ONE variable is N. Both runs use --probe-banner off (mandatory for any pixel
#   gate; the banner paints its own shapes over the scene).
#
# ⚠️ LINUX DEFAULT IS N=0, so the baseline needs no flag, but we pass it
#   explicitly for both arms so the gate reads the same on darwin (default 4).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
RNI_ENGINE_PKG="${RNI_ENGINE_PKG:-$ROOT/packages-engine/engine-linux-x64}"

fail() { echo "SUPERSAMPLE_GATE_FAIL: $*" >&2; exit 1; }

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
APP="$WORK/SupersampleApp"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="supersampleapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="EngSupersample"; a.displayName="EngSupersample";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent \
  "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" || fail "npm install of the tarballs failed"
npm install --no-audit --no-fund --silent react-native-svg@15.15.5 \
  || fail "could not install react-native-svg"

cp "$ROOT/fixtures/eng-supersample/index.js" "$APP/index.js"
npx --no-install react-native init-impeller >/dev/null 2>&1 || fail "init-impeller failed"
ENGINE="$(node node_modules/@react-native-impeller/core/src/bin/engine-path.js)" \
  || fail "engine resolver failed"

echo "== 2. bundle --platform impeller =="
npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/supersample.bundle \
    >/dev/null 2>&1 || fail "bundle failed"
BUNDLE="$APP/impeller/build/supersample.bundle"
[ -s "$BUNDLE" ] || fail "no bundle produced"

echo "== 3. render N=0 (in-place) and N=4 (offscreen) =="
render() {  # $1 = N, $2 = out.ppm
  "$ENGINE" --bundle "$BUNDLE" --app-name EngSupersample \
    --headless --probe-banner off --supersample-rnsvg "$1" \
    --screenshot "$2" > "$WORK/run-$1.log" 2>&1 \
    || { tail -20 "$WORK/run-$1.log" >&2; fail "engine run (N=$1) failed"; }
  [ -s "$2" ] || fail "no screenshot for N=$1"
  grep -q "supersample_rnsvg=$1" "$WORK/run-$1.log" \
    || fail "engine did not report supersample_rnsvg=$1 (flag not honoured)"
}
render 0 "$WORK/n0.ppm"
render 4 "$WORK/n4.ppm"
echo "   $(grep -h 'scene_nodes\|supersample_rnsvg' "$WORK/run-0.log" | tr '\n' ' ')"

echo "== 3b. painted_nodes must be CACHE-INDEPENDENT (same at N=0 and N=4) =="
# ⛔ SAME BUNDLE, TWO N VALUES: the ONLY variable is the supersample flag, so the
#   painted-node count MUST be identical, AND must equal the node_frame line
#   count in EACH arm. The fixture has TWO IDENTICAL icons + one unique:
#     * icon #2 is a svgCache_ HIT (same content+pixel-size key as #1), so its
#       subtree is NEVER walked by the offscreen render;
#     * icon #3 is a MISS, so its subtree IS walked (counter-suppressed).
#   painted_ is attributed by countPaintedNodes at the supersample hook, the
#   same on hit and miss, so it can depend only on the scene graph.
# TWO MUTANTS this gate must catch:
#   A) drop `painted_ = savedPainted;` in renderSvgSubtreeToTexture — the
#      offscreen inner walk then leaks ++painted_ on every MISS, so N=4 > N=0.
#   B) drop `painted_ += countPaintedNodes(...) - 1;` at the supersample hook —
#      children are never counted (offscreen walk is suppressed), so N=4 < N=0
#      and N=4 < node_frame lines. This is the task-768 regression: the old
#      `--painted_;` under-counted on a cache HIT because the walk it cancelled
#      never ran (N=0=534 vs N=4=531).
pn() { grep -oE 'painted_nodes=[0-9]+' "$1" | head -1 | cut -d= -f2; }
nf() { grep -cE '^rn-impeller: node_frame=' "$1"; }
PN0="$(pn "$WORK/run-0.log")"; PN4="$(pn "$WORK/run-4.log")"
NF0="$(nf "$WORK/run-0.log")"; NF4="$(nf "$WORK/run-4.log")"
echo "   N=0  painted_nodes=$PN0  node_frame_lines=$NF0"
echo "   N=4  painted_nodes=$PN4  node_frame_lines=$NF4"
[ -n "$PN0" ] && [ -n "$PN4" ] || fail "painted_nodes not reported in a run log"
[ "$PN0" = "$PN4" ] || fail "painted_nodes differs by supersample flag: N=0=$PN0 N=4=$PN4 (cache-dependent count regression)"
[ "$PN0" = "$NF0" ] || fail "N=0 painted_nodes=$PN0 != node_frame lines=$NF0"
[ "$PN4" = "$NF4" ] || fail "N=4 painted_nodes=$PN4 != node_frame lines=$NF4 (supersample under/over-count)"

echo "== 4. count partial-luminance edge pixels in each =="
python3 - "$WORK/n0.ppm" "$WORK/n4.ppm" <<'PY'
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

# The chevron sits inside the <Svg x=20 y=20 w=240 h=240> box; restrict the
# measurement to that region so nothing outside the icon pollutes the count.
BX,BY,BW,BH = 20,20,240,240

def stats(path):
    w,h,px = read(path)
    partial = 0          # pixels strictly between background and full stroke
    levels = set()       # distinct grey luminances seen
    ink = 0              # any non-background pixel (proves the icon painted)
    for y in range(BY, min(BY+BH, h)):
        row = y*w
        for x in range(BX, min(BX+BW, w)):
            o=(row+x)*3
            r,g,b = px[o],px[o+1],px[o+2]
            if r==255 and g==255 and b==255:
                continue
            ink += 1
            # The stroke is neutral grey (r==g==b), so use luminance and bucket.
            lum = r
            levels.add(lum)
            # ⛔ PARTIAL EXCLUDES BOTH BACKGROUND AND THE SOLID STROKE CORE.
            # The stroke core is ~128 (the grey), background is 255. An AA edge
            # pixel is a blend BETWEEN the two: strictly lighter than the solid
            # core and strictly darker than background. Counting 128 as "partial"
            # (an earlier bug) made partial==ink for the binary in-place render,
            # so the jump could never be measured. 140..250 sits cleanly above
            # the ~128 core and below the 255 background.
            if 140 <= lum <= 250:
                partial += 1
    return dict(partial=partial, levels=len(levels), ink=ink, size=(w,h))

s0 = stats(sys.argv[1])
s4 = stats(sys.argv[2])
print(f"   N=0  ink={s0['ink']:6d}  partial={s0['partial']:6d}  luma_levels={s0['levels']}")
print(f"   N=4  ink={s4['ink']:6d}  partial={s4['partial']:6d}  luma_levels={s4['levels']}")

fails=[]
# Both must actually paint the icon — a blank frame trivially has 0 partials
# and would "pass" a naive jump check if the baseline were also blank.
if s0['ink'] < 200:
    fails.append(f"N=0 painted almost nothing (ink={s0['ink']}); the chevron "
                 "did not render, so the comparison is meaningless.")
if s4['ink'] < 200:
    fails.append(f"N=4 painted almost nothing (ink={s4['ink']}); the "
                 "supersample path produced a blank/near-blank icon.")

# The core assertion: supersample creates FAR more partial-coverage edge pixels.
# A 2x jump is the floor; in practice the offscreen produces many multiples.
if s4['partial'] < s0['partial'] * 2:
    fails.append(f"partial edge pixels did NOT jump: N=0={s0['partial']} "
                 f"N=4={s4['partial']} (need N=4 >= 2x N=0). The offscreen "
                 "downsample is not antialiasing the edge.")

# Luminance levels must multiply: a binary edge has ~2 (128 and 255); an
# antialiased one has a spread. Require the offscreen to show clearly more.
if s4['levels'] < s0['levels'] + 5:
    fails.append(f"distinct luma levels barely changed: N=0={s0['levels']} "
                 f"N=4={s4['levels']}. AA should introduce many intermediate "
                 "greys.")

if fails:
    for f in fails: print("SUPERSAMPLE_GATE_FAIL: " + f, file=sys.stderr)
    sys.exit(1)
print(f"SUPERSAMPLE_GATE_PASS (partial {s0['partial']}->{s4['partial']}, "
      f"levels {s0['levels']}->{s4['levels']})")
PY
