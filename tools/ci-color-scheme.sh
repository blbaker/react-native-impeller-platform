#!/usr/bin/env bash
# ENG-17 gate: Appearance.setColorScheme re-renders useColorScheme() subscribers.
#
# THE BUG. AppearanceModule::setColorScheme only stored the value. RN's
# Appearance.js re-emits its 'change' event (what useColorScheme subscribes
# to) ONLY from the native `appearanceChanged` event, which iOS sends when the
# override changes the trait collection. With no event, every subscriber kept
# the old scheme until something else re-rendered it.
#
# Fixture: fixtures/eng17-color-scheme (two apps, run with --color-scheme dark,
# the "system" scheme). The subscriber paints its box #0a0a0a when dark,
# #ffffff when light, and logs every render.
#   A. setColorScheme('light'): the engine logs appearance_changed
#      scheme=light, the subscriber re-renders light, the box paints WHITE.
#   B. then setColorScheme('unspecified'): back to the system's dark.
#      getColorScheme() reads dark (not the literal 'unspecified'), the
#      subscriber re-renders dark, the box paints DARK.
#   C. setColorScheme('light') when the system is already light: no event and
#      no extra render (iOS sends no trait change when nothing changes).
#
# NO-NPM MODE: renders the committed prebuilt bundle with the staged binary.
# The Mac runs: RNI_BIN=<darwin rn-impeller> bash tools/ci-color-scheme.sh
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { echo "COLOR_SCHEME_GATE_FAIL: $*" >&2; exit 1; }

ENGINE="${RNI_BIN:-$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller}"
[ -x "$ENGINE" ] || fail "no engine binary at $ENGINE (set RNI_BIN)"
FIX="$ROOT/fixtures/eng17-color-scheme"
BUNDLE="${RNI_TEST_BUNDLE:-$FIX/prebuilt/eng17-color-scheme.bundle}"
if [ "${BUILD_BUNDLE:-0}" = "1" ] && [ -z "${RNI_TEST_BUNDLE:-}" ]; then
  bash "$ROOT/tools/build-fixture-bundle.sh" eng17-color-scheme Eng17ColorScheme \
    || fail "could not rebuild the bundle"
fi
[ -s "$BUNDLE" ] || fail "no bundle at $BUNDLE"

WORK="$(mktemp -d)"
KEEP="${KEEP_WORKDIR:-0}"
cleanup() { rni_kill_own; [ "$KEEP" = "1" ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

render() {  # $1 name  $2 app  $3 system scheme
  local rc n
  set +e
  "$ENGINE" --bundle "$BUNDLE" --app-name "$2" --color-scheme "$3" --probe-banner off \
    --width 400 --height 300 --supersample-rnsvg 0 --headless \
    --screenshot "$WORK/$1.ppm" > "$WORK/$1.log" 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { tail -20 "$WORK/$1.log" >&2; fail "$1: headless render exited $rc"; }
  n="$(sed -n 's/^rn-impeller: scene_nodes=\([0-9]*\)$/\1/p' "$WORK/$1.log" | tail -1)"
  [ -n "$n" ] && [ "$n" -gt 0 ] || { tail -20 "$WORK/$1.log" >&2; fail "$1: scene_nodes=${n:-none}: fixture did not mount"; }
}
renders() { sed -n -E 's/.*ENG17 render scheme=([a-z]+)$/\1/p' "$WORK/$1.log" | tr '\n' ' ' | sed 's/ $//'; }

# Colour of the subscriber box's empty corner, away from its caption.
box() {
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
w = int(parts[1]); s = w / 400.0
def px(x, y):
    o = i + (int(y * s) * w + int(x * s)) * 3
    return tuple(d[o:o+3])
cols = set(px(x, y) for x in (150, 170, 190) for y in (80, 100, 112))
if cols == {(255, 255, 255)}: print('WHITE')
elif len(cols) == 1 and all(abs(c - 10) <= 3 for c in next(iter(cols))): print('DARK')
else: print('OTHER', sorted(cols))
PY
}

echo "== A. setColorScheme('light') re-renders the subscriber light =="
render a Eng17ColorScheme dark
grep -q '^rn-impeller: appearance_changed scheme=light$' "$WORK/a.log" \
  || fail "A: the engine never emitted appearanceChanged(light)"
[ "$(renders a)" = "dark light" ] || fail "A: subscriber renders were '$(renders a)', want 'dark light' (no re-render on setColorScheme)"
c="$(box a)"; [ "$c" = "WHITE" ] || fail "A: box painted $c after setColorScheme('light'), want WHITE"
echo "   OK A: renders '$(renders a)', box WHITE"

echo "== B. setColorScheme('unspecified') goes back to the system's dark =="
render b Eng17Unspecified dark
grep -q 'ENG17 set unspecified get=dark$' "$WORK/b.log" \
  || fail "B: getColorScheme() after 'unspecified' read '$(sed -n -E 's/.*ENG17 set unspecified get=([a-z]+)$/\1/p' "$WORK/b.log")', want dark (the system scheme)"
[ "$(renders b)" = "dark light dark" ] || fail "B: subscriber renders were '$(renders b)', want 'dark light dark'"
c="$(box b)"; [ "$c" = "DARK" ] || fail "B: box painted $c after 'unspecified', want DARK"
echo "   OK B: renders '$(renders b)', box DARK"

echo "== C. setting the scheme it already has sends nothing =="
render c Eng17ColorScheme light
grep -q '^rn-impeller: appearance_changed' "$WORK/c.log" && fail "C: appearanceChanged emitted for a no-op set (light -> light)"
[ "$(renders c)" = "light" ] || fail "C: subscriber renders were '$(renders c)', want one 'light'"
echo "   OK C: no event, one render"

echo "COLOR_SCHEME_GATE_PASS (setColorScheme re-renders useColorScheme; 'unspecified' returns to the system; no-op sends nothing)"
