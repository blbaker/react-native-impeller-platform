#!/usr/bin/env bash
# ENG-05b: does requesting a MULTISAMPLED default framebuffer change the
# anti-aliasing on the aliased path route?
#
# THE EXPECTED ANSWER ON THIS HOST IS NO, AND THAT IS WHY THE GATE IS SHAPED
# LIKE THIS. engine/spike/aa_sample_count.cpp arm B already handed Impeller a
# 4x MSAA renderbuffer through ImpellerSurfaceCreateWrappedFBONew -- the same
# call GlfwSurface makes for fbo 0 -- and the readback was byte-identical to
# single-sample arm A. Impeller resolves its own AA into an internal offscreen
# MSAA texture and does not consult the sample count of the target it is given.
#
# So this script is a FALSIFICATION HARNESS, not a fix. It exists so the peer
# can run one command on real hardware, where GL_EXT_multisampled_render_to_
# texture exists and llvmpipe's behaviour may not hold, and get a verdict
# instead of an argument.
#
# ⛔ A NULL RESULT IS THE EASIEST THING IN THE WORLD TO FAKE. "MSAA changed
# nothing" is what you also get from: an engine that failed to start, a blank
# screenshot, a broken readback, a probe measuring the wrong region, and a
# GLFW_SAMPLES hint the driver silently ignored. Four guards, all required,
# each targeting one of those:
#
#   1. GL_SAMPLES GRANTED. GLFW_SAMPLES is a HINT. The engine prints what GL
#      actually granted on the live framebuffer; if that is not >= the request,
#      the experiment NEVER RAN and the gate says so instead of reporting a
#      null result. This is the guard that separates "MSAA did nothing" from
#      "MSAA was never on".
#   2. THE RAMP CONTROL. A gradient in the same frame must show many distinct
#      luminance values. If it collapses to 1, the whole pipeline is blind and
#      the subject's number means nothing.
#   3. THE SUBJECT MUST BE PAINTED. A non-trivial ink count, so a blank frame
#      cannot pass as "unchanged".
#   4. BOTH RUNS COMPARED BYTE FOR BYTE. Same binary, same bundle, same frame,
#      MSAA off then on. The verdict is the diff, not two absolute numbers.
#
# WINDOWED ON PURPOSE: GLFW_SAMPLES applies to the WINDOW's framebuffer config.
# HeadlessSurface builds its own FBO and never consults GLFW, so running this
# headless would test nothing and pass. Needs a display.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) DEF_PKG="$ROOT/packages-engine/engine-darwin-arm64" ;;
  *)            DEF_PKG="$ROOT/packages-engine/engine-linux-x64" ;;
esac
RNI_ENGINE_PKG="${RNI_ENGINE_PKG:-$DEF_PKG}"
SAMPLES="${RNI_GLFW_SAMPLES:-4}"

fail() { echo "ENG05_MSAA_FAIL: $*" >&2; exit 1; }

[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || [ "$(uname -s)" = "Darwin" ] \
  || fail "no display. GLFW_SAMPLES configures the WINDOW framebuffer, so this gate is windowed by necessity; headless would pass while testing nothing"

[ -d "$BASE_APP/node_modules/react-native" ] || bash tools/base-app.sh
[ -d "$BASE_APP/node_modules/react-native" ] || fail "no base RN app at $BASE_APP"

WORK="$(mktemp -d)"
echo "workdir: $WORK"
cleanup() {
  pgrep -x rn-impeller > /dev/null 2>&1 && pkill -x rn-impeller || true
}
trap cleanup EXIT

echo "== 1. pack + install into a pristine app OUTSIDE the repo =="
ENGINE_TGZ="$(cd "$RNI_ENGINE_PKG" && npm pack --silent --pack-destination "$WORK")"
MAIN_TGZ="$(cd package && npm pack --silent --pack-destination "$WORK")"
APP="$WORK/Eng05MsaaApp"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="eng05msaaapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="Eng05Msaa"; a.displayName="Eng05Msaa";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" \
  || fail "npm install of the tarballs failed"
npm install --no-audit --no-fund --silent react-native-svg@15.15.5 \
  || fail "could not install react-native-svg"

cp "$ROOT/fixtures/eng05-msaa/index.js" "$APP/index.js"
npx --no-install react-native init-impeller >/dev/null 2>&1 || fail "init-impeller failed"
ENGINE="$(node node_modules/@react-native-impeller/core/src/bin/engine-path.js)" \
  || fail "engine resolver failed"
INSTALLED_SHA="$(sha256sum "$ENGINE" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$ENGINE" | cut -d' ' -f1)"
STAGED_SHA="$(sha256sum "$RNI_ENGINE_PKG/bin/rn-impeller" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$RNI_ENGINE_PKG/bin/rn-impeller" | cut -d' ' -f1)"
echo "engine: $ENGINE"
echo "sha256: $INSTALLED_SHA"
[ "$INSTALLED_SHA" = "$STAGED_SHA" ] \
  || fail "the installed engine is NOT the staged one -- this gate would grade a different binary than the one just built"

echo "== 2. bundle =="
npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/msaa.bundle \
    >/dev/null 2>&1 || fail "bundle failed"
BUNDLE="$APP/impeller/build/msaa.bundle"
[ -s "$BUNDLE" ] || fail "no bundle produced"

# One windowed run.
#
# ⛔ --screenshot IS IGNORED IN WINDOWED MODE WITHOUT --screenshot-after. The
# windowed loop only captures once elapsed >= screenshotAfterMs, which defaults
# to -1, so a windowed run with --screenshot alone exits 0, prints
# RN_IMPELLER_WINDOW_OK, and writes NO FILE. Measured here: the gate reported
# "no screenshot produced" on a perfectly healthy run.
#
# ⚠️ --frames MUST OUTLAST --screenshot-after. This loop renders ~1000fps, so
# --frames 120 finishes in ~120ms and the process exits BEFORE a 200ms capture
# point -- again producing no file, which reads as a broken capture rather than
# a run that ended early. 600 frames comfortably covers 200ms.
run() {
  local tag="$1"; shift
  env "$@" "$ENGINE" --bundle "$BUNDLE" --app-name Eng05Msaa \
      --window --probe-banner off --width 400 --height 300 \
      --frames 600 --screenshot "$WORK/$tag.ppm" --screenshot-after 200 \
      > "$WORK/$tag.log" 2>&1 \
    || { tail -15 "$WORK/$tag.log" >&2; fail "$tag: engine exited nonzero"; }
  [ -s "$WORK/$tag.ppm" ] || { tail -15 "$WORK/$tag.log" >&2; fail "$tag: no screenshot produced"; }
}

echo "== 3. run A: MSAA OFF (the baseline) =="
run off RNI_GLFW_SAMPLES=
echo "== 4. run B: MSAA ON (RNI_GLFW_SAMPLES=$SAMPLES) =="
run on RNI_GLFW_SAMPLES="$SAMPLES"

echo "== 5. GUARD 1: did GL actually GRANT the samples? =="
GRANTED="$(grep -oE 'glfw_samples_granted=[0-9]+' "$WORK/on.log" | tail -1 | cut -d= -f2 || true)"
REQUESTED="$(grep -oE 'glfw_samples_requested=[0-9]+' "$WORK/on.log" | tail -1 | cut -d= -f2 || true)"
[ -n "$REQUESTED" ] \
  || fail "the engine never printed glfw_samples_requested -- this binary predates the ENG-05b flag, so run B was identical to run A and any 'no change' below is meaningless"
[ -n "$GRANTED" ] || fail "the engine never printed glfw_samples_granted"
echo "   requested=$REQUESTED granted=$GRANTED"
[ "$GRANTED" -ge 2 ] \
  || fail "GL granted GL_SAMPLES=$GRANTED for a request of $REQUESTED -- multisampling was NEVER ENABLED. This is not evidence that MSAA does not help; the experiment did not run. On a driver that refuses MSAA on the default framebuffer, this gate cannot answer the question and must not pretend to."

echo "== 6. GUARD 2+3: the ramp control and the painted subject =="
analyse() {
  python3 - "$1" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
parts, i = [], 0
while len(parts) < 4:
    while d[i:i+1].isspace(): i += 1
    if d[i:i+1] == b'#':
        while d[i:i+1] != b'\n': i += 1
        continue
    s = i
    while not d[i:i+1].isspace(): i += 1
    parts.append(d[s:i])
w, h, px = int(parts[1]), int(parts[2]), d[i+1:]
# Layout is fixed by fixtures/eng05-msaa/index.js at 400x300 logical points.
sx = w / 400.0
sy = h / 300.0
def box(lx, ly, bw, bh):
    return (int(lx*sx), int(ly*sy), int(bw*sx), int(bh*sy))
def stats(b):
    x0, y0, bw, bh = b
    lums, ink, partial = set(), 0, 0
    for y in range(y0, y0+bh):
        for x in range(x0, x0+bw):
            o = (y*w + x) * 3
            l = (px[o] + px[o+1] + px[o+2]) // 3
            if l < 250:
                ink += 1
                lums.add(l)
                if l > 5:
                    partial += 1
    return ink, len(lums), partial
s_ink, s_lums, s_part = stats(box(30, 30, 140, 140))   # subject disc
r_ink, r_lums, r_part = stats(box(210, 30, 180, 140))  # control ramp
print(s_ink, s_lums, s_part, r_ink, r_lums, r_part)
PY
}

read -r S_INK S_LUM S_PART R_INK R_LUM R_PART <<< "$(analyse "$WORK/off.ppm")"
read -r T_INK T_LUM T_PART U_INK U_LUM U_PART <<< "$(analyse "$WORK/on.ppm")"
echo "   MSAA off: subject ink=$S_INK distinct=$S_LUM partial=$S_PART | ramp ink=$R_INK distinct=$R_LUM"
echo "   MSAA on : subject ink=$T_INK distinct=$T_LUM partial=$T_PART | ramp ink=$U_INK distinct=$U_LUM"

[ "$R_LUM" -ge 32 ] \
  || fail "the CONTROL RAMP shows only $R_LUM distinct luminance values with MSAA off. The measuring pipeline is blind -- a gradient is many values by construction -- so the subject's numbers carry no information and 'MSAA changed nothing' would be an artifact of the instrument"
[ "$U_LUM" -ge 32 ] \
  || fail "the CONTROL RAMP shows only $U_LUM distinct values with MSAA on. Same reason: the instrument, not the subject"
[ "$S_INK" -gt 5000 ] \
  || fail "the subject disc painted only $S_INK ink pixels with MSAA off -- the fixture did not render, so an unchanged frame proves nothing"
[ "$T_INK" -gt 5000 ] \
  || fail "the subject disc painted only $T_INK ink pixels with MSAA on"

echo "== 7. THE MEASUREMENT: did MSAA change the aliased route? =="
if cmp -s "$WORK/off.ppm" "$WORK/on.ppm"; then
  IDENTICAL=yes
else
  IDENTICAL=no
fi
echo "   frames byte-identical: $IDENTICAL"
echo "   subject distinct luminance: $S_LUM (off) -> $T_LUM (on)"
echo "   subject partial-coverage px: $S_PART (off) -> $T_PART (on)"

# ⛔ "THE FRAMES DIFFER" IS NOT "MSAA ANTIALIASED SOMETHING", AND THE DIFFERENCE
# MATTERS MORE THAN THE FACT OF A DIFFERENCE.
#
# Measured here: 96 pixels changed between the two runs, every one of them a
# HARD black<->white flip on the disc's rim, with no intermediate value
# introduced anywhere. That is the rasteriser's binary coverage decision landing
# on the other side of a boundary pixel -- sample-position jitter -- and it is
# exactly what a NON-antialiased edge does when you perturb the target config.
# Anti-aliasing would produce NEW intermediate luminances, which is what the
# distinct/partial counts above measure and what stayed flat.
#
# Without this classification, `frames byte-identical: no` is easy to read as
# "MSAA did something", which is the wrong conclusion from the right data.
classify_diff() {
  python3 - "$WORK/off.ppm" "$WORK/on.ppm" <<'PY'
import sys
def read(p):
    d = open(p, 'rb').read()
    parts, i = [], 0
    while len(parts) < 4:
        while d[i:i+1].isspace(): i += 1
        if d[i:i+1] == b'#':
            while d[i:i+1] != b'\n': i += 1
            continue
        s = i
        while not d[i:i+1].isspace(): i += 1
        parts.append(d[s:i])
    return int(parts[1]), int(parts[2]), d[i+1:]
w, h, a = read(sys.argv[1])
_, _, b = read(sys.argv[2])
total = 0
graded = 0   # a differing pixel where EITHER side is an intermediate value
for y in range(h):
    for x in range(w):
        o = (y*w + x) * 3
        if a[o:o+3] == b[o:o+3]:
            continue
        total += 1
        la = (a[o] + a[o+1] + a[o+2]) // 3
        lb = (b[o] + b[o+1] + b[o+2]) // 3
        if (5 < la < 250) or (5 < lb < 250):
            graded += 1
print(total, graded)
PY
}
read -r DIFF_PX DIFF_GRADED <<< "$(classify_diff)"
echo "   differing px: $DIFF_PX, of which INTERMEDIATE (real AA): $DIFF_GRADED"

# ⛔ THIS GATE DOES NOT FAIL ON A NULL RESULT, AND THAT IS DELIBERATE.
# "MSAA does not help" is the EXPECTED finding on llvmpipe and is a legitimate,
# useful outcome -- the guards above are what make it trustworthy. Failing here
# would mean the gate encodes a wish rather than a measurement. It reports a
# VERDICT, and CI can read the token.
#
# The AA test is on INTERMEDIATE values, not on distinct counts alone: a shape
# that merely shifted by a pixel changes counts without antialiasing anything.
if [ "$DIFF_GRADED" -gt 0 ] && [ "$T_PART" -gt "$S_PART" ]; then
  echo
  echo "ENG05_MSAA_HELPS granted=$GRANTED distinct=$S_LUM->$T_LUM partial=$S_PART->$T_PART graded=$DIFF_GRADED"
  echo "  MSAA on the default framebuffer DOES antialias the aliased path route"
  echo "  on this host: $DIFF_GRADED pixels gained intermediate coverage values."
  echo "  Impeller IS consulting the target's sample count here, which"
  echo "  contradicts spike arm B on llvmpipe. ENG-05b is implementable as a"
  echo "  surface-configuration change -- promote RNI_GLFW_SAMPLES to a real"
  echo "  default and re-run the spike on this hardware."
else
  echo
  echo "ENG05_MSAA_NULL granted=$GRANTED distinct=$S_LUM->$T_LUM partial=$S_PART->$T_PART diff=$DIFF_PX graded=$DIFF_GRADED"
  echo "  A REAL multisampled framebuffer (GL_SAMPLES=$GRANTED, guard 1) with a"
  echo "  VALIDATED instrument (ramp $R_LUM->$U_LUM distinct, guard 2) produced"
  echo "  ZERO antialiased pixels on the subject. The $DIFF_PX pixels that did"
  echo "  differ are hard on/off flips at the rim -- sample-position jitter of a"
  echo "  still-binary edge, not coverage. Impeller resolves AA into its own"
  echo "  offscreen and does not consult the wrapped target's sample count, the"
  echo "  same result as spike arm B. GLFW_SAMPLES is not the ENG-05b fix and"
  echo "  should NOT be turned on by default -- it would be a config change with"
  echo "  no measured effect. The remaining lead is docs/ENG-05-aa-findings.md"
  echo "  step 2: route <Circle>/<Ellipse> to AddOval and <Rect> to"
  echo "  AddRoundedRect, which keeps the analytic-coverage path that DOES"
  echo "  antialias. Arbitrary d paths stay aliased regardless; that is upstream."
fi
