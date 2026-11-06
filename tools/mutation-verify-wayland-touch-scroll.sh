#!/usr/bin/env bash
# Mutation check for tools/ci-wayland-touch-scroll.sh: each mutant must make the
# gate FAIL through the arm written for it. The gate's own arm N (same binary,
# RNI_WAYLAND_TOUCH=0) is the negative control inside every run.
#
#   M1 WaylandTouch.cpp: wl_touch.motion no longer forwarded -> V: no begin-drag
#   M2 FabricHostTouchScroll.cpp: a drag never claims a scroll -> V: no begin-drag
#
# Sources are restored with cp + touch (never cp -p: an old mtime makes ninja
# keep the mutant's object), the engine is rebuilt, and the gate must PASS
# again at the end: proof the restore took.
# ⛔ It rebuilds and restages packages-engine/engine-linux-<arch>: do not run it
# while another gate is reading that package.
#
# Usage: bash tools/mutation-verify-wayland-touch-scroll.sh [--arch x64|arm64]
set -uo pipefail
cd "$(dirname "$0")/.."
ARCH=x64
[ "${1:-}" = "--arch" ] && ARCH="${2:-x64}"
case "$ARCH" in x64|arm64) ;; *) echo "usage: $0 [--arch x64|arm64]"; exit 2 ;; esac
WT=engine/host/WaylandTouch.cpp
FH=engine/fabric/FabricHostTouchScroll.cpp
LOGS="${MUT_LOGS:-${TMPDIR:-/tmp}/mutation-wayland-touch-scroll-$ARCH}"
mkdir -p "$LOGS"
BAK="$(mktemp -d)"; cp "$WT" "$BAK/wt"; cp "$FH" "$BAK/fh"
restore() { cp "$BAK/wt" "$WT"; cp "$BAK/fh" "$FH"; touch "$WT" "$FH"; }
trap 'restore; rm -rf "$BAK"' EXIT
fails=0

build() { bash tools/engine-build.sh linux "$ARCH" > "$LOGS/build-$1.log" 2>&1; }
gate() { bash tools/ci-wayland-touch-scroll.sh --arch "$ARCH" > "$LOGS/gate-$1.log" 2>&1; }
apply() {  # $1 file, $2 old, $3 new: exact anchor, must occur once
  python3 - "$1" "$2" "$3" <<'PY'
import sys
path, old, new = sys.argv[1:4]
s = open(path).read()
n = s.count(old)
assert n == 1, f'anchor found {n}x in {path}: {old!r}'
open(path, 'w').write(s.replace(old, new))
PY
}
code_mutant() {  # $1 name, $2 file, $3 old, $4 new, $5 ERE the FAIL line must match
  echo "== $1 ($ARCH)"
  restore
  apply "$2" "$3" "$4" || { echo "   $1: anchor missing (mutant stale)"; fails=$((fails + 1)); return; }
  touch "$2"
  build "$1" || { echo "   $1: engine build failed (see $LOGS/build-$1.log)"; fails=$((fails + 1)); restore; return; }
  if gate "$1"; then
    echo "   $1: SURVIVED ($(tail -1 "$LOGS/gate-$1.log"))"; fails=$((fails + 1))
  elif grep -qE "$5" "$LOGS/gate-$1.log"; then
    echo "   $1: killed: $(grep -E 'WAYLAND_TOUCH_SCROLL_FAIL' "$LOGS/gate-$1.log" | tail -1)"
  else
    echo "   $1: killed, but not by the expected arm /$5/: $(tail -1 "$LOGS/gate-$1.log")"; fails=$((fails + 1))
  fi
  restore
}

code_mutant M1 "$WT" \
  '  g.surface->synthesiseTouch(2, g.lastX, g.lastY);' \
  '  (void)0;  // MUTANT M1: wl_touch.motion not forwarded' \
  'WAYLAND_TOUCH_SCROLL_FAIL: V: no onScrollBeginDrag'
code_mutant M2 "$FH" \
  '  if (t.state.tag == 0) return false;' \
  '  return false;  // MUTANT M2: a drag never claims a scroll' \
  'WAYLAND_TOUCH_SCROLL_FAIL: V: no onScrollBeginDrag'

echo "== restore + rebuild ($ARCH)"
restore
build restore || { echo "MUTATION_WAYLAND_TOUCH_SCROLL_FAIL: restored engine does not build"; exit 1; }
if gate control; then echo "   control: $(tail -1 "$LOGS/gate-control.log")"
else echo "   control: FAILED after restore ($(tail -1 "$LOGS/gate-control.log"))"; fails=$((fails + 1)); fi
cmp -s "$BAK/wt" "$WT" && cmp -s "$BAK/fh" "$FH" \
  || { echo "MUTATION_WAYLAND_TOUCH_SCROLL_FAIL: a mutated source differs from its pre-run copy after restore"; exit 1; }
trap - EXIT; rm -rf "$BAK"
if [ "$fails" -eq 0 ]; then echo "MUTATION_WAYLAND_TOUCH_SCROLL_PASS ($ARCH: M1 M2 killed by arm V, control green)"; exit 0; fi
echo "MUTATION_WAYLAND_TOUCH_SCROLL_FAIL ($ARCH: $fails wrong; logs $LOGS)"; exit 1
