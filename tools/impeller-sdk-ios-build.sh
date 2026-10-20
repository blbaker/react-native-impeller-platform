#!/usr/bin/env bash
# iOS Phase 1: build the Impeller interop STATIC library for the iOS Simulator
# (arm64) on the Mac, from the pinned engine (engine/IMPELLER_SHA) plus
# engine/impeller-sdk-patches/*.patch and engine/impeller-sdk-patches/ios/*.patch,
# staged as <dest> (default engine/third_party/impeller-sdk-ios-simulator-arm64):
#   include/impeller.h, include/impeller.hpp, lib/libimpeller.a (without
#   Flutter's C++ exception runtime; see below),
#   lib/exports.txt (the exported Impeller* C functions), .stamp
#   bash tools/impeller-sdk-ios-build.sh [dest]          (darwin; from linux: tools/sdk-fetch-ios.sh)
# Env: RNI_SDK_WORK  the checkout tools/impeller-sdk-custom-build.sh synced on this Mac
#                    (same default, ~/projects/_ref/sc32). Never re-synced here.
#      RNI_SDK_POST_PATCH  shell command run in the patched interop dir (mutants)
#
# Why not the :sdk zip like every other target: flutter/BUILD.gn:172 adds
# interop:sdk only for mac/linux/win/android/qnx, so for iOS the interop BUILD.gn
# is never loaded. Instead of patching the graph, a GN dotfile kept OUTSIDE the
# checkout loads the interop BUILD.gn as the root (docs/eng/ios-platform.md).
# ios/0006 only adds #if IMPELLER_ENABLE_OPENGLES / _VULKAN guards that iOS (both
# off) needs; it lives in ios/ so the other targets' patch sums do not change.
#
# ⛔ Reset + re-apply on EVERY run, as impeller-sdk-custom-build.sh does: a
# mutation run leaves its mutant in the checkout (an early iOS build picked up a
# leftover "no wait for the blit" mutant in surface.cc and its readback raced).
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
[ "$(uname -s)" = Darwin ] || { echo "impeller-sdk-ios: darwin only (from linux: tools/sdk-fetch-ios.sh)" >&2; exit 2; }
SHA="$(tr -d ' \n' < engine/IMPELLER_SHA)"
DEST="${1:-engine/third_party/impeller-sdk-ios-simulator-arm64}"
WORK="${RNI_SDK_WORK:-$HOME/projects/_ref/sc32}"
F="$WORK/flutter"
SRC="$F/engine/src"
OUT=rni_ios_sim_debug_arm64           # flutter/tools/gn's own out dir (args.gn)
OUTI=rni_ios_sim_interop_arm64        # same args, interop BUILD.gn as the root
say() { echo "[impeller-sdk-ios] $*"; }
die() { say "FAIL: $*" >&2; exit 1; }

[ "$(git -C "$F" rev-parse HEAD 2> /dev/null)" = "$SHA" ] && [ "$(cat "$WORK/.synced" 2> /dev/null)" = "$SHA" ] \
  || die "$F is not a synced checkout of $SHA (run tools/impeller-sdk-custom-build.sh on the Mac)"
# System python3 before Homebrew's (brew python3.14's pyexpat is broken); brew
# before depot_tools (its ninja wrapper refuses to run without a bootstrap).
export PATH="$WORK/shim:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:$WORK/depot_tools"
export DEPOT_TOOLS_UPDATE=0 GCLIENT_SUPPRESS_GIT_VERSION_WARNING=1

PATCHES=("$REPO"/engine/impeller-sdk-patches/*.patch "$REPO"/engine/impeller-sdk-patches/ios/*.patch)
PATCH_SUM="$(cat "${PATCHES[@]}" | shasum -a 256 | cut -c1-64)"
INTEROP=engine/src/flutter/impeller/toolkit/interop
git -C "$F" checkout -q -- "$INTEROP" $(sed -n 's|^+++ b/||p' "${PATCHES[@]}" | sort -u)
for p in "${PATCHES[@]}"; do git -C "$F" apply "$p" || die "patch $(basename "$p") does not apply"; done
[ -z "${RNI_SDK_POST_PATCH:-}" ] || (cd "$F/$INTEROP" && eval "$RNI_SDK_POST_PATCH")
say "patched: ${#PATCHES[@]} patches, sum ${PATCH_SUM:0:16}"

if [ ! -f "$SRC/out/$OUT/args.gn" ]; then
  (cd "$SRC" && ./flutter/tools/gn --target-dir "$OUT" --ios --simulator --simulator-cpu arm64 \
    --runtime-mode debug --prebuilt-dart-sdk --no-lto --no-rbe --no-goma > "$WORK/gn-ios.log" 2>&1) \
    || { tail -15 "$WORK/gn-ios.log"; die "gn --ios"; }
fi
DOT="$WORK/rni-ios-interop.gn"
{ cat "$SRC/.gn"; echo 'root = "//flutter/impeller/toolkit/interop:static_library"'; } > "$DOT.new"
cmp -s "$DOT.new" "$DOT" 2> /dev/null && rm "$DOT.new" || mv "$DOT.new" "$DOT"
if [ ! -f "$SRC/out/$OUTI/build.ninja" ] || ! cmp -s "$SRC/out/$OUT/args.gn" "$SRC/out/$OUTI/args.gn"; then
  mkdir -p "$SRC/out/$OUTI" && cp "$SRC/out/$OUT/args.gn" "$SRC/out/$OUTI/args.gn"
  (cd "$SRC" && flutter/third_party/gn/gn gen "out/$OUTI" --root=. --dotfile="$DOT" > "$WORK/gn-ios-interop.log" 2>&1) \
    || { tail -15 "$WORK/gn-ios-interop.log"; die "gn gen (interop root)"; }
fi

say "ninja (log $WORK/build-ios.log)"
t0=$(date +%s)
ninja -C "$SRC/out/$OUTI" -j "$(getconf _NPROCESSORS_ONLN)" flutter/impeller/toolkit/interop:static_library \
  > "$WORK/build-ios.log" 2>&1 || { grep -m5 -A8 FAILED "$WORK/build-ios.log"; die "ninja"; }
secs=$(( $(date +%s) - t0 ))
LIB="$SRC/out/$OUTI/obj/flutter/impeller/toolkit/interop/libimpeller.a"
[ -f "$LIB" ] || die "no $LIB"

mkdir -p "$(dirname "$DEST")"
TMP="$(mktemp -d "$(dirname "$DEST")/.sdk-ios.XXXXXX")"
mkdir -p "$TMP/include" "$TMP/lib"
cp "$SRC/flutter/impeller/toolkit/interop/impeller.h" "$SRC/flutter/impeller/toolkit/interop/impeller.hpp" "$TMP/include/"
cp -c "$LIB" "$TMP/lib/libimpeller.a" 2> /dev/null || cp "$LIB" "$TMP/lib/libimpeller.a"  # APFS clone
# ⛔ ONE C++ EXCEPTION RUNTIME PER APP. The archive carries Flutter's own
# libc++abi (libcxxabi.*.o: __cxa_throw, __cxa_begin_catch, __cxa_rethrow,
# __gxx_personality_v0, std::terminate, std::exception's typeinfo) and, in
# libcxx.exception.o, its own std::current_exception / std::rethrow_exception /
# std::exception_ptr, built WITHOUT exception support. Linked into an app, an
# archive member wins over the system library for every symbol it defines, so
# engine code captured and re-threw exceptions through those copies while
# Hermes (a framework) throws through the system's. Measured: a re-thrown
# std::runtime_error ends in "terminating due to uncaught exception" even with
# a catch right beside it, and a throwing requestAnimationFrame callback
# crashed the app instead of reaching RN's error handler. Flutter's libc++
# proper is namespaced std::__fl and stays; everything dropped here is
# un-namespaced, and the system libc++ / libc++abi export all of it (an app
# links -lc++abi).
ABI_MEMBERS=$(ar -t "$TMP/lib/libimpeller.a" | grep -E '^(libcxxabi\..*|libcxx\.exception\.o)$' || true)
[ -n "$ABI_MEMBERS" ] && ar -d "$TMP/lib/libimpeller.a" $ABI_MEMBERS
ranlib "$TMP/lib/libimpeller.a" 2> /dev/null || true
nm -gU "$TMP/lib/libimpeller.a" 2> /dev/null > "$TMP/nm.txt" || true   # to a file: nm | grep SIGPIPEs
LEFT=$(grep -cE ' T (___cxa_(throw|rethrow|begin_catch|end_catch|current_primary_exception)|___gxx_personality_v0|__ZSt9terminatev|__ZSt17current_exceptionv|__ZSt17rethrow_exceptionSt13exception_ptr)$' "$TMP/nm.txt" || true)
[ "${LEFT:-0}" = 0 ] || die "libimpeller.a still defines $LEFT C++ exception-runtime symbols"
say "dropped $(echo "$ABI_MEMBERS" | grep -c . || true) C++ exception-runtime members (the system's is the only one)"
sed -nE 's/^[0-9a-f]+ T _(Impeller[A-Za-z0-9_]+)$/\1/p' "$TMP/nm.txt" | sort -u > "$TMP/lib/exports.txt"
rm -f "$TMP/nm.txt"
printf 'sha=%s\npatch_sha256=%s\ntarget=ios-simulator-arm64\nbuild_seconds=%s\n' "$SHA" "$PATCH_SUM" "$secs" > "$TMP/.stamp"
chmod 755 "$TMP"; rm -rf "$DEST"; mv "$TMP" "$DEST"
say "built in ${secs}s -> $DEST ($(du -h "$DEST/lib/libimpeller.a" | cut -f1), $(wc -l < "$DEST/lib/exports.txt" | tr -d ' ') exports)"
echo "IMPELLER_SDK_IOS_OK $DEST"
