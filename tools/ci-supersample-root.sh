#!/usr/bin/env bash
# ENG item 2b gate — ROOT SUPERSAMPLE (View border/corner AA).
#
# WHAT THIS PROVES
#   A View with a rounded border has a curved corner arc. Impeller emits NO
#   edge-coverage AA for it (the arc is a stroked/filled rounded rect, the same
#   class of tessellated edge b9edbee documents for stroked SVG paths), so at
#   N<=1 the arc is a BINARY step: a pixel is fully the shape colour or fully
#   background, ~2 luminance levels. The ROOT supersample path renders the WHOLE
#   tree into one N x offscreen and composites it back with a linear downsample,
#   whose box filter synthesises partial-coverage pixels along the arc. So:
#     * N=1 (in-place, the mutant control) -> ~2 luma levels, flat step
#     * N=4 (root offscreen)               -> many luma levels, graded arc
#   The gate renders the SAME bundle both ways and asserts the jump.
#
# ⛔ MATCHED PAIR. N=1 is not "off" — it is an offscreen-less in-place render, so
#   it MUST stay a flat step. If N=1 already antialiased, the whole premise
#   (Impeller does not AA the corner) would be false and the gate vacuous. So the
#   gate asserts BOTH: N=1 low luma levels AND N=4 high. Neither half alone means
#   anything — N=4 high with a hardcoded-round anything would pass a one-sided
#   check.
#
# ⛔ N=1 NOT N=0 for the baseline. N=0 is "disabled". N=1 is the design's mutant
#   control (offscreen round-trip, no supersample) — but at the ROOT it never
#   even builds an offscreen (paintTreeSupersampled requires N>=2), so N=1 IS the
#   in-place walk. Using N=1 keeps the baseline aligned with the code path the
#   mutation script perturbs.
#
# NO-NPM MODE (for the Mac / any box without a JS toolchain):
#   By default this renders a COMMITTED prebuilt bundle
#   (fixtures/eng-supersample-root/prebuilt/eng-supersample-root.bundle) with the
#   staged engine binary — no npm, no react-native bundle, no node. Override the
#   binary with RNI_BIN and the bundle with RNI_TEST_BUNDLE. On a box WITH node,
#   set BUILD_BUNDLE=1 to rebuild the bundle from the fixture source first.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { echo "SUPERSAMPLE_ROOT_GATE_FAIL: $*" >&2; exit 1; }

# Engine binary: staged linux package by default; RNI_BIN overrides (the Mac
# passes its darwin-arm64 staged binary or a hand-built one).
ENGINE="${RNI_BIN:-$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller}"
[ -x "$ENGINE" ] || fail "no engine binary at $ENGINE (set RNI_BIN)"

# Bundle: committed prebuilt by default (no toolchain needed). RNI_TEST_BUNDLE
# overrides. BUILD_BUNDLE=1 rebuilds from source on a box that has node.
BUNDLE="${RNI_TEST_BUNDLE:-$ROOT/fixtures/eng-supersample-root/prebuilt/eng-supersample-root.bundle}"
if [ "${BUILD_BUNDLE:-0}" = "1" ] && [ -z "${RNI_TEST_BUNDLE:-}" ]; then
  echo "== BUILD_BUNDLE=1: rebuilding the prebuilt bundle from fixture source =="
  bash "$ROOT/tools/build-supersample-root-bundle.sh" \
    || fail "could not rebuild the prebuilt bundle"
fi
# ⛔ --bundle must be ABSOLUTE (no CWD fallback in the engine).
case "$BUNDLE" in /*) ;; *) BUNDLE="$ROOT/$BUNDLE" ;; esac
[ -s "$BUNDLE" ] || fail "no bundle at $BUNDLE (set RNI_TEST_BUNDLE, or BUILD_BUNDLE=1 on a box with node)"

WORK="$(mktemp -d)"
KEEP="${KEEP_WORKDIR:-0}"
cleanup() {
  rni_kill_own
  [ "$KEEP" = "1" ] && echo "workdir kept: $WORK" || rm -rf "$WORK"
}
trap cleanup EXIT

echo "== render N=1 (in-place, flat) and N=4 (root offscreen) =="
render() {  # $1 = N, $2 = out.ppm
  "$ENGINE" --bundle "$BUNDLE" --app-name EngSupersampleRoot \
    --headless --probe-banner off --supersample-rnsvg "$1" \
    --screenshot "$2" > "$WORK/run-$1.log" 2>&1 \
    || { tail -20 "$WORK/run-$1.log" >&2; fail "engine run (N=$1) failed"; }
  [ -s "$2" ] || fail "no screenshot for N=$1"
  grep -q "supersample_rnsvg=$1" "$WORK/run-$1.log" \
    || fail "engine did not report supersample_rnsvg=$1 (flag not honoured)"
}
render 1 "$WORK/n1.ppm"
render 4 "$WORK/n4.ppm"
echo "   $(grep -h 'scene_nodes\|supersample_rnsvg' "$WORK/run-1.log" | tr '\n' ' ')"

echo "== count corner-arc luminance levels + partial-coverage pixels =="
python3 - "$WORK/n1.ppm" "$WORK/n4.ppm" <<'PY'
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

# The View is at (40,40) size 200x200, borderRadius 60. The top-left corner arc
# is centred at (100,100) radius ~60. Restrict measurement to a 60x60 box over
# that corner so straight edges (which even a binary renderer paints axis-aligned
# and crisp, no partials) never pollute the count. Fill=#303030 (48),
# border=#000000 (0), background=#ffffff (255).
BX,BY,BW,BH = 40,40,60,60
FILL = 48

def stats(path):
    w,h,px = read(path)
    partial = 0     # pixels strictly between the shape (<=48) and background (255)
    levels = set()  # distinct luminances in the corner box
    ink = 0         # any non-background pixel (proves the View painted)
    for y in range(BY, min(BY+BH, h)):
        row = y*w
        for x in range(BX, min(BX+BW, w)):
            o=(row+x)*3
            r = px[o]  # neutral grey shape/border on white -> r==g==b
            if r == 255:
                continue
            ink += 1
            levels.add(r)
            # ⛔ PARTIAL EXCLUDES BOTH BACKGROUND (255) AND THE SOLID SHAPE.
            # A binary corner has only fill(<=48) and background(255) with
            # nothing between; an antialiased arc blends across 49..254. The
            # solid fill/border (<=48) is NOT partial; counting it (an easy bug)
            # would make partial==ink for the flat N=1 render and kill the jump.
            if 49 <= r <= 254:
                partial += 1
    return dict(partial=partial, levels=len(levels), ink=ink, size=(w,h))

s1 = stats(sys.argv[1])
s4 = stats(sys.argv[2])
print(f"   N=1  ink={s1['ink']:6d}  partial={s1['partial']:6d}  luma_levels={s1['levels']}")
print(f"   N=4  ink={s4['ink']:6d}  partial={s4['partial']:6d}  luma_levels={s4['levels']}")

fails=[]
# Both must actually paint the corner. A blank frame trivially has 0 partials
# and few levels and would "pass" a naive jump if the baseline were also blank.
if s1['ink'] < 200:
    fails.append(f"N=1 painted almost nothing in the corner box (ink={s1['ink']}); "
                 "the View did not render, so the comparison is meaningless.")
if s4['ink'] < 200:
    fails.append(f"N=4 painted almost nothing in the corner box (ink={s4['ink']}); "
                 "the root supersample produced a blank/near-blank frame.")

# ⛔ MATCHED-PAIR NEGATIVE: N=1 must STAY a flat step. If Impeller (or a future
# change) started antialiasing the corner itself, N=1 would show many levels and
# the whole premise would be false — the gate would then be proving nothing.
# Assert the baseline is genuinely binary (a couple of levels, near-zero
# partials). This is the half that fails if someone hardcodes AA on.
if s1['levels'] > 4:
    fails.append(f"N=1 corner already has {s1['levels']} luma levels — expected a "
                 "binary step (~2). Either the engine now antialiases the corner "
                 "itself (premise broken, gate vacuous) or N=1 wrongly took the "
                 "offscreen path.")
if s1['partial'] > 40:
    fails.append(f"N=1 has {s1['partial']} partial-coverage corner pixels — "
                 "expected a near-binary edge. The baseline is not flat.")

# ⛔ MATCHED-PAIR POSITIVE: N=4 must add many intermediate greys AND many partial
# pixels along the arc. Both, so a mutant that runs an offscreen but does not
# actually supersample (native-res round-trip) cannot pass.
if s4['levels'] < s1['levels'] + 10:
    fails.append(f"distinct corner luma levels barely changed: N=1={s1['levels']} "
                 f"N=4={s4['levels']}. Root supersample should introduce many "
                 "intermediate greys along the arc.")
if s4['partial'] < 60:
    fails.append(f"N=4 has only {s4['partial']} partial-coverage corner pixels — "
                 "the offscreen downsample is not antialiasing the arc.")

if fails:
    for f in fails: print("SUPERSAMPLE_ROOT_GATE_FAIL: " + f, file=sys.stderr)
    sys.exit(1)
print(f"SUPERSAMPLE_ROOT_GATE_PASS (corner luma {s1['levels']}->{s4['levels']}, "
      f"partial {s1['partial']}->{s4['partial']})")
PY
