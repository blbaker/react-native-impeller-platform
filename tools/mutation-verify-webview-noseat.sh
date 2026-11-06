#!/usr/bin/env bash
# Mutation check for the no-seat fix through the web view gate: the noseat arm
# of tools/ci-webview-arm64.sh and the patch step in tools/glfw-fetch.sh
# (tools/glfw-patches/0001). Written on feat/webview-wpe as
# mutation-verify-glfw-seat.sh; renamed when feat/linux-arm64 merged it, because
# that branch's script of the same name drives the NS arm of
# ci-arm64-wayland-touch.sh (x64 + arm64). This one is arm64 only.
#
#   control  GLFW from a normal fetch (patch applied), built with the flags read
#            from engine/build-linux-arm64/glfw, linked by replaying ninja's own
#            rn-impeller link line, staged like engine-build-linux-arm64.sh does
#            -> noseat PASSES, and the archive, the link and the staged binary
#            are byte-identical to the real ones (the replay is faithful)
#   M1       the same pipeline from a fetch with the patch step skipped
#            (RNI_GLFW_SKIP_SEAT_GUARD=1); only wl_init.c.o differs
#            -> noseat FAILS: engine exit 139 (SIGSEGV in glfwInit)
#   M2       the noseat arm loads rni-touch-inject anyway, so Weston HAS a seat
#            -> noseat FAILS on its seat-less precondition (the WAYLAND_DEBUG oracle)
#   M3       a GLFW bump: glfw-fetch.sh --source-only on GLFW master (needs GitHub)
#            -> the fetch FAILS loudly (GLFW_SEAT_GUARD_FAIL), it does not build
#               a GLFW without the fix
#
# It builds nothing in the worktree's build trees and never restages
# packages-engine/: every mutant binary lives in a scratch dir and reaches the
# gate through RNI_ARM64_ENGINE_DIR. Needs a current build:
# bash tools/engine-build-linux-arm64.sh first.
#
# Usage: bash tools/mutation-verify-webview-noseat.sh
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
export PATH="$HOME/.local/bin:$PATH"
export RNI_ARM64_SYSROOT="${RNI_ARM64_SYSROOT:-$ROOT/engine/third_party/sysroot-linux-arm64}"
JOBS="${JOBS:-10}"
B="$ROOT/engine/build-linux-arm64"; EB="$B/engine"
GB="$B/glfw"; GI="$B/glfw-install"; PKG="$ROOT/packages-engine/engine-linux-arm64/bin"
GATE=tools/ci-webview-arm64.sh
W="$(mktemp -d "${TMPDIR:-/tmp}/mut-glfw-seat-webview.XXXXXX")"
die() { echo "MUTATION_GLFW_SEAT_FAIL (webview arm64): $*"; exit 1; }
fails=0
for f in "$GB/CMakeCache.txt" "$GI/lib/libglfw3.a" "$EB/build.ninja" "$EB/rn-impeller" "$PKG/rn-impeller"; do
  [ -e "$f" ] || die "missing $f (bash tools/engine-build-linux-arm64.sh)"
done
cp "$GATE" "$W/gate.orig"
restore() { cp "$W/gate.orig" "$GATE"; touch "$GATE"; }
trap restore EXIT
cache() { grep -E "^$1:" "$2" | head -1 | cut -d= -f2-; }
AR="$(cache CMAKE_AR "$GB/CMakeCache.txt")"
STRIP="$(cache CMAKE_STRIP "$EB/CMakeCache.txt")"
[ -x "$AR" ] || die "no archiver from $GB/CMakeCache.txt"
[ -x "$STRIP" ] || die "no strip from $EB/CMakeCache.txt"

# The GLFW flags come from the real GLFW build tree, not from a copy of
# engine-build-linux-arm64.sh: every user-settable cache entry, minus its own dirs.
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
  grep -qF " $GI/lib/libglfw3.a " <<< " $link " || die "the rn-impeller link line does not name $GI/lib/libglfw3.a"
  grep -qF ' -o rn-impeller ' <<< "$link" || die "the last ninja command is not the rn-impeller link"
  link="${link// $GI\/lib\/libglfw3.a / $d/build/src/libglfw3.a }"
  ! grep -qF "$GI/lib/libglfw3.a" <<< "$link" || die "the link line still names $GI/lib/libglfw3.a after the swap"
  link="${link/ -o rn-impeller / -o $d/rn-impeller }"
  (cd "$EB" && nice -n 10 bash -c "$link") > "$d/link.log" 2>&1 || die "$v: link failed ($d/link.log)"
  # Stage like engine-build-linux-arm64.sh: cmake --install's RPATH_CHANGE to $ORIGIN, then strip.
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
  env "RNI_ARM64_ENGINE_DIR=$2" ARMS=noseat bash "$GATE" > "$W/gate-$1.log" 2>&1
}
expect_killed() {  # $1 name, $2 engine dir, $3 ERE the FAIL line must match
  if gate "$1" "$2"; then
    echo "   $1: SURVIVED ($(tail -1 "$W/gate-$1.log"))"; fails=$((fails + 1))
  elif grep -qE "$3" "$W/gate-$1.log"; then
    echo "   $1: killed: $(grep -E 'WEBVIEW_ARM64_FAIL' "$W/gate-$1.log" | tail -1)"
  else
    echo "   $1: killed, but not by /$3/: $(tail -1 "$W/gate-$1.log")"; fails=$((fails + 1))
  fi
}

echo "== control + M1 builds (arm64, scratch $W)"
build_variant ctl
build_variant mut
UNG='    if (wl_seat_get_version(_glfw.wl.seat) >= WL_KEYBOARD_REPEAT_INFO_SINCE_VERSION)'
[ "$(grep -cF "$UNG" "$W/ctl/src/src/wl_init.c")" -eq 0 ] || die "control source still has the unguarded call"
[ "$(grep -cF "$UNG" "$W/mut/src/src/wl_init.c")" -eq 1 ] || die "M1 source is not the unguarded GLFW 3.4"

echo "== instrument: the replay reproduces the real build"
D="$(members_differing "$W/ctl/build/src/libglfw3.a" "$GI/lib/libglfw3.a")"
[ -z "$D" ] || die "control libglfw3.a differs from $GI/lib/libglfw3.a in: $D (flag derivation drifted, or the build tree is stale)"
cmp -s "$W/ctl/rn-impeller" "$EB/rn-impeller" || die "replayed control link differs from $EB/rn-impeller (stale build tree?)"
cmp -s "$W/ctl/pkg/rn-impeller" "$PKG/rn-impeller" || die "control staged binary differs from $PKG/rn-impeller (restage: bash tools/engine-build-linux-arm64.sh)"
D="$(members_differing "$W/mut/build/src/libglfw3.a" "$W/ctl/build/src/libglfw3.a" | tr '\n' ' ')"
[ "$D" = "wl_init.c.o " ] || die "M1 archive should differ from control in wl_init.c.o only, differs in: ${D:-nothing}"
echo "   control archive, link and staged binary byte-identical to the real ones; M1 differs in wl_init.c.o only"
echo "   control $(sha256sum "$W/ctl/pkg/rn-impeller" | cut -c1-12), M1 $(sha256sum "$W/mut/pkg/rn-impeller" | cut -c1-12)"

echo "== control: patched GLFW, no seat"
if gate control "$W/ctl/pkg"; then echo "   control: $(grep 'noseat pass' "$W/gate-control.log" | sed 's/^ *//')"
else echo "   control: FAILED ($(tail -1 "$W/gate-control.log"))"; fails=$((fails + 1)); fi

echo "== M1: GLFW fetched with the patch step skipped"
expect_killed M1 "$W/mut/pkg" "WEBVIEW_ARM64_FAIL: noseat: engine exited 139"

echo "== M2: the noseat arm loads the touch module (Weston has a seat)"
python3 - "$GATE" <<'PY' || die "M2 anchor missing (mutant stale)"
import sys
p = sys.argv[1]; s = open(p).read()
old = 'then dock=(--ulimit core=0); else envs+=(-e TOUCH_MODULE="$MOD"); fi'
new = 'then dock=(--ulimit core=0); fi; envs+=(-e TOUCH_MODULE="$MOD")  # MUTANT M2: the touch module always loads'
assert s.count(old) == 1, f'anchor found {s.count(old)}x'
open(p, 'w').write(s.replace(old, new))
PY
touch "$GATE"
expect_killed M2 "$W/ctl/pkg" "WEBVIEW_ARM64_FAIL: noseat: the compositor advertised a wl_seat"
restore
cmp -s "$W/gate.orig" "$GATE" || die "$GATE differs from its pre-run copy after restore"

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
  echo "MUTATION_GLFW_SEAT_PASS (webview arm64: M1 exit 139, M2 seat oracle, M3 bump refused; control green and byte-identical; logs $W)"
  exit 0
fi
echo "MUTATION_GLFW_SEAT_FAIL (webview arm64: $fails wrong; logs $W)"; exit 1
