#!/usr/bin/env bash
# Build Hermes at the EXACT tag react-native pins, and nothing else.
#
# The tag is read from the pinned RN package (engine/rn/node_modules/react-native/
# sdks/.hermesversion) rather than hardcoded here. Hermes bytecode is versioned:
# a runtime built from a different Hermes than the one RN expects loads a bundle
# and fails at a layer that looks like a bundler problem. Deriving the tag from
# RN itself makes an RN bump carry its own Hermes bump.
#
# HERMES_SEED_SRC: optional path to an existing hermes checkout at the same tag,
# copied instead of cloned. Purely a network shortcut -- the tag is verified
# after the copy, so a seed at the wrong tag is rejected rather than used.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RN="$ROOT/engine/rn/node_modules/react-native"
[ -f "$RN/sdks/.hermesversion" ] || {
  echo "hermes-build: FAIL: $RN not installed. Run: (cd engine/rn && npm install --ignore-scripts)" >&2
  exit 1
}
TAG="$(cat "$RN/sdks/.hermesversion")"     # e.g. hermes-v0.17.0
VER="${TAG#hermes-}"                        # e.g. v0.17.0
SRC="$ROOT/engine/third_party/hermes"
BUILD="$ROOT/engine/third_party/hermes-build"

if [ ! -d "$SRC/.git" ]; then
  if [ -n "${HERMES_SEED_SRC:-}" ] && [ -d "${HERMES_SEED_SRC}/.git" ]; then
    echo "hermes-build: seeding from ${HERMES_SEED_SRC}"
    cp -a "${HERMES_SEED_SRC}" "$SRC"
  else
    git clone --depth 1 --branch "$VER" https://github.com/facebook/hermes.git "$SRC" \
      || git clone --depth 1 --branch "$TAG" https://github.com/facebook/hermes.git "$SRC"
  fi
fi

# Verify the checkout is actually the pinned tag. A seeded or stale tree at the
# wrong version produces a runtime that mis-reads RN's bytecode, and that failure
# surfaces far from here.
DESC="$(git -C "$SRC" describe --tags --always 2>/dev/null || echo unknown)"
case "$DESC" in
  *"$VER"*) : ;;
  *) echo "hermes-build: FAIL: $SRC is at '$DESC', expected $VER (RN pins $TAG)" >&2; exit 1 ;;
esac

# HERMES_ENABLE_DEBUGGER=ON is required for the CDP inspector later (P6-class
# work). It is set now because turning it on afterwards means a full rebuild.
cmake -S "$SRC" -B "$BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DHERMES_ENABLE_DEBUGGER=ON \
  -DHERMES_BUILD_SHARED_JSI=OFF \
  -DHERMES_ENABLE_TEST_SUITE=OFF
cmake --build "$BUILD" -j"$(nproc)" --target hermesvm hermesc
echo "hermes-build: OK -> $BUILD ($VER)"
