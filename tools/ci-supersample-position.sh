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

# ── PER-ICON ARM ────────────────────────────────────────────────────────────
# WHY A SEPARATE FIXTURE AND ARM
#   The root fixture above proves the WHOLE-TREE composite (paintTreeSupersampled,
#   N>=2) is upright. It CANNOT see the per-icon composite
#   (paintSvgRootSupersampled): at N>=2 the root path pre-empts the per-icon hook
#   entirely, so a per-icon composite bug (a missing DrawTextureRect, or a missing
#   Y-flip) is invisible to it. The per-icon hook runs at N==1, and on backends
#   where the root offscreen exceeds the GPU bound and falls through with
#   supersample_ still set (the Mac at N=8). This arm drives FIVE asymmetric
#   filled up-arrows through their own <Svg> roots and asserts, at EVERY N:
#     * all five present, each with ink within 10% of the N=0 (in-place) baseline
#       — a missing per-icon composite paints NOTHING and reds this immediately;
#     * each arrow points UP (base-heavy: more ink in its bottom half than its
#       top half) — a Y-flipped per-icon composite turns them into down-arrows
#       and reds this.
#
# MUTANT this arm must catch (per the request): skip the per-icon composite — the
#   hook returns true without drawing — and every arrow vanishes at N=1/N=8, so
#   the ink-presence assertion fails. tools/mutation-verify-supersample.sh drives
#   it.
echo "== per-icon arm: 5 up-arrows, ink within 10% of N=0 and each points up =="
ICON_BUNDLE="${RNI_ICON_BUNDLE:-$ROOT/fixtures/eng-supersample-icons/prebuilt/eng-supersample-icons.bundle}"
case "$ICON_BUNDLE" in /*) ;; *) ICON_BUNDLE="$ROOT/$ICON_BUNDLE" ;; esac
[ -s "$ICON_BUNDLE" ] || fail "no per-icon bundle at $ICON_BUNDLE (run tools/build-supersample-icons-bundle.sh)"

render_icons() {  # $1 = N, $2 = out.ppm
  "$ENGINE" --bundle "$ICON_BUNDLE" --app-name EngSupersampleIcons \
    --headless --probe-banner off --supersample-rnsvg "$1" \
    --screenshot "$2" > "$WORK/icons-$1.log" 2>&1 \
    || { tail -20 "$WORK/icons-$1.log" >&2; fail "per-icon engine run (N=$1) failed"; }
  [ -s "$2" ] || fail "no per-icon screenshot for N=$1"
  grep -q "supersample_rnsvg=$1" "$WORK/icons-$1.log" \
    || fail "engine did not report supersample_rnsvg=$1 on the per-icon run"
}
# N=0 is the in-place baseline; N=1 is the per-icon offscreen path; N=2/4/8 test
# the fallthrough backends too. All measured against N=0.
for N in 0 1 2 4 8; do render_icons "$N" "$WORK/ic$N.ppm"; done

python3 - "$WORK/ic0.ppm" "$WORK/ic1.ppm" "$WORK/ic2.ppm" "$WORK/ic4.ppm" "$WORK/ic8.ppm" <<'PY'
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

# The five 48x48 icon wrappers in fixtures/eng-supersample-icons/index.js.
TOPS=[8,64,120,176,232]; BOX=48
NARROWS=len(TOPS)

def measure(path):
    w,h,px=read(path)
    out=[]
    for t in TOPS:
        y0,y1=t,min(t+BOX,h); mid=(y0+y1)//2
        ink=top=bot=0
        for y in range(y0,y1):
            row=y*w
            for x in range(w):
                o=(row+x)*3
                if px[o]!=255 or px[o+1]!=255 or px[o+2]!=255:
                    ink+=1
                    if y<mid: top+=1
                    else: bot+=1
        out.append(dict(ink=ink,top=top,bot=bot))
    return out

Ns=(0,1,2,4,8)
data={N:measure(p) for N,p in zip(Ns,sys.argv[1:6])}
base=data[0]

fails=[]
# Baseline sanity: the in-place render must have drawn all five arrows, up.
for i,a in enumerate(base):
    if a['ink']<200:
        fails.append(f"N=0 baseline arrow {i} painted almost nothing (ink={a['ink']}); "
                     "the fixture itself did not render — nothing else can be believed.")

for N in Ns:
    for i,a in enumerate(data[N]):
        b=base[i]
        # 1. PRESENCE: ink within 10% of the N=0 baseline. A missing per-icon
        #    composite paints 0 here (the bug: hook returns true, draws nothing).
        if b['ink']>0 and abs(a['ink']-b['ink']) > 0.10*b['ink']:
            fails.append(f"N={N} arrow {i} ink={a['ink']} vs N=0 {b['ink']} "
                         f"(>10% off) — the per-icon composite is missing or "
                         "wrong-sized (icon vanished or clipped).")
        elif a['ink']<200:
            fails.append(f"N={N} arrow {i} painted almost nothing (ink={a['ink']}) "
                         "— the per-icon composite drew nothing (missing DrawTextureRect).")
        # 2. ORIENTATION: an up-arrow is base-heavy (bottom half has more ink than
        #    the top half). A Y-flipped composite inverts this into a down-arrow.
        if a['ink']>=200 and not (a['bot'] > a['top']*1.3):
            fails.append(f"N={N} arrow {i} is not pointing UP "
                         f"(top_half={a['top']} bottom_half={a['bot']}) — the "
                         "per-icon composite is VERTICALLY MIRRORED (Y-flip missing).")

for N in Ns:
    inks=",".join(str(a['ink']) for a in data[N])
    print(f"   N={N}  arrow_ink=[{inks}]  "
          f"orient=[{','.join('UP' if a['bot']>a['top']*1.3 else 'X' for a in data[N])}]")

if fails:
    for f in fails: print("SUPERSAMPLE_POSITION_GATE_FAIL: "+f, file=sys.stderr)
    sys.exit(1)
print(f"SUPERSAMPLE_POSITION_GATE_PASS (per-icon: {NARROWS} arrows present within "
      "10% of N=0 and all pointing up at N=0,1,2,4,8)")
PY
