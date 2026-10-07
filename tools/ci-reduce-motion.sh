#!/usr/bin/env bash
# ENG-14 gate: AccessibilityInfo reads the host's reduce-motion state.
#
# THE BUG. AccessibilityInfo.isReduceMotionEnabled() REJECTED on impeller. Its
# non-Android arm calls NativeAccessibilityManagerIOS, which is
# TurboModuleRegistry.get('AccessibilityManager'), and no such module was
# registered. Apps (HostApp's loader, typing dots) read the rejection as "motion
# is fine".
#
# Fixture: fixtures/eng14-reduce-motion. It logs `ENG14 <query>=<value>` for
# reduceMotion, boldText, reduceTransparency, screenReader, grayscale and
# invertColors, and paints its 200x120 box GREEN when reduce motion reads true,
# RED when false, BLACK while pending or rejected.
#
#   A. RNI_REDUCE_MOTION=1: JS reads true, the engine logs reduce_motion=1,
#      the box paints GREEN.
#   B. RNI_REDUCE_MOTION=0: JS reads false, the box paints RED.
#   C. No override: JS reads the SYSTEM value. darwin: what
#      `defaults read com.apple.universalaccess reduceMotion` says (System
#      Settings > Accessibility > Display > Reduce motion). Elsewhere: false.
#      RNI_EXPECT_SYSTEM_RM=true|false overrides the expectation.
#   D. Every arm: all six queries RESOLVE (no REJECTED line). Once the module
#      exists AccessibilityInfo calls each getter directly, so a missing or
#      silent getter would throw or hang where the absent module rejected.
#
# NO-NPM MODE: renders the committed prebuilt bundle with the staged binary.
# The Mac runs: RNI_BIN=<darwin rn-impeller> bash tools/ci-reduce-motion.sh
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { echo "REDUCE_MOTION_GATE_FAIL: $*" >&2; exit 1; }

ENGINE="${RNI_BIN:-$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller}"
[ -x "$ENGINE" ] || fail "no engine binary at $ENGINE (set RNI_BIN)"
FIX="$ROOT/fixtures/eng14-reduce-motion"
BUNDLE="${RNI_TEST_BUNDLE:-$FIX/prebuilt/eng14-reduce-motion.bundle}"
if [ "${BUILD_BUNDLE:-0}" = "1" ] && [ -z "${RNI_TEST_BUNDLE:-}" ]; then
  bash "$ROOT/tools/build-fixture-bundle.sh" eng14-reduce-motion Eng14ReduceMotion \
    || fail "could not rebuild the bundle"
fi
[ -s "$BUNDLE" ] || fail "no bundle at $BUNDLE"

WORK="$(mktemp -d)"
KEEP="${KEEP_WORKDIR:-0}"
cleanup() { rni_kill_own; [ "$KEEP" = "1" ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

APP=Eng14ReduceMotion
QUERIES="reduceMotion boldText reduceTransparency screenReader grayscale invertColors"

# render <name> <RNI_REDUCE_MOTION value or "unset">
render() {
  local name="$1" rm="$2" rc n
  set +e
  if [ "$rm" = "unset" ]; then
    env -u RNI_REDUCE_MOTION "$ENGINE" --bundle "$BUNDLE" --app-name "$APP" --probe-banner off \
      --width 400 --height 300 --supersample-rnsvg 0 --headless \
      --screenshot "$WORK/$name.ppm" > "$WORK/$name.log" 2>&1
  else
    RNI_REDUCE_MOTION="$rm" "$ENGINE" --bundle "$BUNDLE" --app-name "$APP" --probe-banner off \
      --width 400 --height 300 --supersample-rnsvg 0 --headless \
      --screenshot "$WORK/$name.ppm" > "$WORK/$name.log" 2>&1
  fi
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { tail -20 "$WORK/$name.log" >&2; fail "$name: headless render exited $rc"; }
  n="$(sed -n 's/^rn-impeller: scene_nodes=\([0-9]*\)$/\1/p' "$WORK/$name.log" | tail -1)"
  [ -n "$n" ] && [ "$n" -gt 0 ] || { tail -20 "$WORK/$name.log" >&2; fail "$name: scene_nodes=${n:-none}: fixture did not mount"; }
}

# D: every query resolved, exactly once, with a boolean.
check_all_resolved() {
  local name="$1" q
  if grep -q 'ENG14 .* REJECTED' "$WORK/$name.log"; then
    grep 'ENG14 .* REJECTED' "$WORK/$name.log" | head -3 >&2
    fail "D($name): a query REJECTED: the AccessibilityManager module is missing"
  fi
  for q in $QUERIES; do
    [ "$(grep -cE "ENG14 $q=(true|false)\$" "$WORK/$name.log")" = "1" ] \
      || fail "D($name): query $q did not resolve exactly once with a boolean (a getter is missing or never calls back)"
  done
}

js_rm() { sed -n -E 's/.*ENG14 reduceMotion=(true|false)$/\1/p' "$WORK/$1.log" | tail -1; }

# Colour of the fixture box's empty corner, away from its caption. The PPM can
# be 2x on a Retina host, so scale from the header.
box_colour() {
  python3 - "$WORK/$1.ppm" <<'PY'
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
w, h = int(parts[1]), int(parts[2])
s = w / 400.0
def px(x, y):
    o = i + (int(y * s) * w + int(x * s)) * 3
    return d[o], d[o+1], d[o+2]
cols = set(px(x, y) for x in (150, 170, 190) for y in (80, 100, 112))
if len(cols) != 1:
    print('MIXED', sorted(cols)); sys.exit(0)
r, g, b = cols.pop()
if g > 150 and r < 40 and b < 40: print('GREEN')
elif r > 150 and g < 40 and b < 40: print('RED')
elif r < 20 and g < 20 and b < 20: print('BLACK')
else: print('OTHER', r, g, b)
PY
}

echo "== A. RNI_REDUCE_MOTION=1 reads true and paints GREEN =="
render on 1
check_all_resolved on
[ "$(js_rm on)" = "true" ] || fail "A: JS read reduceMotion=$(js_rm on), want true"
grep -q '^rn-impeller: a11y reduce_motion=1$' "$WORK/on.log" || fail "A: engine did not log a11y reduce_motion=1"
c="$(box_colour on)"; [ "$c" = "GREEN" ] || fail "A: box painted $c, want GREEN"
echo "   OK A: true, GREEN"

echo "== B. RNI_REDUCE_MOTION=0 reads false and paints RED =="
render off 0
check_all_resolved off
[ "$(js_rm off)" = "false" ] || fail "B: JS read reduceMotion=$(js_rm off), want false"
c="$(box_colour off)"; [ "$c" = "RED" ] || fail "B: box painted $c, want RED"
echo "   OK B: false, RED"

echo "== C. no override reads the system setting =="
WANT="${RNI_EXPECT_SYSTEM_RM:-}"
if [ -z "$WANT" ]; then
  if [ "$(uname)" = "Darwin" ]; then
    v="$(defaults read com.apple.universalaccess reduceMotion 2>/dev/null || echo 0)"
    [ "$v" = "1" ] && WANT=true || WANT=false
  else
    WANT=false
  fi
fi
render sys unset
check_all_resolved sys
[ "$(js_rm sys)" = "$WANT" ] || fail "C: JS read reduceMotion=$(js_rm sys) with no override, the system says $WANT"
c="$(box_colour sys)"
{ [ "$WANT" = "true" ] && [ "$c" = "GREEN" ]; } || { [ "$WANT" = "false" ] && [ "$c" = "RED" ]; } \
  || fail "C: box painted $c for system value $WANT"
echo "   OK C: system value $WANT ($(uname)), box $c"

echo "   OK D: all six queries resolved in every arm"
echo "REDUCE_MOTION_GATE_PASS (AccessibilityInfo.isReduceMotionEnabled reads the host, override and system)"
