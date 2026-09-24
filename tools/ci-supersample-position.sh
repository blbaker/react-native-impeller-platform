#!/usr/bin/env bash
# POSITION gate for the root supersample composite — orientation, not AA.
#
# WHAT THIS PROVES
#   paintTreeSupersampled renders the whole tree into an offscreen FBO texture
#   and composites it back with ImpellerDisplayListBuilderDrawTextureRect. A GL
#   FBO-backed texture is BOTTOM-LEFT origin; whether the composite comes back
#   upright or vertically mirrored depends on the backend's wrapped-FBO handling.
#   The fixture View is 200x200 at top:40 on a 400x300 surface, so it has an
#   ASYMMETRIC vertical margin: 40px above, 60px below. An upright composite puts
#   the ink bbox at rows ~40..240; a Y-flipped composite puts it at ~60..260.
#   The top margin alone tells the two apart, at every N.
#
#   N=1 is the in-place walk (no offscreen, cannot flip) — the ground-truth
#   orientation. N=2/4/8 all go through the offscreen composite. Every N must
#   agree with N=1's top margin, or the composite is mirrored at that N.
#
# ⛔ This is a BACKEND-SPECIFIC observable. FBO texture origin differs across GL
#   implementations and Metal/ANGLE. A PASS here (llvmpipe) does not certify the
#   Mac's ANGLE-Metal backend, and vice versa. Run it on the box under question.
#
# NO-NPM MODE: renders the committed prebuilt root-supersample bundle with the
#   staged engine. RNI_BIN / RNI_TEST_BUNDLE override.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
fail() { echo "SUPERSAMPLE_POSITION_GATE_FAIL: $*" >&2; exit 1; }

ENGINE="${RNI_BIN:-$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller}"
[ -x "$ENGINE" ] || fail "no engine binary at $ENGINE (set RNI_BIN)"
BUNDLE="${RNI_TEST_BUNDLE:-$ROOT/fixtures/eng-supersample-root/prebuilt/eng-supersample-root.bundle}"
case "$BUNDLE" in /*) ;; *) BUNDLE="$ROOT/$BUNDLE" ;; esac
[ -s "$BUNDLE" ] || fail "no bundle at $BUNDLE"

WORK="$(mktemp -d)"
KEEP="${KEEP_WORKDIR:-0}"
cleanup() { rni_kill_own; [ "$KEEP" = "1" ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

render() {  # $1 = N, $2 = out.ppm
  "$ENGINE" --bundle "$BUNDLE" --app-name EngSupersampleRoot \
    --headless --probe-banner off --supersample-rnsvg "$1" \
    --screenshot "$2" > "$WORK/run-$1.log" 2>&1 \
    || { tail -20 "$WORK/run-$1.log" >&2; fail "engine run (N=$1) failed"; }
  [ -s "$2" ] || fail "no screenshot for N=$1"
  grep -q "supersample_rnsvg=$1" "$WORK/run-$1.log" \
    || fail "engine did not report supersample_rnsvg=$1 (flag not honoured)"
}

echo "== render N=1,2,4,8 and measure ink-bbox top margin =="
for N in 1 2 4 8; do render "$N" "$WORK/n$N.ppm"; done

python3 - "$WORK/n1.ppm" "$WORK/n2.ppm" "$WORK/n4.ppm" "$WORK/n8.ppm" <<'PY'
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

def ink_bbox(path):
    w,h,px=read(path)
    top=bot=None; ink=0
    for y in range(h):
        row=y*w; rowink=False
        for x in range(w):
            o=(row+x)*3
            if px[o]!=255 or px[o+1]!=255 or px[o+2]!=255:
                ink+=1; rowink=True
        if rowink:
            if top is None: top=y
            bot=y
    return dict(w=w,h=h,top=top,bot=bot,ink=ink)

res={}
for N,p in zip((1,2,4,8), sys.argv[1:5]):
    r=ink_bbox(p); res[N]=r
    print(f"   N={N}  surface={r['w']}x{r['h']}  ink={r['ink']:6d}  "
          f"top_margin={r['top']}  bottom_margin={r['h']-1-r['bot']}")

fails=[]
base=res[1]
if base['ink']<1000 or base['top'] is None:
    fails.append("N=1 painted almost nothing; the fixture did not render.")
# Ground truth: N=1 in-place walk. Fixture is top:40 -> expect top_margin ~40.
if base['top'] is not None and base['top']>55:
    fails.append(f"N=1 top margin {base['top']} — expected ~40 for an upright "
                 "in-place render; the ground truth itself looks displaced.")
# Every offscreen N must match N=1's top margin within a couple px.
for N in (2,4,8):
    r=res[N]
    if r['ink']<1000 or r['top'] is None:
        fails.append(f"N={N} painted almost nothing (offscreen produced blank).")
        continue
    if abs(r['top']-base['top'])>4:
        fails.append(f"N={N} top margin {r['top']} vs N=1 {base['top']} "
                     f"(delta {r['top']-base['top']}) — the offscreen composite is "
                     "VERTICALLY MIRRORED at this N (srcRect Y-flip needed on this backend).")

if fails:
    for f in fails: print("SUPERSAMPLE_POSITION_GATE_FAIL: "+f, file=sys.stderr)
    sys.exit(1)
print(f"SUPERSAMPLE_POSITION_GATE_PASS (top margins "
      f"N1={res[1]['top']} N2={res[2]['top']} N4={res[4]['top']} N8={res[8]['top']}, upright)")
PY
