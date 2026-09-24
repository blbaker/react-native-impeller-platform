#!/usr/bin/env bash
# ENG-05 probe — SvgView viewBox scaling + path-edge anti-aliasing.
#
# Not a permanent gate yet; this is the ACCEPTANCE PROBE the peer's ledger row
# describes, run against the current binary so the accept/dispute is backed by
# pixels instead of by reading the paint code.
#
# Two independent questions on one frame:
#   A. Does <Svg width=16 viewBox="0 0 24 24"> scale its children by 16/24?
#   B. Do path strokes produce intermediate edge coverage (anti-aliasing)?
#
# ⛔ --probe-banner off is mandatory (see ci-svg.sh: the banner paints its own
# shapes over the scene and makes every fixture byte-identical).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
RNI_ENGINE_PKG="${RNI_ENGINE_PKG:-$ROOT/packages-engine/engine-linux-x64}"

fail() { echo "ENG05_PROBE_FAIL: $*" >&2; exit 1; }

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
APP="$WORK/Eng05App"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="eng05app";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="Eng05"; a.displayName="Eng05";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent \
  "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" || fail "npm install of the tarballs failed"
npm install --no-audit --no-fund --silent react-native-svg@15.15.5 \
  || fail "could not install react-native-svg"

echo "== 2. swap in the ENG-05 fixture =="
cp "$ROOT/fixtures/eng05-viewbox/index.js" "$APP/index.js"

npx --no-install react-native init-impeller >/dev/null 2>&1 || fail "init-impeller failed"
ENGINE="$(node node_modules/@react-native-impeller/core/src/bin/engine-path.js)" \
  || fail "engine resolver failed"

echo "== 3. bundle --platform impeller =="
npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/index.impeller.bundle \
    >/dev/null 2>&1 || fail "bundle failed"
BUNDLE="$APP/impeller/build/index.impeller.bundle"
[ -s "$BUNDLE" ] || fail "no bundle produced"

echo "== 4. render headless at 1x and 2x =="
for S in 1 2; do
  "$ENGINE" --bundle "$BUNDLE" --app-name Eng05 --headless --probe-banner off \
    --width $((400*S)) --height $((300*S)) --scale "$S" \
    --screenshot "$WORK/eng05-${S}x.ppm" > "$WORK/run-${S}x.log" 2>&1 \
    || { tail -20 "$WORK/run-${S}x.log" >&2; fail "engine run failed at ${S}x"; }
  [ -s "$WORK/eng05-${S}x.ppm" ] || fail "no screenshot at ${S}x"
  echo "   ${S}x: $(grep -E 'scene_nodes|painted_nodes' "$WORK/run-${S}x.log" | tr '\n' ' ')"
done

echo "== 5. measure ink extent + edge coverage =="
python3 - "$WORK/eng05-1x.ppm" "$WORK/eng05-2x.ppm" <<'PY'
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

def analyse(path, scale):
    w,h,px = read(path)
    def at(x,y):
        o=(y*w+x)*3
        return tuple(px[o:o+3])

    # Arms are laid out at layout points; multiply by scale for device pixels.
    arms = {"A_vb24": (40,40,16,16), "B_vb48": (200,40,16,16),
            "CTRL_vb48": (40,150,48,48), "C_nonsq": (200,150,32,16)}
    out={}
    for name,(lx,ly,bw,bh) in arms.items():
        x0,y0 = int(lx*scale), int(ly*scale)
        # ⛔ --scale scales CONTENT into the SAME --width/--height canvas; it
        # does not enlarge the framebuffer. At 2x an arm pinned at 200pt starts
        # at device pixel 400 on a 400px image and finds zero ink. That is my
        # probe running off the canvas, NOT the engine failing to paint, and
        # calling it "PAINTED NOTHING" manufactures a defect. Distinguish them.
        if x0 >= w or y0 >= h:
            out[name]={"offcanvas":True,"origin":(x0,y0),"image":(w,h)}
            continue
        # Scan a region 3x the declared box so OVERFLOW is visible, not clipped
        # out of the measurement by the measurement itself.
        span = int(max(bw,bh)*scale*3)
        ink=[]
        for dy in range(span):
            for dx in range(span):
                x,y = x0+dx, y0+dy
                if x>=w or y>=h: continue
                r,g,b = at(x,y)
                if (r,g,b) != (255,255,255):
                    ink.append((dx,dy,r))
        if not ink:
            out[name]={"painted":False}
            continue
        minx=min(p[0] for p in ink); miny=min(p[1] for p in ink)
        maxx=max(p[0] for p in ink); maxy=max(p[1] for p in ink)
        # Coverage classes: pure ink (near 0), pure bg excluded already,
        # intermediate = anti-aliased edge.
        pure = sum(1 for p in ink if p[2] <= 8)
        partial = sum(1 for p in ink if 8 < p[2] < 247)
        # ⛔ INK WIDTH AND HEIGHT SEPARATELY, plus the LEFT MARGIN. Reporting
        # only a max extent cannot tell a centred 16x16 drawing inside a 32x16
        # box from a 32x16 stretch that happens to end at the same bottom-right
        # corner. The margin is the discriminating number for arm C.
        out[name]={"painted":True,"px":len(ink),
                   "ink_pt":(round((maxx-minx+1)/scale,2),
                             round((maxy-miny+1)/scale,2)),
                   "margin_pt":(round(minx/scale,2), round(miny/scale,2)),
                   "extent_pt":(round((maxx+1)/scale,2), round((maxy+1)/scale,2)),
                   "declared_pt":(bw,bh),
                   "pure":pure,"partial":partial,
                   "partial_pct":round(100.0*partial/len(ink),1)}
    return out

for path,scale in ((sys.argv[1],1),(sys.argv[2],2)):
    print(f"\n--- {scale}x ---")
    res = analyse(path, scale)
    for name,r in res.items():
        if r.get("offcanvas"):
            print(f"   {name}: OUT OF FRAME at {scale}x "
                  f"(origin {r['origin']} vs image {r['image']}) -- not a paint result")
            continue
        if not r["painted"]:
            print(f"   {name}: PAINTED NOTHING")
            continue
        print(f"   {name}: declared {r['declared_pt'][0]}x{r['declared_pt'][1]}pt "
              f"-> ink {r['ink_pt'][0]}x{r['ink_pt'][1]}pt "
              f"at margin +{r['margin_pt'][0]},{r['margin_pt'][1]}, "
              f"{r['px']}px ({r['pure']} pure / {r['partial']} partial = "
              f"{r['partial_pct']}% AA coverage)")
PY
