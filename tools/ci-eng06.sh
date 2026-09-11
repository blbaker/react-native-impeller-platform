#!/usr/bin/env bash
# ENG-06 ACCEPTANCE GATE: NativeAnimatedModule, the peer's three arms.
#
# The macOS peer (internal request) specified acceptance as:
#   (a) --list-modules lists NativeAnimatedModule with startAnimatingNode and
#       stopAnimation among its methods
#   (b) the fixture's Animated.View pixel count DIFFERS between the first frame
#       and a later one in the SAME run
#   (c) --frames steps the animation clock, i.e. the delegate's time source is
#       the FRAME COUNTER and not wall time, so headless runs are deterministic
#
# All three are asserted here, plus two arms the peer could not have known to
# ask for:
#
#   ⚠️ THE PIXEL DIFF ALONE CANNOT GATE THIS. Delete the pump and rebuild and
#   the same pixels still move -- RN silently falls back to its JS driver and
#   both drivers animate a fixture identically. Only `nativeanimated_ticks`
#   goes 60 -> 0 under that mutation. So arm (b) is paired with a TICKS arm; a
#   gate asserting pixels only stays green with the entire ENG-06 commit
#   reverted, which is the definition of a gate that cannot fail.
#
#   ⚠️ A CONTROL THAT MUST NOT MOVE. Box A is a plain View at opacity 1. If it
#   also changes between the two frames then something global is repainting
#   (surface clear, resize, banner) and box B's movement is not evidence of
#   an animation at all.
#
# DETERMINISM IS MEASURED 5x, NOT ASSERTED ONCE. "Deterministic" is exactly the
# kind of claim that holds on the run you watch; a single pair of equal numbers
# is also what a wall-clock driver prints when two runs happen to take the same
# time. Five runs of the same --frames N must give the SAME tick count and the
# SAME late-frame pixel count, and a run with a DIFFERENT --frames N must give a
# different tick count -- otherwise the flag is wired to nothing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
RNI_ENGINE_PKG="${RNI_ENGINE_PKG:-$ROOT/packages-engine/engine-linux-x64}"

fail() { echo "ENG06_FAIL: $*" >&2; exit 1; }

[ -d "$BASE_APP/node_modules/react-native" ] || bash tools/base-app.sh
[ -d "$BASE_APP/node_modules/react-native" ] || fail "no base RN app at $BASE_APP"

WORK="${ENG06_WORK:-$(mktemp -d)}"
echo "workdir: $WORK"

APP="$WORK/Eng06App"
# ⛔ ALWAYS REINSTALL. An earlier version of this script skipped the install
# when $APP already existed (a speed-up for ENG06_WORK reruns), and that made
# the gate measure a STALE BINARY: it printed the sha of an engine three builds
# old, reported the defect as still reproducing, and sent me looking for a bug
# in code that was already fixed. A gate that can silently test the wrong
# artifact is worse than a slow one. The sha printed below is the sha that ran.
rm -rf "$APP"
echo "== 1. pack + install into a pristine app OUTSIDE the repo =="
ENGINE_TGZ="$(cd "$RNI_ENGINE_PKG" && npm pack --silent --pack-destination "$WORK")"
MAIN_TGZ="$(cd package && npm pack --silent --pack-destination "$WORK")"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="eng06app";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="probe"; a.displayName="probe";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent \
  "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" || fail "npm install of the tarballs failed"
npx --no-install react-native init-impeller >/dev/null 2>&1 || fail "init-impeller failed"

cd "$APP"
ENGINE="$(node node_modules/@react-native-impeller/core/src/bin/engine-path.js)" \
  || fail "engine resolver failed"
echo "engine: $ENGINE"
INSTALLED_SHA="$(sha256sum "$ENGINE" | cut -d' ' -f1)"
STAGED_SHA="$(sha256sum "$RNI_ENGINE_PKG/bin/rn-impeller" | cut -d' ' -f1)"
echo "sha256: $INSTALLED_SHA"
# The assertion the rm -rf above makes cheap, and which would have caught the
# stale-binary run on its own: what got installed must be what was staged.
[ "$INSTALLED_SHA" = "$STAGED_SHA" ] \
  || fail "the installed engine ($INSTALLED_SHA) is NOT the staged one ($STAGED_SHA) -- this gate would be measuring a different binary than the one just built"

# ---------------------------------------------------------------------------
echo "== ARM (a): the module manifest =="
MANIFEST="$WORK/modules.txt"
"$ENGINE" --list-modules > "$MANIFEST" 2>&1 || fail "--list-modules exited nonzero"
LINE="$(grep -o 'module=NativeAnimatedModule methods=[^ ]*' "$MANIFEST" || true)"
[ -n "$LINE" ] || fail "--list-modules does not list NativeAnimatedModule (the module is not registered)"
for m in startAnimatingNode stopAnimation createAnimatedNode connectAnimatedNodeToView; do
  echo "$LINE" | grep -q "\b$m\b" \
    || fail "NativeAnimatedModule is registered but has no $m() -- the method map is not RN's"
done
echo "   OK NativeAnimatedModule registered, $(echo "$LINE" | sed 's/.*methods=//' | tr ',' '\n' | wc -l) methods"

# ---------------------------------------------------------------------------
echo "== 2. swap in the peer's ENG-06 fixture and bundle =="
cp "$ROOT/fixtures/eng06-animated/index.js" "$APP/index.js"
mkdir -p impeller/build
npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/eng06.bundle \
    >/dev/null 2>&1 || fail "bundle failed"
BUNDLE="$APP/impeller/build/eng06.bundle"
[ -s "$BUNDLE" ] || fail "no bundle produced"

# Run headless at the peer's geometry. --screenshot-first is the frame-0
# capture; --screenshot is written at the end of the stepped loop.
run() {
  local frames="$1" tag="$2"
  rm -f "$WORK/$tag-a.ppm" "$WORK/$tag-b.ppm"
  "$ENGINE" --headless --probe-banner off \
            --bundle "$BUNDLE" --app-name probe \
            --width 300 --height 140 --frames "$frames" \
            --screenshot-first "$WORK/$tag-a.ppm" \
            --screenshot "$WORK/$tag-b.ppm" \
            > "$WORK/$tag.log" 2>&1 \
    || { tail -15 "$WORK/$tag.log" >&2; fail "$tag: engine exited nonzero"; }
  # An Invariant Violation tears the tree down and paints one black RootView,
  # which would otherwise read as "the animation simply did not move".
  if grep -q '\[js-exception\] (fatal' "$WORK/$tag.log"; then
    grep '\[js-exception\]' "$WORK/$tag.log" >&2
    fail "$tag: the bundle threw a fatal JS exception -- useNativeDriver was refused"
  fi
  [ -s "$WORK/$tag-a.ppm" ] || fail "$tag: --screenshot-first wrote nothing (headless path ignores it)"
  [ -s "$WORK/$tag-b.ppm" ] || fail "$tag: no late capture"
}

# Sum the GREEN CHANNEL over box A (the control) and box B (the animated
# subject), split at the GAP BETWEEN THEM.
#
# ⛔ THE SPLIT IS x=130, NOT THE MIDPOINT. The fixture is 300 wide with 20px
# padding and a 20px gap, so A occupies x=20..120 and B occupies x=140..240 --
# B straddles the 150px midpoint. A midpoint split put 10 columns of box B into
# the CONTROL total, so the control "changed" by exactly those columns the
# moment the animation started, and the gate failed with "something global is
# repainting" on a correctly working engine. The control arm was measuring the
# subject.
#
# ⛔ SUM THE CHANNEL, DO NOT THRESHOLD IT. An earlier version counted pixels with
# green > 120, i.e. "is the box visible", and reported a working animation as
# FROZEN: an opacity ramp spends most of its time dim, and at the sampled frame
# box B painted green=4 -- every pixel correct, every pixel under the threshold,
# count 0 on both frames. A threshold turns a continuous quantity into a boolean
# and discards exactly the part that moves.
counts() {
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
SPLIT = 130  # the gap between box A (20..120) and box B (140..240)
a = b = 0
for y in range(h):
    for x in range(w):
        o = (y*w + x) * 3
        if x < SPLIT: a += px[o+1]
        else: b += px[o+1]
print(a, b)
PY
}

echo "== ARM (b): the animated box moves, the control does not =="
# ⛔ THE FRAME COUNT IS PART OF THE ASSERTION. The fixture loops 0->1 over 500ms
# and 1->0 over 500ms: a full cycle is 1000ms, which at the frame-counted clock's
# 16.667ms/frame is EXACTLY 60 frames. Sampling at frame 60 therefore lands back
# on the ramp's start value and a perfectly working animation reads as frozen --
# measured, and it cost a debugging detour. 30 frames is the ramp's PEAK, the
# furthest point from the start value and the least sensitive to being a few
# frames off.
run 30 f30
read -r A1 B1 <<< "$(counts "$WORK/f30-a.ppm")"
read -r A2 B2 <<< "$(counts "$WORK/f30-b.ppm")"
echo "   frame 0 : control_green=$A1 animated_green=$B1"
echo "   frame 30: control_green=$A2 animated_green=$B2"
[ "$A1" -gt 1000000 ] || fail "the CONTROL box summed $A1 green at frame 0 -- the fixture never rendered, so nothing below means anything"
[ "$A1" -eq "$A2" ] || fail "the CONTROL box changed ($A1 -> $A2). Something global is repainting; box B moving is not evidence of an animation"
[ "$B1" -ne "$B2" ] || fail "the animated box summed $B1 green on BOTH frames -- the Animated value never moved (ENG-06 reproduces)"
# Direction matters: the ramp rises from 0, so a LOWER value at the peak means
# something is driving it backwards.
[ "$B2" -gt "$B1" ] || fail "the animated box got DIMMER ($B1 -> $B2) over a rising 0->1 ramp"

echo "== ARM (ticks): the NATIVE driver did the work, not RN's JS fallback =="
TICKS="$(grep -oE 'nativeanimated_ticks=[0-9]+' "$WORK/f30.log" | tail -1 | cut -d= -f2 || true)"
[ -n "$TICKS" ] || fail "the engine never printed nativeanimated_ticks -- the pump is absent, and the pixel diff above is RN's JS driver"
[ "$TICKS" -gt 0 ] || fail "nativeanimated_ticks=0: the pump exists but never ran, so the moving pixels came from RN's JS fallback"
echo "   OK nativeanimated_ticks=$TICKS"

echo "== ARM (props): the computed props actually REACHED a node =="
# ⚠️ THIS ARM EXISTS BECAUSE TICKS ALONE WERE GREEN THROUGH A REAL DEFECT.
# Measured 2026-09-11: ticks read a perfect 60/60 while every animated pixel
# stayed frozen, because SchedulerDelegate::schedulerShouldSynchronouslyUpdate-
# ViewOnUIThread -- the ONLY path animated props take -- was an empty stub. The
# pump ran, the graph evaluated, the opacity was computed, and it was discarded.
# ticks>0 with updates==0 is that exact signature.
UPDATES="$(grep -oE 'directprop_updates=[0-9]+' "$WORK/f30.log" | tail -1 | cut -d= -f2 || true)"
[ -n "$UPDATES" ] || fail "the engine never printed directprop_updates -- this binary predates the ENG-06 prop path"
[ "$UPDATES" -gt 0 ] \
  || fail "nativeanimated_ticks=$TICKS but directprop_updates=0: the animation engine ran and every prop it computed was DROPPED before reaching a node"
echo "   OK directprop_updates=$UPDATES"

# ---------------------------------------------------------------------------
echo "== ARM (c): --frames is the clock, measured 5x =="
# Five runs of the SAME frame count. A wall-clock driver varies here; a frame
# counter cannot.
DET_TICKS=""; DET_PX=""
for n in 1 2 3 4 5; do
  run 30 "det$n"
  t="$(grep -oE 'nativeanimated_ticks=[0-9]+' "$WORK/det$n.log" | tail -1 | cut -d= -f2)"
  read -r _ bpx <<< "$(counts "$WORK/det$n-b.ppm")"
  echo "   run $n: ticks=$t animated_green=$bpx"
  DET_TICKS="$DET_TICKS $t"; DET_PX="$DET_PX $bpx"
done
U_T="$(echo $DET_TICKS | tr ' ' '\n' | sort -u | wc -l)"
U_P="$(echo $DET_PX    | tr ' ' '\n' | sort -u | wc -l)"
[ "$U_T" -eq 1 ] || fail "5 runs of --frames 30 gave $U_T distinct tick counts ($DET_TICKS) -- the clock is not the frame counter"
[ "$U_P" -eq 1 ] || fail "5 runs of --frames 30 gave $U_P distinct animated green sums ($DET_PX) -- the animation is not deterministic under --frames"

# Equal-across-runs is necessary but NOT sufficient: a driver wired to nothing
# is also perfectly repeatable. A different --frames must move the clock.
#
# Asserted on the PIXELS, not only on ticks. A tick counter is incremented by
# the host loop and would differ between 30 and 200 even if the animation clock
# were still wall-time -- so ticks alone cannot tell "--frames drives the
# animation" from "--frames drives the loop". The rendered value at frame 45
# (mid-ramp-down) must differ from the value at frame 30 (the peak).
echo "   a different --frames must give a different RENDERED value:"
run 45 f45
T45="$(grep -oE 'nativeanimated_ticks=[0-9]+' "$WORK/f45.log" | tail -1 | cut -d= -f2)"
read -r _ B45 <<< "$(counts "$WORK/f45-b.ppm")"
echo "   --frames 45: ticks=$T45 animated_green=$B45 (vs $TICKS / $B2 at --frames 30)"
[ "$T45" -ne "$TICKS" ] \
  || fail "--frames 45 and --frames 30 both gave $TICKS ticks -- --frames does not step the loop at all"
[ "$B45" -ne "$B2" ] \
  || fail "--frames 45 and --frames 30 rendered the SAME animated value ($B2) -- the frame count steps the loop but NOT the animation clock, and the 5x agreement above was a frozen driver rather than a deterministic one"

echo
echo "ENG06_PASS (registered, animates, native-driven, updates=$UPDATES, green ${B45}@45 vs ${B2}@30, deterministic 5/5)"
