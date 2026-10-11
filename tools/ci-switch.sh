#!/usr/bin/env bash
# ENG-15 gate: <Switch> mounts at the iOS size, paints, and takes presses.
#
# THE BUG. No "Switch" component was registered, so RN's <Switch> mounted as a
# plain View: node_frame 0 x 0, nothing painted, and a tap fell through to the
# page behind it (audit tile 62).
#
# Fixture: fixtures/eng15-switch (see its header for the five switches).
#   A. MOUNT. Five node_frame=Switch lines, each 51 x 31 (UISwitch's size).
#   B. PAINT, no input. S1/S2 OFF, S3 ON at half alpha (disabled), S4 ON in
#      its custom colours (magenta track, yellow thumb at the RIGHT), S5 OFF in
#      its custom colours (blue track, yellow thumb at the LEFT).
#   C. TAP S1 (controlled). The engine toggles it, JS hears
#      `ENG15 s1 change=true`, and it paints ON (green track, thumb right).
#   D. TAP S2 (JS keeps value=false). JS hears change=true, Switch.js sends
#      the setValue(false) command back, and it paints OFF again.
#   E. TAP S3 (disabled). No toggle, no onChange, still paints ON.
#   F. TAP beside S1 (on the page, not the switch). Nothing toggles.
#
# A state is read from two samples on the track's centre line: L (x+6) and
# R (x+45). OFF = L thumb, R off-track. ON = L on-track, R thumb.
#
# NO-NPM MODE: renders the committed prebuilt bundle with the staged binary.
# The Mac runs: RNI_BIN=<darwin rn-impeller> bash tools/ci-switch.sh
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { echo "SWITCH_GATE_FAIL: $*" >&2; exit 1; }

ENGINE="${RNI_BIN:-$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller}"
[ -x "$ENGINE" ] || fail "no engine binary at $ENGINE (set RNI_BIN)"
FIX="$ROOT/fixtures/eng15-switch"
BUNDLE="${RNI_TEST_BUNDLE:-$FIX/prebuilt/eng15-switch.bundle}"
if [ "${BUILD_BUNDLE:-0}" = "1" ] && [ -z "${RNI_TEST_BUNDLE:-}" ]; then
  bash "$ROOT/tools/build-fixture-bundle.sh" eng15-switch Eng15Switch \
    || fail "could not rebuild the bundle"
fi
[ -s "$BUNDLE" ] || fail "no bundle at $BUNDLE"

WORK="$(mktemp -d)"
KEEP="${KEEP_WORKDIR:-0}"
cleanup() { rni_kill_own; [ "$KEEP" = "1" ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

render() {  # $1 name  [$2 tap X,Y]
  local name="$1" rc n
  local tap=()
  [ -n "${2:-}" ] && tap=(--tap "$2")
  set +e
  "$ENGINE" --bundle "$BUNDLE" --app-name Eng15Switch --probe-banner off \
    --width 400 --height 300 --supersample-rnsvg 0 --headless "${tap[@]}" \
    --screenshot "$WORK/$name.ppm" > "$WORK/$name.log" 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { tail -20 "$WORK/$name.log" >&2; fail "$name: headless render exited $rc"; }
  n="$(sed -n 's/^rn-impeller: scene_nodes=\([0-9]*\)$/\1/p' "$WORK/$name.log" | tail -1)"
  [ -n "$n" ] && [ "$n" -gt 0 ] || { tail -20 "$WORK/$name.log" >&2; fail "$name: scene_nodes=${n:-none}: fixture did not mount"; }
}

# state <name> <switch-x> <switch-y> -> OFF | ON | ONDIM | C_ON | C_OFF | ?(...)
state() {
  python3 - "$WORK/$1.ppm" "$2" "$3" <<'PY'
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
w = int(parts[1]); s = w / 400.0
x0, y0 = float(sys.argv[2]), float(sys.argv[3])
def px(x, y):
    o = i + (int(round(y * s)) * w + int(round(x * s))) * 3
    return tuple(d[o:o+3])
L, R = px(x0 + 8, y0 + 15.5), px(x0 + 43, y0 + 15.5)
def near(c, t, tol=24): return all(abs(a - b) <= tol for a, b in zip(c, t))
WHITE, OFFTRACK, GREEN = (255, 255, 255), (233, 233, 235), (52, 199, 89)
MAG, YEL, BLUE = (255, 0, 255), (255, 255, 0), (0, 0, 255)
# Half-alpha green on white, under a half-alpha white thumb: greenish but light.
def dimgreen(c): return c[1] - c[0] > 25 and c[0] > 110 and c[1] > 200
def white(c): return near(c, WHITE, 6)
def offtrack(c): return near(c, OFFTRACK, 8) and not white(c)
if white(L) and offtrack(R): print('OFF')
elif near(L, GREEN) and white(R): print('ON')
elif dimgreen(L) and white(R): print('ONDIM')
elif near(L, MAG) and near(R, YEL): print('C_ON')
elif near(L, YEL) and near(R, BLUE): print('C_OFF')
else: print(f'?(L={L} R={R})')
PY
}
expect() {  # $1 arm  $2 name  $3 label  $4 x  $5 y  $6 want
  local got
  got="$(state "$2" "$4" "$5")"
  [ "$got" = "$6" ] || fail "$1: $3 painted $got, want $6"
}

echo "== A. five Switches mount at 51 x 31 =="
render base
FR="$(grep -c '^rn-impeller: node_frame=Switch,' "$WORK/base.log" || true)"
[ "$FR" = "5" ] || { grep node_frame "$WORK/base.log" >&2; fail "A: $FR Switch node_frames, want 5 (Switch not registered?)"; }
BAD="$(grep '^rn-impeller: node_frame=Switch,' "$WORK/base.log" | grep -vc ',51\.0,31\.0$' || true)"
[ "$BAD" = "0" ] || { grep node_frame=Switch "$WORK/base.log" >&2; fail "A: $BAD Switch frames are not 51 x 31: it measures as a plain View"; }
echo "   OK A"

echo "== B. paint with no input =="
expect B base "S1 (controlled, false)" 20 20 OFF
expect B base "S2 (value false)" 20 80 OFF
expect B base "S3 (disabled, true)" 20 140 ONDIM
expect B base "S4 (custom, true)" 20 200 C_ON
expect B base "S5 (custom, false)" 120 200 C_OFF
echo "   OK B: OFF OFF ONDIM C_ON C_OFF"

echo "== C. tap S1 (controlled) turns it ON =="
render c 45,35
grep -qE '^rn-impeller: switch_toggle tag=[0-9]+ value=1 emitter=1$' "$WORK/c.log" \
  || { grep -E 'tap_hit|switch_' "$WORK/c.log" >&2 || true; fail "C: engine did not toggle S1 to 1 with an onChange emitter"; }
grep -q 'ENG15 s1 change=true$' "$WORK/c.log" || fail "C: JS never heard onValueChange(true) for S1"
expect C c "S1 after a tap" 20 20 ON
expect C c "S2 (untouched)" 20 80 OFF
echo "   OK C"

echo "== D. tap S2 (JS keeps false) snaps back OFF =="
render d 45,95
grep -q 'ENG15 s2 change=true$' "$WORK/d.log" || fail "D: JS never heard onValueChange(true) for S2"
grep -qE '^rn-impeller: switch_set tag=[0-9]+ value=0$' "$WORK/d.log" \
  || fail "D: no setValue(false) command reached the engine (Switch.js's revert path)"
expect D d "S2 after JS refused" 20 80 OFF
echo "   OK D"

echo "== E. tap S3 (disabled) does nothing =="
render e 45,155
grep -q '^rn-impeller: switch_toggle' "$WORK/e.log" && fail "E: the disabled S3 toggled"
grep -q 'ENG15 s3 change' "$WORK/e.log" && fail "E: the disabled S3 fired onValueChange"
expect E e "S3 after a tap" 20 140 ONDIM
echo "   OK E"

echo "== F. tap beside S1 toggles nothing =="
render f 120,35
grep -q '^rn-impeller: switch_toggle' "$WORK/f.log" && fail "F: a tap on the page toggled a switch"
expect F f "S1 after a tap beside it" 20 20 OFF
echo "   OK F"

echo "== G. press S1, drag off it, release on the page: cancelled =="
set +e
"$ENGINE" --bundle "$BUNDLE" --app-name Eng15Switch --probe-banner off \
  --width 400 --height 300 --supersample-rnsvg 0 --headless --drag 45,35:120,35:200,35 \
  --screenshot "$WORK/g.ppm" > "$WORK/g.log" 2>&1
rc=$?
set -e
[ "$rc" -eq 0 ] || { tail -20 "$WORK/g.log" >&2; fail "g: headless drag exited $rc"; }
grep -qE '^rn-impeller: drag_down_tag=[1-9]' "$WORK/g.log" || { grep drag_ "$WORK/g.log" >&2 || true; fail "G: the press did not land on S1"; }
grep -q '^rn-impeller: switch_toggle' "$WORK/g.log" && fail "G: a release OFF the switch toggled it (touch-up-inside only)"
expect G g "S1 after a drag-off release" 20 20 OFF
echo "   OK G"

echo "== H. press S1 and release ON it (capture path) toggles =="
set +e
"$ENGINE" --bundle "$BUNDLE" --app-name Eng15Switch --probe-banner off \
  --width 400 --height 300 --supersample-rnsvg 0 --headless --drag 45,35:50,36 \
  --screenshot "$WORK/h.ppm" > "$WORK/h.log" 2>&1
rc=$?
set -e
[ "$rc" -eq 0 ] || { tail -20 "$WORK/h.log" >&2; fail "h: headless drag exited $rc"; }
grep -qE '^rn-impeller: switch_toggle tag=[0-9]+ value=1 emitter=1$' "$WORK/h.log" \
  || fail "H: a press+release inside S1 through the capture path did not toggle it"
expect H h "S1 after a capture-path release inside" 20 20 ON
echo "   OK H"

echo "SWITCH_GATE_PASS (51x31 mount, iOS paint + custom colours, tap toggles + onChange, JS refusal snaps back, disabled inert)"
