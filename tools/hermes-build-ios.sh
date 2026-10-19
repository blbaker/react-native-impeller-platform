#!/usr/bin/env bash
# iOS Phase 1 (Task 1.6): Hermes for iOS, staged for the iOS CMake branch as
#   engine/third_party/hermes-ios/hermesvm.xcframework   (ios-arm64 + ios-arm64_x86_64-simulator)
#   engine/third_party/hermes-ios/include/                (hermes/, jsi/ API headers)
#   engine/third_party/hermes-ios/.stamp
#   bash tools/hermes-build-ios.sh        (on linux: RNI_MAC_HOST=<ssh host> runs it on a Mac)
#
# Same tag rule as tools/hermes-build.sh: the tag RN pins
# (engine/rn/node_modules/react-native/sdks/.hermesversion), verified against
# the checkout. Built with Hermes's OWN Apple packaging functions
# (utils/build-apple-framework.sh: build_host_hermesc + build_apple_framework),
# the path RN's hermes-engine pod takes (docs/eng/ios-platform.md).
# Hermes builds in-tree (build_<platform>/, destroot/), so the checkout is
# COPIED to RNI_HERMES_IOS_WORK (default ~/Library/Caches/rni-hermes-ios) and
# the source (possibly a shared checkout) is never written.
# BUILD_TYPE=Debug = Release cmake + the debugger on, as RN debug builds and
# this repo's desktop Hermes (HERMES_ENABLE_DEBUGGER=ON).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$(uname -s)" != Darwin ]; then
  [ -n "${RNI_MAC_HOST:-}" ] || { echo "hermes-build-ios: macOS only (from linux: RNI_MAC_HOST=<ssh host>)" >&2; exit 2; }
  RNI_MAC_TREE="${RNI_MAC_TREE:-rni-ios}" RNI_MAC_ENV="RNI_HERMES_IOS_WORK" \
    exec bash "$ROOT/tools/mac-run.sh" bash tools/hermes-build-ios.sh "$@"
fi
cd "$ROOT"
say() { echo "[hermes-build-ios] $*"; }
die() { say "FAIL: $*" >&2; exit 1; }
RN="$ROOT/engine/rn/node_modules/react-native"
[ -f "$RN/sdks/.hermesversion" ] || die "$RN not installed (engine/rn npm install)"
TAG="$(cat "$RN/sdks/.hermesversion")"
VER="${TAG#hermes-}"
SRC="$ROOT/engine/third_party/hermes"
DEST="$ROOT/engine/third_party/hermes-ios"
WORK="${RNI_HERMES_IOS_WORK:-$HOME/Library/Caches/rni-hermes-ios}"
H="$WORK/src"
IOS_MIN=15.1

desc() { git -C "$1" describe --tags --always 2> /dev/null || echo unknown; }
case "$(desc "$SRC")" in *"$VER"*) : ;; *) die "$SRC is at '$(desc "$SRC")', expected $VER (RN pins $TAG)" ;; esac
# ⛔ engine/third_party/hermes may be a SYMLINK to a shared checkout, and
# `cp -a` copies a symlink as a symlink: a build would then write GBs of
# build_*/destroot into that checkout. Copy the resolved directory, and refuse
# to build anywhere that resolves to the source.
SRC_REAL="$(cd "$SRC" && pwd -P)"
[ -L "$H" ] && rm -f "$H"
case "$(desc "$H")" in
  *"$VER"*) say "reusing $H ($(desc "$H"))" ;;
  *) say "copying $SRC_REAL -> $H"; rm -rf "$H"; mkdir -p "$WORK"; cp -a "$SRC_REAL" "$H"; rm -rf "$H"/build_* "$H/destroot" ;;
esac
[ ! -L "$H" ] && [ "$(cd "$H" && pwd -P)" != "$SRC_REAL" ] || die "$H resolves to the source tree; refusing to build in it"

# nvm node (Hermes reads its version with node); system dirs before Homebrew
# (brew's python3.14 has a broken pyexpat); Homebrew for cmake.
N=$(ls -d "$HOME"/.nvm/versions/node/v2[2-9]*/bin 2> /dev/null | tail -1)
export PATH="$N:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
export IOS_DEPLOYMENT_TARGET=$IOS_MIN BUILD_TYPE=Debug
cd "$H"
set +eu  # Hermes's script reads unset variables (JSI_PATH, ...); artefacts are checked instead
# shellcheck source=/dev/null
source "$H/utils/build-apple-framework.sh"
t0=$SECONDS
# Its functions end in popd, so their exit status hides a failed build: check
# the artefact each one must produce.
build_host_hermesc_if_needed > "$WORK/host.log" 2>&1
[ -x "$H/build_host_hermesc/bin/hermesc" ] || { tail -20 "$WORK/host.log"; die "host hermesc"; }
for P in iphoneos iphonesimulator; do
  case $P in iphoneos) ARCHS="arm64" ;; *) ARCHS="x86_64;arm64" ;; esac  # build-ios-framework.sh's
  rm -rf "$H/destroot/Library/Frameworks/$P"
  build_apple_framework "$P" "$ARCHS" "$IOS_MIN" > "$WORK/$P.log" 2>&1
  [ -f "$H/destroot/Library/Frameworks/$P/hermesvm.framework/hermesvm" ] || { tail -20 "$WORK/$P.log"; die "$P framework"; }
  say "$P: $(lipo -archs "$H/destroot/Library/Frameworks/$P/hermesvm.framework/hermesvm")"
done
set -eu

TMP="$(mktemp -d "$ROOT/engine/third_party/.hermes-ios.XXXXXX")"
xcodebuild -create-xcframework \
  -framework "$H/destroot/Library/Frameworks/iphoneos/hermesvm.framework" \
  -framework "$H/destroot/Library/Frameworks/iphonesimulator/hermesvm.framework" \
  -output "$TMP/hermesvm.xcframework" > "$WORK/xcf.log" 2>&1 || { cat "$WORK/xcf.log"; die "create-xcframework"; }
cp -R "$H/destroot/include" "$TMP/include"
SIM=$(ls -d "$TMP"/hermesvm.xcframework/ios-*simulator/hermesvm.framework | head -1)
nm -gUC "$SIM/hermesvm" > "$WORK/nm.txt" 2> /dev/null || true   # to a file: nm | grep SIGPIPEs
grep -q 'facebook::hermes::makeHermesRuntime' "$WORK/nm.txt" || die "makeHermesRuntime not exported"
printf 'tag=%s\nbuild_type=%s\nios_min=%s\nslices=%s\n' "$TAG" "$BUILD_TYPE" "$IOS_MIN" \
  "$(ls "$TMP/hermesvm.xcframework" | grep ios- | tr '\n' ' ')" > "$TMP/.stamp"
rm -rf "$DEST"; mv "$TMP" "$DEST"
say "built in $((SECONDS - t0))s -> $DEST ($(du -sh "$DEST/hermesvm.xcframework" | cut -f1))"
echo "HERMES_BUILD_IOS_OK $DEST"
