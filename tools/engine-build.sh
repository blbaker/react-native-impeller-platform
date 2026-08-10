#!/usr/bin/env bash
# Build the rn-impeller engine host and stage it into a per-platform npm package
# under packages-engine/engine-<platform>-<arch>/.
#
# The package is self-contained: it carries the engine binary AND libimpeller.so,
# with an rpath of $ORIGIN so the binary finds the library wherever npm unpacks it.
# A binary that only runs from the build tree is not a shippable package.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
SDK="${IMPELLER_SDK:-engine/third_party/impeller-sdk}"
[ -f "${SDK}/include/impeller.h" ] || bash tools/sdk-fetch.sh "${SDK}"

PLATFORM="${1:-linux}"
ARCH="${2:-x64}"
TRIPLE="${PLATFORM}-${ARCH}"
PKG="packages-engine/engine-${TRIPLE}"
VERSION="$(node -p "require('${ROOT}/package/package.json').version")"

if [ "${PLATFORM}" != "linux" ]; then
  echo "engine-build: ${PLATFORM} is not supported yet (P5=windows, P6=macos)" >&2
  exit 1
fi

mkdir -p "${PKG}/bin"
echo "engine-build: compiling ${TRIPLE} host"
g++ -std=c++17 -O2 engine/host/main.cpp \
    -I"${SDK}/include" -L"${SDK}/lib" -limpeller -lEGL -lGLESv2 \
    -Wl,-rpath,'$ORIGIN' \
    -o "${PKG}/bin/rn-impeller"

cp "${SDK}/lib/libimpeller.so" "${PKG}/bin/libimpeller.so"
strip --strip-unneeded "${PKG}/bin/rn-impeller" 2>/dev/null || true

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
MD

echo "engine-build: staged ${PKG} @ ${VERSION}"
