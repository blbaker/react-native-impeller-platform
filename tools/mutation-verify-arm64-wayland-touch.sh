#!/usr/bin/env bash
# Mutation check for tools/ci-arm64-wayland-touch.sh: each mutant must make the
# gate FAIL, through the arm written for it. Default arch x64 (native rebuild,
# about a minute per mutant); --arch arm64 runs the same mutants cross-built and
# gated under qemu (slower).
#
#   M1 WaylandTouch.cpp: wl_touch.motion no longer forwarded   -> arm C (drag)
#   M2 WaylandTouch.cpp: wl_touch.down x/y swapped             -> arm A (tap-b)
#   M3 RNI_GLFW_PLATFORM=wayland forced on every run           -> arm X (Xvfb run)
#   M4 GlfwPlatformSelect.h: the DISPLAY rule dropped (GLFW's  -> arm S1 (the
#      Wayland-first default reaches the default socket)           WSLg layout)
#
# Sources are restored with cp + touch (never cp -p: an old mtime makes ninja
# keep the mutant's object), the engine is rebuilt, and the gate must PASS
# again at the end: proof the restore took.
# ⛔ It rebuilds and restages packages-engine/engine-linux-<arch>: do not run it
# while another gate is reading that package.
#
# Usage: bash tools/mutation-verify-arm64-wayland-touch.sh [--arch x64|arm64]
set -uo pipefail
cd "$(dirname "$0")/.."
ARCH=x64
[ "${1:-}" = "--arch" ] && ARCH="${2:-x64}"
case "$ARCH" in x64) TAG=X64 ;; arm64) TAG=ARM64 ;; *) echo "usage: $0 [--arch x64|arm64]"; exit 2 ;; esac
export PATH="$HOME/.local/bin:$PATH"
WT=engine/host/WaylandTouch.cpp
SEL=engine/host/GlfwPlatformSelect.h
LOGS="${MUT_LOGS:-${TMPDIR:-/tmp}/mutation-wayland-touch-$ARCH}"
mkdir -p "$LOGS"
BAK="$(mktemp -d)"; cp "$WT" "$BAK/wt"; cp "$SEL" "$BAK/sel"
restore() { cp "$BAK/wt" "$WT"; cp "$BAK/sel" "$SEL"; touch "$WT" "$SEL"; }
trap 'restore; rm -rf "$BAK"' EXIT
fails=0

build() { bash tools/engine-build.sh linux "$ARCH" > "$LOGS/build-$1.log" 2>&1; }
gate() { bash tools/ci-arm64-wayland-touch.sh --arch "$ARCH" > "$LOGS/gate-$1.log" 2>&1; }
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
expect_killed() {  # $1 mutant, $2 ERE the FAIL line must match
  if gate "$1"; then
    echo "   $1: SURVIVED ($(tail -1 "$LOGS/gate-$1.log"))"; fails=$((fails + 1))
  elif grep -qE "$2" "$LOGS/gate-$1.log"; then
    echo "   $1: killed: $(grep -E "${TAG}_WAYLAND_TOUCH_FAIL" "$LOGS/gate-$1.log" | tail -1)"
  else
    echo "   $1: killed, but not by the expected arm /$2/: $(tail -1 "$LOGS/gate-$1.log")"; fails=$((fails + 1))
  fi
}
code_mutant() {  # $1 name, $2 file, $3 old, $4 new, $5 ERE
  echo "== $1 ($ARCH)"
  restore
  apply "$2" "$3" "$4" || { echo "   $1: anchor missing (mutant stale)"; fails=$((fails + 1)); return; }
  touch "$2"
  build "$1" || { echo "   $1: engine build failed (see $LOGS/build-$1.log)"; fails=$((fails + 1)); restore; return; }
  expect_killed "$1" "$5"
  restore
}

code_mutant M1 "$WT" \
  '  g.surface->synthesiseTouch(2, g.lastX, g.lastY);' \
  '  (void)0;  // MUTANT M1: wl_touch.motion not forwarded' \
  "${TAG}_WAYLAND_TOUCH_FAIL: C: "
code_mutant M2 "$WT" \
  $'  g.lastX = wl_fixed_to_double(fx);\n  g.lastY = wl_fixed_to_double(fy);\n  ++g.downs;' \
  $'  g.lastX = wl_fixed_to_double(fy);  // MUTANT M2: x/y swapped\n  g.lastY = wl_fixed_to_double(fx);\n  ++g.downs;' \
  "${TAG}_WAYLAND_TOUCH_FAIL: A: "
code_mutant M4 "$SEL" \
  '  if (env("DISPLAY") != nullptr) return {x11Id, "x11", "DISPLAY_set_session_not_wayland"};' \
  '  // MUTANT M4: DISPLAY rule dropped' \
  "${TAG}_WAYLAND_TOUCH_FAIL: S1: "

echo "== restore + rebuild ($ARCH)"
restore
build restore || { echo "MUTATION_WAYLAND_TOUCH_FAIL: restored engine does not build"; exit 1; }
echo "== M3 ($ARCH): RNI_GLFW_PLATFORM=wayland on every run"
RNI_GLFW_PLATFORM=wayland expect_killed M3 "${TAG}_WAYLAND_TOUCH_FAIL: X: "
echo "== control: restored engine, unforced"
if gate control; then echo "   control: $(tail -1 "$LOGS/gate-control.log")"
else echo "   control: FAILED after restore ($(tail -1 "$LOGS/gate-control.log"))"; fails=$((fails + 1)); fi
cmp -s "$BAK/wt" "$WT" && cmp -s "$BAK/sel" "$SEL" \
  || { echo "MUTATION_WAYLAND_TOUCH_FAIL: a mutated source differs from its pre-run copy after restore"; exit 1; }
trap - EXIT; rm -rf "$BAK"
if [ "$fails" -eq 0 ]; then echo "MUTATION_WAYLAND_TOUCH_PASS ($ARCH: M1 M2 M3 M4 killed by their arms, control green)"; exit 0; fi
echo "MUTATION_WAYLAND_TOUCH_FAIL ($ARCH: $fails wrong; logs $LOGS)"; exit 1
