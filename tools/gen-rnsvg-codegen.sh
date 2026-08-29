#!/usr/bin/env bash
# P9-B — generate react-native-svg's Fabric codegen output.
#
# WHY THIS EXISTS
#
# react-native-svg ships `common/cpp/.../rnsvg/` (the shadow-node templates
# and component-descriptor typedefs) but NOT the codegen output those headers
# #include -- `react/renderer/components/rnsvg/Props.h`, `EventEmitters.h`,
# `States.h`, `ShadowNodes.h`. On Android that is generated into the gradle
# build dir; on iOS into the pod. We have neither.
#
# So we run react-native's own codegen, a pure-JS tool that ships in the npm
# package and needs no gradle, no Android SDK, no Xcode.
#
# ⚠️ WHY `-t android` AND NOT `ios`, GIVEN THAT JS PICKS THE iOS LEAF
#
# Svg.js does `Platform.OS === 'android' ? RNSVGSvgAndroid : RNSVGSvgIOS`, so
# on our platform the mounted root is `RNSVGSvgView` (the iOS one). It would
# be natural to generate for `ios` to match. Do NOT: the iOS generator emits
# ObjC++ (`.mm`, `RCTComponentViewHelpers.h`), while the ANDROID generator
# emits the platform-neutral C++ we want -- and it is a SUPERSET, containing
# BOTH `RNSVGSvgViewProps` and `RNSVGSvgViewAndroidProps`. The
# `excludedPlatforms: ['android']` on the iOS spec excludes it from Android's
# *view manager*, not from the C++ prop generation.
#
# This is solved prior art -- verbatim reasoning and structure from
# ~/projects/rn-skia-prototype/tools/gen-rnsvg-codegen.sh (that repo
# is read-only reference for us; this script is our own copy, adapted to
# this engine's paths).
#
# The generated tree is COMMITTED (under engine/svg/generated/) for the same
# reason: a build that silently depends on a node_modules-derived generator
# step is a build that breaks on a fresh clone.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)

RN="$ROOT/engine/rn/node_modules/react-native"
SVG="$ROOT/engine/rn/node_modules/react-native-svg"
DEST="$ROOT/engine/svg/generated"

[ -d "$RN/scripts" ]     || { echo "gen-rnsvg: react-native not found at $RN" >&2; exit 1; }
[ -d "$SVG/src/fabric" ] || { echo "gen-rnsvg: react-native-svg not found at $SVG" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# `-s library` makes the generator read the package's own codegenConfig
# (name: rnsvg, jsSrcsDir: ./src/fabric) instead of scanning an app's deps.
node "$RN/scripts/generate-codegen-artifacts.js" \
  -p "$(realpath "$SVG")" -t android -o "$TMP" -s library >"$TMP/gen.log" 2>&1 || {
    echo "gen-rnsvg: codegen failed"; cat "$TMP/gen.log"; exit 1; }

SRC="$TMP/android/app/build/generated/source/codegen/jni/react/renderer/components/rnsvg"
[ -f "$SRC/Props.h" ] || {
  echo "gen-rnsvg: codegen produced no Props.h (layout changed?)"; cat "$TMP/gen.log"; exit 1; }

# ⛔ Refuse to commit anything with JNI in it. This keeps the "it's portable
# C++" claim honest across a vendor bump, rather than a comment asserting it
# once.
if grep -rqE 'JNIEnv|fbjni|<jni\.h>|#import' "$SRC"; then
  echo "gen-rnsvg: FAIL -- generated sources contain JNI/ObjC:"
  grep -rlE 'JNIEnv|fbjni|<jni\.h>|#import' "$SRC"
  exit 1
fi

OUTDIR="$DEST/react/renderer/components/rnsvg"
mkdir -p "$OUTDIR"
# Only the platform-neutral Fabric files. Deliberately NOT rnsvg.h /
# rnsvg-generated.cpp / rnsvgJSI.h -- those are the JNI TurboModule wrapper
# for NativeSvgRenderableModule (getBBox/getPointAtLength etc.), which
# nothing in the SVG paint path calls.
for f in Props.h Props.cpp EventEmitters.h EventEmitters.cpp \
         States.h States.cpp ShadowNodes.h ShadowNodes.cpp \
         ComponentDescriptors.h ComponentDescriptors.cpp; do
  cp "$SRC/$f" "$OUTDIR/$f"
done

echo "gen-rnsvg: wrote $(ls "$OUTDIR" | wc -l) files to $OUTDIR"
