#!/usr/bin/env bash
# requestAnimationFrame pacing GATE (Jim v5 chat-loop report, 2026-10-19).
#
# RN core's bridgeless requestAnimationFrame is setTimeout(0), so a JS-driven
# Animated loop ran as fast as the JS thread could go (Jim's typing dots:
# ~14,400 frame requests/s, JS thread 88-100%, streamed text starved). The
# engine now runs rAF callbacks once per frame (runtime/AnimationFrameScheduler).
#
#   A  contract, windowed (frame cadence). fixtures/native-anim-dots RafSemantics:
#      same-batch cancel, cancel-before-flush, a throwing callback neither
#      stops the rest nor goes unreported, a rAF registered inside a callback
#      runs on a LATER frame; then a 2 s rAF loop runs at frame rate.
#      Control: RNI_RAF_PACING=0 (RN's own rAF) must run >= 1000/s, so the
#      rate arm can see the defect.
#   B  contract, headless single-shot (timer cadence, no frame loop): the same
#      contract, and rAF still fires (~60/s) with nothing driving frames.
#   C  cost, windowed: the chat-loop transcript under JS-driven dots. Frame
#      requests per painted frame stay small; the control (pacing off) floods.
#   D  the JS-driven dots still ANIMATE (pixels, shots 150 ms apart).
#   E  the NATIVE-driven dots animate windowed (Jim's TypingDot shape:
#      interpolated opacity + translateY, loop(sequence) with delays).
#
# Node-free: committed bundles + RNI_BIN. linux runs windowed arms under xvfb;
# darwin uses the real window server.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
DOTS="$ROOT/fixtures/native-anim-dots/prebuilt/native-anim-dots.bundle"
CHAT="$ROOT/fixtures/chat-loop/prebuilt/chat-loop.bundle"
fail() { echo "RAF_PACING_FAIL: $*" >&2; exit 1; }
[ -s "$DOTS" ] || fail "no committed bundle at $DOTS"
[ -s "$CHAT" ] || fail "no committed bundle at $CHAT"
. tools/lib/host-window.sh
[ "$(rni_host)" != other ] || fail "linux (xvfb) or darwin only"
if [ -n "${RNI_BIN:-}" ]; then
  BIN="$RNI_BIN"
else
  bash tools/engine-build.sh > "${TMPDIR:-/tmp}/ci-raf-build.log" 2>&1 \
    || { tail -20 "${TMPDIR:-/tmp}/ci-raf-build.log" >&2; fail "engine build failed"; }
  BIN="$ROOT/packages-engine/engine-$(rni_host)-$( [ "$(uname -m)" = arm64 ] && echo arm64 || echo x64)/bin/rn-impeller"
fi
[ -x "$BIN" ] || fail "no engine binary at $BIN (set RNI_BIN)"
echo "engine: $BIN ($(shasum -a 256 "$BIN" | cut -c1-12)) host=$(rni_host)"

WORK="$(mktemp -d)"
cleanup() { [ "${KEEP_WORKDIR:-0}" = 1 ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

need_line() {  # log ERE what
  grep -qE "$2" "$1" || { grep -E 'rafsem|rafrate|raf_pacing|js-exception' "$1" | tail -6 >&2; tail -8 "$1" >&2; fail "$3"; }
}
rate() { sed -n 's/.*rafrate per_s=\([0-9]*\).*/\1/p' "$1" | tail -1; }
raf_field() { sed -n "s/^rn-impeller: raf_pacing .*[ ]$2=\([0-9]*\).*/\1/p" "$1" | tail -1; }

windowed() {  # tag bundle app w h runsec pacing(0|1) [extra engine args...]
  local tag="$1" bun="$2" app="$3" w="$4" h="$5" sec="$6" pacing="$7" rc=0; shift 7
  ( export RNI_RAF_PACING="$pacing"; cd "$(dirname "$BIN")" && rni_xrun "$WORK/xvfb.auth" \
      timeout 120 "$BIN" --window --scale 1 --width "$w" --height "$h" --bundle "$bun" \
      --app-name "$app" --probe-banner off --supersample-rnsvg 0 --idle-skip \
      --idle-run-sec "$sec" "$@" ) > "$WORK/$tag.log" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || { tail -15 "$WORK/$tag.log" >&2; fail "$tag exited $rc"; }
  need_line "$WORK/$tag.log" 'RN_IMPELLER_WINDOW_OK' "$tag: window run did not finish OK"
}

contract() {  # log mode
  need_line "$1" 'rafsem a=1 b=0 c=1 d=0 nested_later=1' \
    "$1: rAF contract broken (want a=1 b=0 c=1 d=0 nested_later=1)"
  need_line "$1" 'js-exception.*raf-semantics expected throw' \
    "$1: a throwing rAF callback was swallowed, not reported"
  need_line "$1" "^rn-impeller: raf_pacing enabled=1 mode=$2 " "$1: pacing not in $2 mode"
  local r; r=$(rate "$1")
  [ -n "$r" ] || fail "$1: no rafrate line (the 2 s rAF loop never finished)"
  [ "$r" -ge 20 ] && [ "$r" -le 150 ] || fail "$1: rAF ran $r/s, want frame rate (20..150)"
  echo "   $(basename "$1" .log): contract ok, rAF $r/s, $(grep -o 'raf_pacing .*' "$1" | tail -1)"
}

echo "== A: contract + rate, windowed (frame cadence) =="
windowed a-paced "$DOTS" RafSemantics 220 100 4 1
contract "$WORK/a-paced.log" frame
[ "$(raf_field "$WORK/a-paced.log" frame_flushes)" -gt 0 ] || fail "A: no frame-driven flush"
windowed a-control "$DOTS" RafSemantics 220 100 4 0
need_line "$WORK/a-control.log" 'rafsem a=1 b=0 c=1 d=0 nested_later=1' "A control: RN's own rAF broke the contract fixture"
AC=$(rate "$WORK/a-control.log")
echo "   control (RN setTimeout(0) rAF): $AC/s"
[ "${AC:-0}" -ge 1000 ] || fail "A control: unpaced rAF ran only ${AC:-0}/s -- the rate arm cannot see the defect"

echo "== B: contract + rate, headless single-shot (timer cadence) =="
( export RNI_RAF_PACING=1; cd "$(dirname "$BIN")" && timeout 120 "$BIN" --headless --width 220 --height 100 \
    --bundle "$DOTS" --app-name RafSemantics --probe-banner off ) > "$WORK/b-headless.log" 2>&1 \
  || { tail -15 "$WORK/b-headless.log" >&2; fail "B: headless exited non-zero"; }
contract "$WORK/b-headless.log" timer
[ "$(raf_field "$WORK/b-headless.log" timer_flushes)" -gt 0 ] || fail "B: no timer-driven flush"

echo "== C: cost, chat-loop transcript under JS-driven dots, windowed 6 s =="
sched() { sed -n "s/^rn-impeller: frame_scheduler .*[ ]$2=\([0-9]*\).*/\1/p" "$1" | tail -1; }
windowed c-paced "$CHAT" ChatLoopJs 800 600 6 1
windowed c-control "$CHAT" ChatLoopJs 800 600 6 0
for t in c-paced c-control; do need_line "$WORK/$t.log" 'chatloop dots=3 native=0' "$t: dots not on the JS driver"; done
PF=$(sched "$WORK/c-paced.log" frames); PR=$(sched "$WORK/c-paced.log" requests)
CF=$(sched "$WORK/c-control.log" frames); CR=$(sched "$WORK/c-control.log" requests)
echo "   paced: frames=$PF requests=$PR | control: frames=$CF requests=$CR"
[ "${PF:-0}" -ge 60 ] || fail "C: only ${PF:-0} frames painted in 6 s"
[ "${CR:-0}" -ge $(( ${CF:-1} * 20 )) ] || fail "C control: unpaced requests=$CR < 20 x frames=$CF -- the cost arm cannot see the defect"
[ "${PR:-999999}" -le $(( PF * 6 )) ] || fail "C: paced requests=$PR > 6 x frames=$PF -- rAF is not paced to frames"

dots() {  # ppm -> "l0 l1 l2"
  python3 - "$1" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
parts, i = [], 0
while len(parts) < 4:
    while d[i:i+1].isspace(): i += 1
    if d[i:i+1] == b'#':
        while d[i:i+1] != b'\n': i += 1
        continue
    j = i
    while not d[j:j+1].isspace(): j += 1
    parts.append(d[i:j]); i = j
i += 1
w, h = int(parts[1]), int(parts[2]); px = d[i:]
out = []
for x0 in (20, 80, 140):
    s = 0
    for y in range(0, min(h, 90)):
        for x in range(x0, x0 + 40):
            o = (y * w + x) * 3; s += px[o] + px[o+1] + px[o+2]
    out.append(str(s // 3))
print(' '.join(out))
PY
}
animates() {  # label app
  local a="$2" t
  for t in 2000 2150 2300; do
    windowed "$1-$t" "$DOTS" "$a" 220 100 4 1 --screenshot "$WORK/$1-$t.ppm" --screenshot-after "$t"
    [ -s "$WORK/$1-$t.ppm" ] || fail "$1: no screenshot at ${t} ms"
  done
  python3 - "$1" "$(dots "$WORK/$1-2000.ppm")" "$(dots "$WORK/$1-2150.ppm")" "$(dots "$WORK/$1-2300.ppm")" <<'PY' || fail "$1: dots did not animate"
import sys
label, shots = sys.argv[1], [list(map(int, s.split())) for s in sys.argv[2:]]
moving = 0
for k in range(3):
    vals = [s[k] for s in shots]
    if max(vals) - min(vals) >= 0.25 * max(vals): moving += 1
print("   %s: dot luma at 2000/2150/2300 ms: %s; %d of 3 dots moving" % (label, ' | '.join(' '.join(map(str, s)) for s in shots), moving))
sys.exit(0 if moving >= 2 else 1)
PY
}
echo "== D: JS-driven dots still animate under pacing =="
animates d-js DotsJimJs
echo "== E: native-driven dots (Jim's TypingDot shape) animate windowed =="
animates e-native DotsJim
echo "RAF_PACING_PASS"
