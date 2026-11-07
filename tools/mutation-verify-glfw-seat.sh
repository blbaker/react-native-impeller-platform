#!/usr/bin/env bash
# Mutation check for the no-seat fix: the NS arm of tools/ci-arm64-wayland-touch.sh
# and the patch step in tools/glfw-fetch.sh (tools/glfw-patches/0001).
#
#   control  GLFW from a normal fetch (patch applied), built with the flags read
#            from this worktree's GLFW build tree, linked by replaying ninja's own
#            rn-impeller link line, staged like engine-build-linux.sh does
#            -> NS PASSES, and the archive, the link and the staged binary are
#            byte-identical to the real ones (the replay is faithful)
#   M1       the same pipeline from a fetch with the patch step skipped
#            (RNI_GLFW_SKIP_SEAT_GUARD=1); only wl_init.c.o differs
#            -> NS FAILS: engine exit 139 (SIGSEGV in glfwInit)
#   M2       wayland-session.sh loads rni-touch-inject even with
#            RNI_SESSION_NO_SEAT=1, so Weston HAS a seat
#            -> NS FAILS on its seat-less precondition (the WAYLAND_DEBUG oracle)
#   M3       a GLFW bump: glfw-fetch.sh --source-only on GLFW master (needs GitHub)
#            -> the fetch FAILS loudly (GLFW_SEAT_GUARD_FAIL), it does not build
#               a GLFW without the fix
#
# It builds nothing in the worktree's build trees and never restages
# packages-engine/: every mutant binary lives in a scratch dir and reaches the
# gate through RNI_<ARCH>_ENGINE_DIR. Needs a current build:
# bash tools/engine-build.sh linux <arch> first.
#
# Usage: bash tools/mutation-verify-glfw-seat.sh [--arch x64|arm64]   (default x64)
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
ARCH=x64
[ "${1:-}" = "--arch" ] && ARCH="${2:-x64}"
case "$ARCH" in
  x64)   TAG=X64; B="$ROOT/engine/build-linux-x64"; EB="$ROOT/engine/build" ;;
  arm64) TAG=ARM64; B="$ROOT/engine/build-linux-arm64"; EB="$B/engine" ;;
  *) echo "usage: $0 [--arch x64|arm64]"; exit 2 ;;
esac
export PATH="$HOME/.local/bin:$PATH"
JOBS="${JOBS:-10}"
GB="$B/glfw"; GI="$B/glfw-install"; PKG="$ROOT/packages-engine/engine-linux-$ARCH/bin"
SESS=tools/arm64-testenv/wayland-session.sh
W="$(mktemp -d "${TMPDIR:-/tmp}/mut-glfw-seat-$ARCH.XXXXXX")"
die() { echo "MUTATION_GLFW_SEAT_FAIL ($ARCH): $*"; exit 1; }
fails=0
for f in "$GB/CMakeCache.txt" "$GI/lib/libglfw3.a" "$EB/build.ninja" "$EB/rn-impeller" "$PKG/rn-impeller"; do
  [ -e "$f" ] || die "missing $f (bash tools/engine-build.sh linux $ARCH)"
done
cp "$SESS" "$W/session.orig"
restore() { cp "$W/session.orig" "$SESS"; touch "$SESS"; }
trap restore EXIT
cache() { grep -E "^$1:" "$2" | head -1 | cut -d= -f2-; }
AR="$(cache CMAKE_AR "$GB/CMakeCache.txt")"
STRIP=strip; [ "$ARCH" = arm64 ] && STRIP="$(cache CMAKE_STRIP "$EB/CMakeCache.txt")"
[ -x "$AR" ] || die "no archiver from $GB/CMakeCache.txt"

# The GLFW flags come from the real GLFW build tree, not from a copy of
# engine-build-linux.sh: every user-settable cache entry, minus its own dirs.
grep -E '^[A-Za-z_][A-Za-z0-9_]*:(BOOL|STRING|FILEPATH|PATH)=' "$GB/CMakeCache.txt" \
  | grep -vF "$GB" | grep -vE '^CMAKE_INSTALL_PREFIX:' \
  | sed -E 's/^([^:]+):([A-Z]+)=(.*)$/set(\1 "\3" CACHE \2 "")/' > "$W/init.cmake"

build_variant() {  # $1 ctl|mut: fetch, build GLFW, relink, stage
  local v="$1" d="$W/$1" skip=0 old link
  [ "$v" = mut ] && skip=1
  mkdir -p "$d"
  GLFW_SRC="$d/src" GLFW_GIT_URL="file://$ROOT/engine/third_party/glfw" RNI_GLFW_SKIP_SEAT_GUARD="$skip" \
    bash tools/glfw-fetch.sh --source-only > "$d/fetch.log" 2>&1 || die "$v: fetch failed ($d/fetch.log)"
  grep 'GLFW_SEAT_GUARD' "$d/fetch.log" | sed "s/^/   $v fetch: /"
  nice -n 10 cmake -S "$d/src" -B "$d/build" -G Ninja -C "$W/init.cmake" > "$d/cfg.log" 2>&1 || die "$v: GLFW configure ($d/cfg.log)"
  nice -n 10 cmake --build "$d/build" -j"$JOBS" > "$d/build.log" 2>&1 || die "$v: GLFW build ($d/build.log)"
  [ -f "$d/build/src/libglfw3.a" ] || die "$v: no libglfw3.a"
  link="$(ninja -C "$EB" -t commands rn-impeller | tail -1)"
  # x64 names the archive once, arm64 twice (CMake repeats it for link order).
  grep -qF " $GI/lib/libglfw3.a " <<< " $link " || die "the rn-impeller link line does not name $GI/lib/libglfw3.a"
  grep -qF ' -o rn-impeller ' <<< "$link" || die "the last ninja command is not the rn-impeller link"
  link="${link// $GI\/lib\/libglfw3.a / $d/build/src/libglfw3.a }"
  ! grep -qF "$GI/lib/libglfw3.a" <<< "$link" || die "the link line still names $GI/lib/libglfw3.a after the swap"
  link="${link/ -o rn-impeller / -o $d/rn-impeller }"
  (cd "$EB" && nice -n 10 bash -c "$link") > "$d/link.log" 2>&1 || die "$v: link failed ($d/link.log)"
  # Stage like engine-build-linux.sh: cmake --install's RPATH_CHANGE to $ORIGIN, then strip.
  cp -a "$PKG" "$d/pkg"; cp "$d/rn-impeller" "$d/pkg/rn-impeller"
  old="$(readelf -d "$d/rn-impeller" | sed -n 's/.*Library runpath: \[\(.*\)\]/\1/p')"
  printf 'file(RPATH_CHANGE FILE "%s" OLD_RPATH "%s" NEW_RPATH "$ORIGIN")\n' "$d/pkg/rn-impeller" "$old" \
    | sed 's/"\$ORIGIN"/"\\$ORIGIN"/' > "$d/rpath.cmake"
  cmake -P "$d/rpath.cmake" > /dev/null || die "$v: RPATH_CHANGE failed"
  "$STRIP" --strip-unneeded "$d/pkg/rn-impeller"; chmod 755 "$d/pkg/rn-impeller"
}
members_differing() {  # $1 $2 archives: names of members whose bytes differ
  local m
  for m in $("$AR" t "$1"); do
    cmp -s <("$AR" p "$1" "$m") <("$AR" p "$2" "$m") || echo "$m"
  done
}
gate() {  # $1 log name, $2 engine dir
  env "RNI_${TAG}_ENGINE_DIR=$2" bash tools/ci-arm64-wayland-touch.sh --arch "$ARCH" --only-no-seat > "$W/gate-$1.log" 2>&1
}
expect_killed() {  # $1 name, $2 engine dir, $3 ERE the FAIL line must match
  if gate "$1" "$2"; then
    echo "   $1: SURVIVED ($(tail -1 "$W/gate-$1.log"))"; fails=$((fails + 1))
  elif grep -qE "$3" "$W/gate-$1.log"; then
    echo "   $1: killed: $(grep -E "${TAG}_WAYLAND_TOUCH_FAIL" "$W/gate-$1.log" | tail -1)"
  else
    echo "   $1: killed, but not by /$3/: $(tail -1 "$W/gate-$1.log")"; fails=$((fails + 1))
  fi
}

echo "== control + M1 builds ($ARCH, scratch $W)"
build_variant ctl
build_variant mut
UNG='    if (wl_seat_get_version(_glfw.wl.seat) >= WL_KEYBOARD_REPEAT_INFO_SINCE_VERSION)'
[ "$(grep -cF "$UNG" "$W/ctl/src/src/wl_init.c")" -eq 0 ] || die "control source still has the unguarded call"
[ "$(grep -cF "$UNG" "$W/mut/src/src/wl_init.c")" -eq 1 ] || die "M1 source is not the unguarded GLFW 3.4"

echo "== instrument: the replay reproduces the real build"
D="$(members_differing "$W/ctl/build/src/libglfw3.a" "$GI/lib/libglfw3.a")"
[ -z "$D" ] || die "control libglfw3.a differs from $GI/lib/libglfw3.a in: $D (flag derivation drifted, or the build tree is stale)"
cmp -s "$W/ctl/rn-impeller" "$EB/rn-impeller" || die "replayed control link differs from $EB/rn-impeller (stale build tree?)"
cmp -s "$W/ctl/pkg/rn-impeller" "$PKG/rn-impeller" || die "control staged binary differs from $PKG/rn-impeller (restage: bash tools/engine-build.sh linux $ARCH)"
D="$(members_differing "$W/mut/build/src/libglfw3.a" "$W/ctl/build/src/libglfw3.a" | tr '\n' ' ')"
[ "$D" = "wl_init.c.o " ] || die "M1 archive should differ from control in wl_init.c.o only, differs in: ${D:-nothing}"
echo "   control archive, link and staged binary byte-identical to the real ones; M1 differs in wl_init.c.o only"

echo "== control: patched GLFW, no seat"
if gate control "$W/ctl/pkg"; then echo "   control: $(tail -1 "$W/gate-control.log")"
else echo "   control: FAILED ($(tail -1 "$W/gate-control.log"))"; fails=$((fails + 1)); fi

echo "== M1: GLFW fetched with the patch step skipped"
expect_killed M1 "$W/mut/pkg" "${TAG}_WAYLAND_TOUCH_FAIL: NS: engine exited 139"

echo "== M2: the session loads the touch module (Weston has a seat)"
python3 - "$SESS" <<'PY' || die "M2 anchor missing (mutant stale)"
import sys
p = sys.argv[1]; s = open(p).read(); old = '[ "$NOSEAT" = 1 ] && MODS=()'
assert s.count(old) == 1, f'anchor found {s.count(old)}x'
open(p, 'w').write(s.replace(old, ': # MUTANT M2: the touch module always loads'))
PY
touch "$SESS"
expect_killed M2 "$W/ctl/pkg" "${TAG}_WAYLAND_TOUCH_FAIL: NS: the compositor advertised a wl_seat"
restore
cmp -s "$W/session.orig" "$SESS" || die "$SESS differs from its pre-run copy after restore"

echo "== M3: a GLFW bump (fetch of GLFW master)"
if GLFW_SRC="$W/bump" GLFW_VERSION=master bash tools/glfw-fetch.sh --source-only > "$W/fetch-bump.log" 2>&1; then
  echo "   M3: SURVIVED (the fetch accepted GLFW master: $(tail -1 "$W/fetch-bump.log"))"; fails=$((fails + 1))
elif grep -q 'GLFW_SEAT_GUARD_FAIL: .* neither applies' "$W/fetch-bump.log"; then
  echo "   M3: killed: $(grep -m1 'GLFW_SEAT_GUARD_FAIL' "$W/fetch-bump.log" | cut -c1-110)..."
else
  echo "   M3: fetch failed, but not with GLFW_SEAT_GUARD_FAIL: $(tail -2 "$W/fetch-bump.log" | tr '\n' ' ')"; fails=$((fails + 1))
fi

trap - EXIT
if [ "$fails" -eq 0 ]; then
  echo "MUTATION_GLFW_SEAT_PASS ($ARCH: M1 exit 139, M2 seat oracle, M3 bump refused; control green and byte-identical; logs $W)"
  exit 0
fi
echo "MUTATION_GLFW_SEAT_FAIL ($ARCH: $fails wrong; logs $W)"; exit 1
