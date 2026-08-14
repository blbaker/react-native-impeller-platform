#!/usr/bin/env bash
# Build the rn-impeller engine host and stage it into a per-platform npm package
# under packages-engine/engine-<platform>-<arch>/.
#
# The package is self-contained: engine binary + libimpeller.so + libhermesvm.so,
# with an rpath of $ORIGIN so the binary finds its libraries wherever npm unpacks
# it. A binary that only runs from the build tree is not a shippable package.
#
# ⚠️ THIS SCRIPT IS THE ONLY THING THAT PRODUCES THE GATED BINARY. It used to
# compile host/main.cpp with a standalone g++ line, and when the engine became a
# CMake project that line kept working — it just built a DIFFERENT, older
# program, so the consumer gate went green against an engine that no longer
# reflected the source tree. Anything that builds the engine must go through
# CMake here.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

# ⛔ THE TRIPLE IS node's `process.platform`-`process.arch`, NOT a friendly name.
# `resolve.js` computes the package name from those values at runtime, so the
# directory here must be `win32-x64` and never `windows-x64`: a mismatch produces
# a package that publishes fine, installs fine, and can never be found.
PLATFORM="${1:-linux}"
ARCH="${2:-x64}"
case "${PLATFORM}" in
  windows|win) PLATFORM=win32 ;;
esac
TRIPLE="${PLATFORM}-${ARCH}"
PKG="packages-engine/engine-${TRIPLE}"
VERSION="$(node -p "require('${ROOT}/package/package.json').version")"

case "${PLATFORM}" in
  linux) ;;
  win32) exec bash tools/engine-build-win-stage.sh "${ARCH}" ;;
  *) echo "engine-build: ${PLATFORM} is not supported yet (P6=macos)" >&2; exit 1 ;;
esac

SDK="${IMPELLER_SDK:-engine/third_party/impeller-sdk}"
[ -f "${SDK}/include/impeller.h" ] || bash tools/sdk-fetch.sh "${SDK}"
[ -f "engine/third_party/hermes-build/lib/libhermesvm.so" ] || bash tools/hermes-build.sh
[ -d "engine/rn/node_modules/react-native" ] || (cd engine/rn && npm install --ignore-scripts --no-audit --no-fund)

echo "engine-build: configuring + compiling ${TRIPLE} host (cmake)"
cmake -S engine -B engine/build -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="${ROOT}/${PKG}" > /dev/null
cmake --build engine/build -j"$(nproc)" --target rn-impeller

# `cmake --install` (not cp) — it rewrites the rpath from the build tree's
# absolute paths to $ORIGIN and stages libimpeller.so + libhermesvm.so with it.
# --component engine is REQUIRED: without it CMake also runs the install rules
# of every FetchContent'd dependency (glog, fmt, ...) and their headers end up
# inside the shipped package.
rm -rf "${PKG}/bin" "${PKG}/include" "${PKG}/lib" "${PKG}/share"
cmake --install engine/build --component engine > /dev/null
strip --strip-unneeded "${PKG}/bin/rn-impeller" 2>/dev/null || true

# The package must contain the payload and NOTHING ELSE. A dependency that
# quietly adds an install rule would otherwise ship its whole header tree to
# every consumer, and npm pack would not complain.
STRAY="$(cd "${PKG}" && ls -A | grep -vE '^(bin|package\.json|README\.md)$' || true)"
[ -z "$STRAY" ] || { echo "engine-build: FAIL — stray files staged into the package:"; echo "$STRAY"; exit 1; }
STRAY_BIN="$(cd "${PKG}/bin" && ls -A | grep -vE '^(rn-impeller|libimpeller\.so|libhermesvm\.so)$' || true)"
[ -z "$STRAY_BIN" ] || { echo "engine-build: FAIL — stray files in bin/:"; echo "$STRAY_BIN"; exit 1; }

# Prove the staged binary runs on its OWN libraries, not the build tree's. A
# missing rpath only shows up once the package leaves this machine, which is
# exactly the failure the consumer gate exists to prevent.
MISSING="$(cd "${PKG}/bin" && ldd ./rn-impeller | grep 'not found' || true)"
[ -z "$MISSING" ] || { echo "engine-build: FAIL — staged binary has unresolved libs:"; echo "$MISSING"; exit 1; }
# ...and prove it is genuinely $ORIGIN-relative rather than accidentally
# resolving through the build tree that is still on this disk.
if readelf -d "${PKG}/bin/rn-impeller" | grep -qE 'R(UN)?PATH.*engine/build'; then
  echo "engine-build: FAIL — staged binary still has build-tree rpath" >&2
  readelf -d "${PKG}/bin/rn-impeller" | grep -E 'R(UN)?PATH' >&2
  exit 1
fi

# R3 size budget: <60 MB unpacked per platform. Measure, never assume.
UNPACKED_KB=$(du -sk "${PKG}/bin" | cut -f1)
echo "engine-build: unpacked payload = $((UNPACKED_KB / 1024)) MB"
if [ "${UNPACKED_KB}" -gt 61440 ]; then
  echo "engine-build: FAIL — payload exceeds the 60 MB budget (R3)" >&2
  exit 1
fi

cat > "${PKG}/package.json" <<JSON
{
  "name": "@react-native-impeller/engine-${TRIPLE}",
  "version": "${VERSION}",
  "description": "Prebuilt Impeller engine host for ${TRIPLE} (installed automatically by react-native-impeller)",
  "license": "MIT",
  "files": ["bin", "README.md"],
  "os": ["${PLATFORM}"],
  "cpu": ["${ARCH}"]
}
JSON

cat > "${PKG}/README.md" <<MD
# @react-native-impeller/engine-${TRIPLE}

Prebuilt engine binary for \`react-native-impeller\` on ${TRIPLE}.

Installed automatically as an optional dependency — do not depend on it directly.
Version is locked in step with \`react-native-impeller\`; the resolver refuses a
mismatch because the engine C ABI is not stable across versions.

Impeller SDK pin: \`$(cat engine/IMPELLER_SHA)\`
React Native (ReactCommon) pin: \`$(node -p "require('${ROOT}/engine/rn/node_modules/react-native/package.json').version")\`
MD

echo "engine-build: staged ${PKG} @ ${VERSION}"
