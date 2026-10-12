#!/usr/bin/env bash
# SC-23 gate: the host follows the OS appearance live (test hook, never the real OS).
# Windowed on a private xvfb display, node-free (prebuilt bundle + RNI_BIN).
#   A. boot reads the hook: no --color-scheme, hook=dark -> first render dark.
#   B. live change: hook dark -> light mid-run emits appearanceChanged, the
#      subscriber re-renders ("dark light") and the box PAINTS white.
#   C. --color-scheme beats the OS: flag dark, hook flipped to light -> no event.
#   D. an app Appearance.setColorScheme override beats later OS changes.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
fail() { echo "OS_APPEARANCE_GATE_FAIL: $*" >&2; exit 1; }
BIN="${RNI_BIN:-$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller}"
[ -x "$BIN" ] || fail "no engine binary at $BIN"
BUNDLE="${RNI_TEST_BUNDLE:-$ROOT/fixtures/sc23-os-appearance/prebuilt/sc23-os-appearance.bundle}"
[ -s "$BUNDLE" ] || fail "no bundle at $BUNDLE"
WORK="$(mktemp -d)"
trap 'rni_kill_own; rm -rf "$WORK"' EXIT

wait_for() {  # $1 log  $2 ERE  $3 count  $4 what
  local i
  for i in $(seq 1 150); do
    [ "$(grep -cE "$2" "$1" 2>/dev/null || true)" -ge "$3" ] && return 0
    sleep 0.1
  done
  tail -15 "$1" >&2; fail "$4: timed out waiting for /$2/ x$3"
}
launch() {  # $1 name  $2 app  $3 initial hook  [extra engine args...]
  local name="$1" app="$2"; shift 2
  echo "$1" > "$WORK/hook"; shift
  ( cd "$(dirname "$BIN")" && RNI_OS_APPEARANCE_FILE="$WORK/hook" \
      xvfb-run -a -s "-screen 0 1280x1024x24" "$BIN" --bundle "$BUNDLE" --app-name "$app" \
      --probe-banner off --window --scale 1 --width 400 --height 300 --supersample-rnsvg 0 \
      --frames 1000000 --screenshot-after 3500 --screenshot "$WORK/$name.ppm" "$@" ) \
      > "$WORK/$name.log" 2>&1 &
  rni_track "$!"
}
renders() { sed -n -E 's/.*SC23 render scheme=([a-z]+)$/\1/p' "$WORK/$1.log" | tr '\n' ' ' | sed 's/ $//'; }
# The frame budget is far past the 3.5 s capture: unpaced xvfb runs ~1000 fps, so a
# small --frames ended the run before the screenshot (SC-45). finish kills it.
finish() {
  for i in $(seq 1 100); do [ -s "$WORK/$1.ppm" ] && grep -q '^rn-impeller: screenshot=' "$WORK/$1.log" && break; sleep 0.2; done
  rni_kill_own
  [ -s "$WORK/$1.ppm" ] || { tail -15 "$WORK/$1.log" >&2; fail "$1: the engine wrote no screenshot"; }
}
box() {
  python3 - "$WORK/$1.ppm" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
parts, i = [], 0
while len(parts) < 4:
    while d[i:i+1].isspace(): i += 1
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

echo "== A+B. boot from the hook, then follow a live change =="
launch b Sc23OsAppearance dark
wait_for "$WORK/b.log" 'SC23 render scheme=dark$' 1 "B: first render"
grep -q '^rn-impeller: color_scheme=dark source=hook$' "$WORK/b.log" \
  || fail "A: boot scheme line was '$(grep '^rn-impeller: color_scheme=' "$WORK/b.log" | head -1)', want dark source=hook"
sleep 0.5; echo light > "$WORK/hook"
wait_for "$WORK/b.log" 'SC23 render scheme=light$' 1 "B: re-render after the OS flip"
grep -q '^rn-impeller: appearance_changed scheme=light source=os$' "$WORK/b.log" \
  || fail "B: the host never reported the OS change"
finish b
[ "$(renders b)" = "dark light" ] || fail "B: subscriber renders were '$(renders b)', want 'dark light'"
c="$(box b)" || fail "B: could not read $WORK/b.ppm"; [ "$c" = "WHITE" ] || fail "B: box painted $c after the OS went light, want WHITE"
echo "   OK A+B: renders '$(renders b)', box WHITE"

echo "== C. --color-scheme beats the OS =="
launch c Sc23OsAppearance dark --color-scheme dark
wait_for "$WORK/c.log" 'SC23 render scheme=dark$' 1 "C: first render"
sleep 0.5; echo light > "$WORK/hook"; sleep 1.5
grep -q 'source=flag' "$WORK/c.log" || fail "C: scheme source was not the flag"
grep -q '^rn-impeller: appearance_changed' "$WORK/c.log" && fail "C: the OS change overrode --color-scheme"
finish c
[ "$(renders c)" = "dark" ] || fail "C: renders were '$(renders c)', want only 'dark'"
echo "   OK C: flag held, renders '$(renders c)'"

echo "== D. an app override beats later OS changes =="
launch d Sc23Override light
wait_for "$WORK/d.log" 'SC23 render scheme=dark$' 1 "D: app override render"
echo dark > "$WORK/hook"; sleep 0.6; echo light > "$WORK/hook"; sleep 1.5
finish d
[ "$(renders d)" = "light dark" ] || fail "D: renders were '$(renders d)', want 'light dark' (OS change must not beat the app override)"
echo "   OK D: renders '$(renders d)'"

echo "OS_APPEARANCE_GATE_PASS (boot from hook, live change repaints, flag and app override win)"
